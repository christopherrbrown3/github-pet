import Foundation
import CoreFoundation

/// One operation, one request-bound viewer. Every search has exactly one safe inclusion qualifier.
public struct ScopeQueryPlan: Sendable {
    public static let rowsPerCategory = 30
    public struct Search: Sendable {
        public let alias: String
        public let kind: ItemKind
        public let targetIndex: Int?
    }
    public let scope: MonitoringScope
    public let expectedAccount: ScopeAccount?
    public let searches: [Search]
    public let arguments: [String]

    public init(scope: MonitoringScope = .everything, expectedAccount: ScopeAccount? = nil) throws {
        guard scope.mode == .everything || expectedAccount != nil else { throw ScopeValidationError.invalidIdentity }
        self.scope = scope; self.expectedAccount = expectedAccount
        var definitions: [String] = [], variables: [(String, String)] = [], fields = ["viewer { id login }"]
        var searches: [Search] = []
        func variable(_ key: String, _ value: String) {
            definitions.append("$\(key): String!"); variables.append((key, value))
        }
        for (index, target) in scope.targets.enumerated() {
            variable("owner\(index)", target.owner)
            if let name = target.name {
                variable("name\(index)", name)
                fields.append("target\(index): repository(owner: $owner\(index), name: $name\(index)) { __typename id nameWithOwner }")
            } else {
                fields.append("target\(index): organization(login: $owner\(index)) { __typename id login }")
            }
        }
        let inclusions: [MonitoringTarget?] = scope.mode == .everything ? [nil] : scope.targets.map(Optional.some)
        for (index, target) in inclusions.enumerated() {
            for kind in [ItemKind.reviewRequest, .assignedIssue] {
                let alias = (kind == .reviewRequest ? "reviews" : "assigned") + String(index)
                let base = kind == .reviewRequest ? "is:pr is:open review-requested:@me" : "is:issue is:open assignee:@me"
                variable(alias, base + (target.map { " " + $0.qualifier } ?? ""))
                let type = kind == .reviewRequest ? "PullRequest" : "Issue"
                fields.append("""
                    \(alias): search(query: $\(alias), type: ISSUE, first: \(Self.rowsPerCategory)) {
                      issueCount pageInfo { hasNextPage }
                      nodes { __typename ... on \(type) { id number title url updatedAt repository { nameWithOwner } } }
                    }
                    """)
                searches.append(Search(alias: alias, kind: kind, targetIndex: target == nil ? nil : index))
            }
        }
        self.searches = searches
        let query = "query(\(definitions.joined(separator: ", "))) {\n\(fields.joined(separator: "\n"))\n}"
        self.arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=\(query)"]
            + variables.flatMap { ["-f", "\($0.0)=\($0.1)"] }
    }
}

public enum ScopedFetchIssue: Equatable, Sendable {
    case viewerUnavailable, identityMismatch, identityRequired
    case targetUnavailable(Int), malformedTarget(Int)
    case missingSource(String), malformedSource(String), malformedRow(String), capped(String), inconsistentDuplicate
    case graphQLError, rateLimited, ghMissing, signedOut, transport, deadline, outputLimit, incompleteOutput, cancelled
}

public struct ScopedPollResult: Equatable, Sendable {
    public let viewer: ScopeViewer?
    public let items: [InboxItem]
    public let issues: [ScopedFetchIssue]
    public let successfulSources: Int
    public var complete: Bool { viewer != nil && successfulSources > 0 && issues.isEmpty }
    public var outcome: FetchOutcome {
        if issues.contains(.ghMissing) { return .failure(.ghMissing) }
        if issues.contains(.signedOut) { return .failure(.unauthenticated) }
        guard viewer != nil, successfulSources > 0 else { return .failure(.failed("Monitoring scope could not be verified")) }
        return .snapshot(items: items, complete: complete)
    }
    static func failure(_ issue: ScopedFetchIssue, viewer: ScopeViewer? = nil) -> Self {
        Self(viewer: viewer, items: [], issues: [issue], successfulSources: 0)
    }
}

public enum ScopedResponseParser {
    private struct Row: Decodable {
        struct Repository: Decodable { let nameWithOwner: String }
        let __typename: String
        let id: String
        let number: Int
        let title: String
        let url: String
        let updatedAt: Date
        let repository: Repository
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= Double(Int32.max),
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    public static func parse(_ bytes: Data, plan: ScopeQueryPlan) -> ScopedPollResult {
        guard bytes.count <= CommandBudget.maximumBytes else { return .failure(.outputLimit) }
        guard let envelope = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            return .failure(.viewerUnavailable)
        }
        var issues: [ScopedFetchIssue] = []
        if let errors = envelope["errors"] {
            let array = errors as? [[String: Any]] ?? []
            let limited = array.contains {
                ($0["type"] as? String) == "RATE_LIMITED"
                    || (($0["extensions"] as? [String: Any])?["type"] as? String) == "RATE_LIMITED"
            }
            issues.append(limited ? .rateLimited : .graphQLError)
        }
        guard let body = envelope["data"] as? [String: Any],
              let rawViewer = body["viewer"] as? [String: Any], let id = rawViewer["id"] as? String,
              let login = rawViewer["login"] as? String, login.trimmingCharacters(in: .whitespacesAndNewlines) == login,
              (try? MonitoringTarget(organization: login)) != nil,
              let account = try? ScopeAccount(viewerID: id) else {
            return ScopedPollResult(viewer: nil, items: [], issues: issues + [.viewerUnavailable], successfulSources: 0)
        }
        let viewer = ScopeViewer(account: account, login: login)
        if let expected = plan.expectedAccount, expected != account { return .failure(.identityMismatch, viewer: viewer) }
        var verified = Set<Int>()
        for (index, target) in plan.scope.targets.enumerated() {
            guard let metadata = body["target\(index)"] as? [String: Any] else {
                issues.append(.targetUnavailable(index)); continue
            }
            guard let id = metadata["id"] as? String, ScopeASCII.nodeID(id) else {
                issues.append(.malformedTarget(index)); continue
            }
            let type = metadata["__typename"] as? String
            let matches: Bool
            if target.kind == .organization {
                matches = type == "Organization" && (metadata["login"] as? String)?.lowercased() == target.owner
            } else {
                matches = type == "Repository" && (metadata["nameWithOwner"] as? String)?.lowercased() == "\(target.owner)/\(target.name!)"
            }
            if matches { verified.insert(index) } else { issues.append(.malformedTarget(index)) }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var items: [String: InboxItem] = [:], successes = 0
        for search in plan.searches {
            if let index = search.targetIndex, !verified.contains(index) { continue }
            guard let page = body[search.alias] as? [String: Any] else { issues.append(.missingSource(search.alias)); continue }
            guard let count = integer(page["issueCount"]), let nodes = page["nodes"] as? [Any],
                  nodes.count <= ScopeQueryPlan.rowsPerCategory,
                  let info = page["pageInfo"] as? [String: Any], let more = boolean(info["hasNextPage"]) else {
                issues.append(.malformedSource(search.alias)); continue
            }
            successes += 1
            if count > nodes.count || more { issues.append(.capped(search.alias)) }
            if count < nodes.count { issues.append(.malformedSource(search.alias)) }
            var sourceIDs = Set<String>()
            for node in nodes {
                guard let data = try? JSONSerialization.data(withJSONObject: node, options: [.fragmentsAllowed]),
                      let row = try? decoder.decode(Row.self, from: data), row.number > 0,
                      ScopeASCII.nodeID(row.id),
                      row.__typename == (search.kind == .reviewRequest ? "PullRequest" : "Issue"),
                      let repository = try? MonitoringTarget(repository: row.repository.nameWithOwner),
                      let url = SafeLink.validated(row.url),
                      url.path.lowercased() == "/\(repository.owner)/\(repository.name!)/\(search.kind == .reviewRequest ? "pull" : "issues")/\(row.number)",
                      search.targetIndex.map({ plan.scope.targets[$0].includes(row.repository.nameWithOwner) }) ?? true else {
                    issues.append(.malformedRow(search.alias)); continue
                }
                let key = "\(search.kind.rawValue):\(row.id)"
                guard sourceIDs.insert(key).inserted else { issues.append(.malformedRow(search.alias)); continue }
                let item = InboxItem(id: key, kind: search.kind, repository: row.repository.nameWithOwner,
                                     title: row.title, url: url, updatedAt: row.updatedAt)
                if let old = items[key], old != item { issues.append(.inconsistentDuplicate) }
                if items[key].map({ $0.updatedAt > item.updatedAt }) != true { items[key] = item }
            }
        }
        return ScopedPollResult(viewer: viewer, items: InboxEngine.dedupe(Array(items.values)), issues: issues,
                                successfulSources: successes)
    }
}

/// Opt-in core API for the later AppModel slice. Existing GhClient callers remain Everything.
public struct ScopedGhClient: Sendable {
    public var locator: GhLocator
    public var runner: CommandRunner
    public var timeout: TimeInterval
    public init(locator: GhLocator = GhLocator(), runner: CommandRunner = ProcessCommandRunner(), timeout: TimeInterval = 20) {
        self.locator = locator; self.runner = runner; self.timeout = timeout
    }
    private static func authFailure(_ result: CommandResult) -> Bool {
        let message = result.stderrText.lowercased()
        return GhClient.isAuthFailure(result) || message.contains("bad credentials") || message.contains("http 401")
    }
    public func fetch(scope: MonitoringScope = .everything, expectedAccount: ScopeAccount? = nil) -> ScopedPollResult {
        let budget = CommandBudget(timeout: timeout)
        guard let plan = try? ScopeQueryPlan(scope: scope, expectedAccount: expectedAccount) else {
            return .failure(.identityRequired)
        }
        guard let gh = locator.locate() else { return .failure(.ghMissing) }
        do {
            let auth = try runner.run(executable: gh, arguments: GhClient.authStatusArguments, budget: budget)
            guard auth.outputComplete else { return .failure(.incompleteOutput) }
            if auth.exitCode != 0 && !auth.stderrText.lowercased().contains("unknown flag") {
                let message = auth.stderrText.lowercased()
                if message.contains("rate limit") { return .failure(.rateLimited) }
                if ["network", "could not resolve", "connection", "timed out", "dial tcp"].contains(where: message.contains) {
                    return .failure(.transport)
                }
                return .failure(auth.exitCode == 1 || Self.authFailure(auth) ? .signedOut : .transport)
            }
            let result = try runner.run(executable: gh, arguments: plan.arguments, budget: budget)
            if Self.authFailure(result) { return .failure(.signedOut) }
            guard result.outputComplete else { return .failure(.incompleteOutput) }
            if result.exitCode != 0 && result.stderrText.lowercased().contains("rate limit") { return .failure(.rateLimited) }
            let parsed = ScopedResponseParser.parse(result.stdout, plan: plan)
            try budget.check()
            if result.exitCode != 0 && parsed.viewer == nil && !parsed.issues.contains(.graphQLError)
                && !parsed.issues.contains(.rateLimited) { return .failure(.transport) }
            // A failing gh process cannot turn a superficially valid empty JSON payload into success.
            if result.exitCode != 0 && parsed.issues.isEmpty {
                return ScopedPollResult(viewer: parsed.viewer, items: parsed.items, issues: [.transport],
                                        successfulSources: parsed.successfulSources)
            }
            return parsed
        } catch CommandError.outputLimitExceeded { return .failure(.outputLimit) }
        catch CommandError.timedOut { return .failure(.deadline) }
        catch CommandError.cancelled { return .failure(.cancelled) }
        catch { return .failure(.transport) }
    }
}
