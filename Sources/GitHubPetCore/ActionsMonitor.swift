import Foundation
import CoreFoundation

/// #10 slice 1: GitHub Actions failures on the default branch's head commit of explicitly selected
/// repositories. Read-only: one viewer-bound GraphQL request per poll, with its own 20 s / 2 MiB
/// budget. Organizations and Everything are not expanded yet; they get an honest note instead.
public enum ActionsWatch {
    /// The GitHub Actions app (checked against the public /apps/github-actions endpoint).
    public static let actionsAppID = 15368
    /// Check suites read per head commit; more than this marks the repository capped (Partial).
    public static let suitesPerCommit = 20
    /// Conclusions that count as a genuine failure. Cancelled, skipped, neutral and stale don't.
    public static let failingConclusions: Set<String> = ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE"]
    /// Every value GitHub documents today. Anything else fails closed (Partial), so a future
    /// failure conclusion can't be silently skipped.
    public static let knownConclusions: Set<String> = failingConclusions.union(["SUCCESS", "CANCELLED", "SKIPPED", "NEUTRAL", "STALE", "ACTION_REQUIRED"])
    public static let knownStatuses: Set<String> = ["REQUESTED", "QUEUED", "IN_PROGRESS", "COMPLETED", "WAITING", "PENDING"]
    /// Bumped when what counts as a watched failure changes; part of the baseline key.
    public static let coverageVersion = 1

    public enum Coverage: Equatable, Sendable {
        case off
        /// Watch these repositories; `note` says what else in the scope is not watched.
        case repositories([MonitoringTarget], note: String?)
        /// Turned on, but the scope has no selected repository to watch.
        case needsRepositories(String)
    }

    public static let needsRepositoriesNote = "Workflow failures: select repositories in Monitoring scope to watch them. Organizations and Everything aren't watched yet."
    public static let organizationsNotWatchedNote = "Workflow failures are watched for the selected repositories only, not for selected organizations."

    public static func coverage(enabled: Bool, scope: MonitoringScope?) -> Coverage {
        guard enabled else { return .off }
        guard let scope, scope.mode == .selected else { return .needsRepositories(needsRepositoriesNote) }
        let repositories = scope.targets.filter { $0.kind == .repository }
        guard !repositories.isEmpty else { return .needsRepositories(needsRepositoriesNote) }
        let hasOrganizations = scope.targets.contains { $0.kind == .organization }
        return .repositories(repositories, note: hasOrganizations ? organizationsNotWatchedNote : nil)
    }
}

/// Repository owners and names travel only as GraphQL variables, never in the query text.
public struct ActionsQueryPlan: Sendable {
    public let repositories: [MonitoringTarget]
    public let expectedAccount: ScopeAccount?
    public let arguments: [String]

    public init(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?) {
        self.repositories = repositories.filter { $0.kind == .repository }
        self.expectedAccount = expectedAccount
        var definitions: [String] = [], variables: [(String, String)] = [], fields = ["viewer { id login }"]
        for (index, target) in self.repositories.enumerated() {
            definitions += ["$owner\(index): String!", "$name\(index): String!"]
            variables += [("owner\(index)", target.owner), ("name\(index)", target.name!)]
            fields.append("""
                repo\(index): repository(owner: $owner\(index), name: $name\(index)) {
                  nameWithOwner isArchived
                  defaultBranchRef { name target { __typename ... on Commit { oid
                    checkSuites(first: \(ActionsWatch.suitesPerCommit), filterBy: { appId: \(ActionsWatch.actionsAppID) }) {
                      totalCount
                      nodes { id status conclusion updatedAt creator { id } workflowRun { url runAttempt workflow { name } } }
                    } } } }
                }
                """)
        }
        let header = definitions.isEmpty ? "query" : "query(\(definitions.joined(separator: ", ")))"
        arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=\(header) {\n\(fields.joined(separator: "\n"))\n}"]
            + variables.flatMap { ["-f", "\($0.0)=\($0.1)"] }
    }
}

public enum ActionsResponseParser {
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
    private static let dates: ISO8601DateFormatter = ISO8601DateFormatter()

    /// Alias names in issues are "actions<i>" so they never collide with the inbox search aliases.
    public static func alias(_ index: Int) -> String { "actions\(index)" }

    public static func parse(_ bytes: Data, plan: ActionsQueryPlan) -> ScopedPollResult {
        guard bytes.count <= CommandBudget.maximumBytes else { return .failure(.outputLimit) }
        guard let envelope = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            return .failure(.viewerUnavailable)
        }
        var issues: [ScopedFetchIssue] = []
        if let errors = envelope["errors"] {
            let array = errors as? [[String: Any]] ?? []
            func type(_ error: [String: Any]) -> String? {
                error["type"] as? String ?? (error["extensions"] as? [String: Any])?["type"] as? String
            }
            let limited = array.contains { type($0) == "RATE_LIMITED" }
            let denied = array.contains { error in
                ["FORBIDDEN", "INSUFFICIENT_SCOPES"].contains(type(error) ?? "")
                    || (error["message"] as? String).map(ScopedGhClient.deniesAccess) == true
            }
            issues.append(limited ? .rateLimited : denied ? .accessDenied : .graphQLError)
        }
        guard let body = envelope["data"] as? [String: Any],
              let rawViewer = body["viewer"] as? [String: Any], let viewerID = rawViewer["id"] as? String,
              let login = rawViewer["login"] as? String, !login.isEmpty,
              let account = try? ScopeAccount(viewerID: viewerID) else {
            return ScopedPollResult(viewer: nil, items: [], issues: issues + [.viewerUnavailable], successfulSources: 0)
        }
        let viewer = ScopeViewer(account: account, login: login)
        if let expected = plan.expectedAccount, expected != account { return .failure(.identityMismatch, viewer: viewer) }

        var items: [InboxItem] = [], successes = 0
        for (index, target) in plan.repositories.enumerated() {
            let alias = alias(index)
            guard let repository = body["repo\(index)"] as? [String: Any] else { issues.append(.targetUnavailable(index)); continue }
            let expectedName = "\(target.owner)/\(target.name!)"
            guard (repository["nameWithOwner"] as? String)?.lowercased() == expectedName,
                  let archived = boolean(repository["isArchived"]) else { issues.append(.malformedTarget(index)); continue }
            // Archived, or no default branch yet: verified, nothing to watch.
            if archived || repository["defaultBranchRef"] is NSNull { successes += 1; continue }
            guard let branch = repository["defaultBranchRef"] as? [String: Any], let branchName = branch["name"] as? String,
                  let commit = branch["target"] as? [String: Any], commit["__typename"] as? String == "Commit",
                  let suites = commit["checkSuites"] as? [String: Any], let total = integer(suites["totalCount"]),
                  let nodes = suites["nodes"] as? [Any], nodes.count <= ActionsWatch.suitesPerCommit, total >= nodes.count else {
                issues.append(.malformedSource(alias)); continue
            }
            successes += 1
            if total > nodes.count { issues.append(.capped(alias)) }
            for node in nodes {
                guard let suite = node as? [String: Any], let id = suite["id"] as? String, ScopeASCII.nodeID(id),
                      let status = suite["status"] as? String,
                      let updated = (suite["updatedAt"] as? String).flatMap(dates.date(from:)) else {
                    issues.append(.malformedRow(alias)); continue
                }
                let conclusion = suite["conclusion"] as? String
                // Unknown values, or a completed suite without a conclusion, are not readable.
                guard ActionsWatch.knownStatuses.contains(status),
                      conclusion.map(ActionsWatch.knownConclusions.contains) ?? (status != "COMPLETED"),
                      suite["conclusion"] is String || suite["conclusion"] is NSNull else {
                    issues.append(.malformedRow(alias)); continue
                }
                guard status == "COMPLETED", let conclusion, ActionsWatch.failingConclusions.contains(conclusion) else { continue }
                guard let run = suite["workflowRun"] as? [String: Any], let rawURL = run["url"] as? String,
                      let url = SafeLink.validated(URL(string: rawURL)),
                      url.path.lowercased().hasPrefix("/\(expectedName)/actions/runs/"),
                      let workflow = (run["workflow"] as? [String: Any])?["name"] as? String, !workflow.isEmpty else {
                    issues.append(.malformedRow(alias)); continue
                }
                // Critical only when the viewer triggered the failing suite; any other failure is actionable.
                let creator = (suite["creator"] as? [String: Any])?["id"] as? String
                let kind: ItemKind = creator == viewerID ? .ciFailure : .workflowFailure
                // The ID follows the check suite: a re-run updates it in place, a new commit is a new item.
                items.append(InboxItem(id: "actions:\(id)", kind: kind, repository: repository["nameWithOwner"] as? String ?? expectedName,
                                       title: "\(workflow) failed on \(branchName)", url: url, updatedAt: updated))
            }
        }
        return ScopedPollResult(viewer: viewer, items: items, issues: issues, successfulSources: successes)
    }
}

/// Actions polling for the watched repositories. Callers give it its own budget.
public protocol ActionsPolling: Sendable {
    func fetch(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult
}

public struct ActionsGhClient: ActionsPolling {
    public var locator: GhLocator
    public var runner: CommandRunner
    public init(locator: GhLocator = GhLocator(), runner: CommandRunner = ProcessCommandRunner()) {
        self.locator = locator; self.runner = runner
    }

    public func fetch(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        let plan = ActionsQueryPlan(repositories: repositories, expectedAccount: expectedAccount)
        guard !plan.repositories.isEmpty else { return ScopedPollResult(viewer: nil, items: [], issues: [], successfulSources: 0) }
        guard let gh = locator.locate() else { return .failure(.ghMissing) }
        do {
            let result = try runner.run(executable: gh, arguments: plan.arguments, budget: budget)
            let message = result.stderrText.lowercased()
            if GhClient.isAuthFailure(result) || message.contains("bad credentials") || message.contains("http 401") {
                return .failure(.signedOut)
            }
            guard result.outputComplete else { return .failure(.incompleteOutput) }
            if result.exitCode != 0 && message.contains("rate limit") { return .failure(.rateLimited) }
            let parsed = ActionsResponseParser.parse(result.stdout, plan: plan)
            try budget.check()
            guard result.exitCode != 0 else { return parsed }
            // A failed gh process keeps readable repositories but can never look complete.
            let usable = parsed.viewer != nil && parsed.successfulSources > 0
            let reason: ScopedFetchIssue = ScopedGhClient.deniesAccess(result.stderrText) ? .accessDenied : .transport
            guard usable else { return .failure(parsed.issues.contains(.identityMismatch) ? .identityMismatch : reason) }
            let issues = parsed.issues.contains(reason) ? parsed.issues : parsed.issues + [reason]
            return ScopedPollResult(viewer: parsed.viewer, items: parsed.items, issues: issues, successfulSources: parsed.successfulSources)
        } catch CommandError.outputLimitExceeded { return .failure(.outputLimit) }
        catch CommandError.timedOut { return .failure(.deadline) }
        catch CommandError.cancelled { return .failure(.cancelled) }
        catch { return .failure(.transport) }
    }
}

/// The last readable failures per watched repository (#10). When a cycle can't read a repository,
/// its previous rows stay, marked "last known", and the snapshot is Partial: never a clean
/// "no failures". It starts over whenever the account or the watched repositories change.
public final class ActionsLastKnown: @unchecked Sendable {
    public static let staleSuffix = " · last known"
    private let lock = NSLock()
    private var key: String?
    private var byRepository: [String: [InboxItem]] = [:]

    public init() {}

    public func apply(_ result: ScopedPollResult, repositories: [MonitoringTarget], account: ScopeAccount?) -> ScopedPollResult {
        let names = repositories.map { "\($0.owner)/\($0.name!)" }
        let key = (account?.viewerID ?? "") + "\n" + names.sorted().joined(separator: ",")
        lock.lock(); defer { lock.unlock() }
        if key != self.key { self.key = key; byRepository = [:] }
        // An account change is handled by the inbox (refetch); nothing carries over.
        if result.issues.contains(.identityMismatch) { byRepository = [:]; return result }
        var failed = Set<Int>()
        if result.viewer == nil || result.successfulSources == 0 {
            failed = Set(names.indices)
        } else {
            for issue in result.issues {
                switch issue {
                case .targetUnavailable(let index), .malformedTarget(let index): failed.insert(index)
                case .malformedSource(let alias):
                    if let index = names.indices.first(where: { ActionsResponseParser.alias($0) == alias }) { failed.insert(index) }
                default: break
                }
            }
        }
        var carried: [InboxItem] = []
        for (index, name) in names.enumerated() {
            if failed.contains(index) {
                carried += (byRepository[name] ?? []).map { item in
                    var stale = item
                    if !stale.title.hasSuffix(Self.staleSuffix) { stale.title += Self.staleSuffix }
                    return stale
                }
            } else {
                byRepository[name] = result.items.filter { $0.repository.lowercased() == name }
            }
        }
        guard !carried.isEmpty else { return result }
        return ScopedPollResult(viewer: result.viewer, items: result.items + carried, issues: result.issues,
                                successfulSources: result.successfulSources, hidden: result.hidden,
                                waitingOnOthers: result.waitingOnOthers)
    }
}

public extension ScopedPollResult {
    /// Adds a watched-repositories Actions result to the inbox poll. Any Actions problem makes the
    /// whole snapshot Partial (never a clean "no failures"); a different viewer is an account change.
    /// The inbox's own waiting-on-others count (#9) is informational and always carried through.
    func mergingActions(_ actions: ScopedPollResult) -> ScopedPollResult {
        if let mine = viewer, let theirs = actions.viewer, mine.account != theirs.account {
            return ScopedPollResult(viewer: viewer, items: items, issues: issues + [.identityMismatch],
                                    successfulSources: successfulSources, hidden: hidden, waitingOnOthers: waitingOnOthers)
        }
        // Problems that are fatal for a whole poll only mean "Actions unverified" here.
        let actionsIssues = actions.issues.map { issue -> ScopedFetchIssue in
            switch issue {
            case .signedOut, .ghMissing, .identityRequired, .viewerUnavailable: return .transport
            default: return issue
            }
        }
        let ids = Set(items.map(\.id))
        return ScopedPollResult(viewer: viewer, items: items + actions.items.filter { !ids.contains($0.id) },
                                issues: issues + actionsIssues, successfulSources: successfulSources + actions.successfulSources,
                                hidden: actionsIssues.isEmpty ? hidden : 0, waitingOnOthers: waitingOnOthers)
    }
}
