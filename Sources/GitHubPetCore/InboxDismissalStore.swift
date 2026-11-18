import Foundation

/// Local presentation history. The digest uses the stable row ID, independent of attention
/// revisions, titles, or the repository/assignment query that returned the row.
public struct DismissedInboxItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ItemKind
    public let number: Int?
    public let dismissedAt: Date

    public init?(item: InboxItem, dismissedAt: Date) {
        guard !item.id.isEmpty, Self.supports(item.kind), dismissedAt.timeIntervalSince1970.isFinite else { return nil }
        self.id = EventBaseline.digest(item.id)
        self.kind = item.kind
        self.dismissedAt = dismissedAt
        let path = SafeLink.validated(item.url)?.pathComponents.suffix(2)
        if let path, let resource = path.first, resource == "pull" || resource == "issues",
           let last = path.last, let number = Int(last), number > 0 {
            self.number = number
        } else {
            self.number = nil
        }
    }

    public static func supports(_ kind: ItemKind) -> Bool {
        switch kind {
        case .reviewRequest, .assignedIssue, .authoredPullRequest, .entitlement: return true
        case .ciFailure, .workflowFailure, .deploymentApproval, .serviceIncident: return false
        }
    }

    fileprivate var isValid: Bool {
        EventBaseline.isDigest(id) && Self.supports(kind) && (number.map { $0 > 0 } ?? true)
            && dismissedAt.timeIntervalSince1970.isFinite
    }
}

/// One bounded record per verified account or fixture identity, in the injected launch domain.
/// Absent rows never prune the record. Only Restore removes a dismissal.
public struct InboxDismissalStore {
    public static let capacity = 512
    private static let maximumBytes = 80 * 1024
    private struct Record: Codable {
        let entries: [DismissedInboxItem]
    }

    public enum Failure: Error { case invalidRecord }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    static func key(for identity: ScopeIdentity) -> String {
        "GitHubPet.inbox-dismissals.v1." + EventBaseline.digest(identity.storageSuffix)
    }

    public func load(for identity: ScopeIdentity) throws -> [DismissedInboxItem] {
        guard let saved = defaults.object(forKey: Self.key(for: identity)) else { return [] }
        guard let data = saved as? Data, data.count <= Self.maximumBytes,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              Self.valid(record.entries) else { throw Failure.invalidRecord }
        return record.entries
    }

    public func save(_ entries: [DismissedInboxItem], for identity: ScopeIdentity) throws {
        let key = Self.key(for: identity)
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        guard Self.valid(entries) else { throw Failure.invalidRecord }
        let data = try JSONEncoder().encode(Record(entries: entries))
        guard data.count <= Self.maximumBytes else { throw Failure.invalidRecord }
        defaults.set(data, forKey: key)
    }

    private static func valid(_ entries: [DismissedInboxItem]) -> Bool {
        entries.count <= capacity && entries.allSatisfy(\.isValid)
            && Set(entries.map(\.id)).count == entries.count
    }
}
