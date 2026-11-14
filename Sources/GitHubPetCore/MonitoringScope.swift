import Foundation

public enum ScopeValidationError: Error, Equatable, Sendable {
    case invalidOrganization, invalidRepository, emptySelection, tooManyTargets, invalidIdentity, unsupportedHost
}

/// Immutable, validated input. Query text can contain only these normalized components.
public struct MonitoringTarget: Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable { case organization, repository }
    public let kind: Kind
    public let owner: String
    public let name: String?

    private static func ownerValid(_ value: String) -> Bool {
        (1...39).contains(value.utf8.count)
            && value.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$", options: .regularExpression) != nil
    }
    public init(organization: String) throws {
        let owner = organization.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.ownerValid(owner) else { throw ScopeValidationError.invalidOrganization }
        self.kind = .organization; self.owner = owner; self.name = nil
    }
    public init(repository: String) throws {
        let parts = repository.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ScopeValidationError.invalidRepository }
        let owner = String(parts[0]).lowercased(), name = String(parts[1]).lowercased()
        guard Self.ownerValid(owner), (1...100).contains(name.utf8.count), name != ".", name != "..",
              name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            throw ScopeValidationError.invalidRepository
        }
        self.kind = .repository; self.owner = owner; self.name = name
    }
    public var qualifier: String { kind == .organization ? "org:\(owner)" : "repo:\(owner)/\(name!)" }
    public var includes: (String) -> Bool {
        { repository in
            guard let parsed = try? MonitoringTarget(repository: repository) else { return false }
            return self.kind == .organization ? parsed.owner == self.owner : parsed == self
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, owner, name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind), owner = try c.decode(String.self, forKey: .owner)
        if kind == .organization {
            guard try c.decodeIfPresent(String.self, forKey: .name) == nil else { throw ScopeValidationError.invalidOrganization }
            try self.init(organization: owner)
        } else {
            try self.init(repository: owner + "/" + c.decode(String.self, forKey: .name))
        }
    }
}

public struct MonitoringScope: Equatable, Sendable, Codable {
    public enum Mode: String, Codable, Sendable { case everything, selected }
    public static let maximumTargets = 10
    public let mode: Mode
    public let targets: [MonitoringTarget]
    public static let everything = MonitoringScope()
    private init() { mode = .everything; targets = [] }

    public init(selected targets: [MonitoringTarget]) throws {
        let unique = Set(targets)
        guard !unique.isEmpty else { throw ScopeValidationError.emptySelection }
        guard unique.count <= Self.maximumTargets else { throw ScopeValidationError.tooManyTargets }
        mode = .selected
        self.targets = unique.sorted { $0.qualifier < $1.qualifier }
    }
    public func includes(repository: String) -> Bool {
        mode == .everything || targets.contains { $0.includes(repository) }
    }
    private enum CodingKeys: String, CodingKey { case mode, targets }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try c.decode(Mode.self, forKey: .mode)
        let targets = try c.decode([MonitoringTarget].self, forKey: .targets)
        if mode == .everything {
            guard targets.isEmpty else { throw ScopeValidationError.emptySelection }
            self = .everything
        } else { try self.init(selected: targets) }
    }
}

public struct ScopeAccount: Hashable, Sendable, Codable {
    public let host: String
    public let viewerID: String
    public init(host: String = "github.com", viewerID: String) throws {
        guard host.lowercased() == "github.com" else { throw ScopeValidationError.unsupportedHost }
        guard (1...256).contains(viewerID.utf8.count),
              viewerID.range(of: "^[A-Za-z0-9_+/=-]+$", options: .regularExpression) != nil else {
            throw ScopeValidationError.invalidIdentity
        }
        self.host = "github.com"; self.viewerID = viewerID
    }
    private enum CodingKeys: String, CodingKey { case host, viewerID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: c.decode(String.self, forKey: .host), viewerID: c.decode(String.self, forKey: .viewerID))
    }
}

/// Login is display metadata; renaming an account never changes its persistence key.
public struct ScopeViewer: Equatable, Sendable {
    public let account: ScopeAccount
    public let login: String
    public init(account: ScopeAccount, login: String) { self.account = account; self.login = login }
}

public enum ScopeIdentity: Hashable, Sendable {
    case demo
    case github(ScopeAccount)
    var storageSuffix: String {
        switch self {
        case .demo: return "demo"
        case .github(let account): return "\(account.host).\(account.viewerID)"
        }
    }
}

public enum ScopeLoadResult: Equatable, Sendable {
    case scope(MonitoringScope)
    case corruptConfiguration
}

/// Separate records prevent one corrupt account selection from silently broadening another.
/// Missing legacy/account records start at Everything; present-but-invalid records never do.
public final class ScopeSelectionStore {
    public static let maximumRecordBytes = 16 * 1024
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func key(_ identity: ScopeIdentity) -> String { "GitHubPet.monitoring-scope.v1." + identity.storageSuffix }
    public func load(for identity: ScopeIdentity) -> ScopeLoadResult {
        let key = Self.key(identity)
        guard let object = defaults.object(forKey: key) else { return .scope(.everything) }
        guard let data = object as? Data, data.count <= Self.maximumRecordBytes,
              let scope = try? JSONDecoder().decode(MonitoringScope.self, from: data) else {
            return .corruptConfiguration
        }
        return .scope(scope)
    }
    public func save(_ scope: MonitoringScope, for identity: ScopeIdentity) throws {
        defaults.set(try JSONEncoder().encode(scope), forKey: Self.key(identity))
    }
}

/// Offline scope fixtures are explicitly Demo and never look up live targets or credentials.
public struct ScopedFixtureSource: Sendable {
    public var items: [InboxItem]
    public init(items: [InboxItem]) { self.items = items }
    public func poll(scope: MonitoringScope = .everything) -> FetchOutcome {
        let scoped = items.filter { scope.includes(repository: $0.repository) }.map { item -> InboxItem in
            var demo = item; demo.isDemo = true; return demo
        }
        return .snapshot(items: InboxEngine.dedupe(scoped), complete: true)
    }
}
