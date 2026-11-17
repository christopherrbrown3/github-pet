import Foundation
import CoreFoundation

/// #10 slice 2: deployment approvals in the selected repositories. Read-only, never approves:
/// one REST `actions/runs?status=waiting` call per watched repository, then (only if any run is
/// waiting) one batched GraphQL request for each run's `pendingDeploymentRequests`, where GitHub
/// itself says whether the viewer can approve. Approvable runs are rows that open the run page;
/// runs waiting for other reviewers or a wait timer are only a count.
public enum DeploymentApprovals {
    /// Waiting runs read per repository; more marks it capped (Partial).
    public static let waitingRunsPerRepository = 10
    /// Pending requests read per run; more marks it capped (Partial).
    public static let requestsPerRun = 10

    /// Issue aliases are "deploy<i>", indexed like the watched repositories.
    public static func alias(_ index: Int) -> String { "deploy\(index)" }

    /// One line beside usable data, never rows, alerts or mood. A lower bound while incomplete.
    public static func waitingNote(_ count: Int, complete: Bool) -> String? {
        guard count > 0 else { return nil }
        let prefix = complete ? "" : "At least "
        let noun = count == 1 ? "deployment" : "deployments"
        let verb = count == 1 && complete ? "is" : "are"
        // Neutral: a run with no approvable request may wait on other reviewers or only a wait timer.
        return "\(prefix)\(count) \(noun) \(verb) waiting for other reviewers or a wait timer"
    }
}

/// One watched repository's waiting runs. The owner and name are validated `MonitoringTarget`
/// parts (ASCII, no slashes), passed as one argv element; no shell is involved.
public struct WaitingRunsPlan: Sendable {
    public let repository: MonitoringTarget
    public let arguments: [String]
    public init(repository: MonitoringTarget) {
        self.repository = repository
        arguments = ["api", "--hostname", "github.com", "-X", "GET",
                     "repos/\(repository.owner)/\(repository.name!)/actions/runs",
                     "-f", "status=waiting", "-f", "per_page=\(DeploymentApprovals.waitingRunsPerRepository)"]
    }
}

public struct WaitingRun: Equatable, Sendable {
    public let nodeID: String
    public let repositoryIndex: Int
    public let repository: String
    public let workflow: String
    public let url: URL
    public let updatedAt: Date
}

public enum WaitingRunsParser {
    public struct Page: Equatable, Sendable {
        public var runs: [WaitingRun]
        public var capped: Bool
    }
    private static let dates = ISO8601DateFormatter()
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= Double(Int32.max),
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }

    /// nil when the response isn't a readable runs page. Every run must be "waiting" and link to
    /// this repository's run page on github.com.
    public static func parse(_ bytes: Data, plan: WaitingRunsPlan, index: Int) -> Page? {
        guard bytes.count <= CommandBudget.maximumBytes,
              let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let total = integer(body["total_count"]), let raw = body["workflow_runs"] as? [Any],
              raw.count <= DeploymentApprovals.waitingRunsPerRepository, total >= raw.count else { return nil }
        let name = "\(plan.repository.owner)/\(plan.repository.name!)"
        var runs: [WaitingRun] = []
        for entry in raw {
            guard let run = entry as? [String: Any], let nodeID = run["node_id"] as? String, ScopeASCII.nodeID(nodeID),
                  run["status"] as? String == "waiting",
                  let workflow = run["name"] as? String, !workflow.isEmpty,
                  let link = (run["html_url"] as? String).flatMap({ SafeLink.validated(URL(string: $0)) }),
                  link.path.lowercased().hasPrefix("/\(name)/actions/runs/"),
                  let updated = (run["updated_at"] as? String).flatMap(dates.date(from:)) else { return nil }
            runs.append(WaitingRun(nodeID: nodeID, repositoryIndex: index, repository: name, workflow: workflow,
                                   url: link, updatedAt: updated))
        }
        return Page(runs: runs, capped: total > raw.count)
    }
}

/// One request for every waiting run's pending deployment requests, bound to the viewer.
public struct PendingRequestsPlan: Sendable {
    public let runs: [WaitingRun]
    public let expectedAccount: ScopeAccount?
    public let arguments: [String]
    public init(runs: [WaitingRun], expectedAccount: ScopeAccount?) {
        self.runs = runs; self.expectedAccount = expectedAccount
        var definitions: [String] = [], variables: [String] = [], fields = ["viewer { id login }"]
        for (index, run) in runs.enumerated() {
            definitions.append("$run\(index): ID!")
            variables += ["-f", "run\(index)=\(run.nodeID)"]
            fields.append("""
                run\(index): node(id: $run\(index)) { __typename ... on WorkflowRun {
                  pendingDeploymentRequests(first: \(DeploymentApprovals.requestsPerRun)) {
                    totalCount nodes { currentUserCanApprove environment { name } } } } }
                """)
        }
        let header = definitions.isEmpty ? "query" : "query(\(definitions.joined(separator: ", ")))"
        arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=\(header) {\n\(fields.joined(separator: "\n"))\n}"]
            + variables
    }
}

public enum PendingRequestsParser {
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

    /// Approvable runs become `deploymentApproval` rows; every other waiting run is counted as
    /// waiting on others. Anything unreadable fails closed for that repository.
    public static func parse(_ bytes: Data, plan: PendingRequestsPlan) -> ScopedPollResult {
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
        var items: [InboxItem] = [], waiting = 0
        for (index, run) in plan.runs.enumerated() {
            let alias = DeploymentApprovals.alias(run.repositoryIndex)
            guard let node = body["run\(index)"] as? [String: Any], node["__typename"] as? String == "WorkflowRun",
                  let requests = node["pendingDeploymentRequests"] as? [String: Any],
                  let total = integer(requests["totalCount"]), let nodes = requests["nodes"] as? [Any],
                  nodes.count <= DeploymentApprovals.requestsPerRun, total >= nodes.count else {
                issues.append(.malformedRow(alias)); continue
            }
            if total > nodes.count { issues.append(.capped(alias)) }
            var approvable: [String] = [], readable = true
            for entry in nodes {
                guard let request = entry as? [String: Any], let canApprove = boolean(request["currentUserCanApprove"]) else {
                    readable = false; break
                }
                if canApprove { approvable.append(((request["environment"] as? [String: Any])?["name"] as? String) ?? "") }
            }
            guard readable else { issues.append(.malformedRow(alias)); continue }
            guard !approvable.isEmpty else { waiting += 1; continue }
            let environments = Array(Set(approvable.filter { !$0.isEmpty })).sorted()
            let target = environments.isEmpty ? "" : " to " + environments.joined(separator: ", ")
            // The run is the row: a new attempt of the same run waiting again doesn't re-announce.
            items.append(InboxItem(id: "deploy:\(run.nodeID)", kind: .deploymentApproval, repository: run.repository,
                                   title: "\(run.workflow) is waiting for your approval\(target)", url: run.url,
                                   updatedAt: run.updatedAt))
        }
        return ScopedPollResult(viewer: viewer, items: items, issues: issues, successfulSources: 1, waitingOnOthers: waiting)
    }
}

/// Deployment approvals for the watched repositories. Callers give it its own budget.
public protocol DeploymentPolling: Sendable {
    func fetch(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult
}

public struct DeploymentGhClient: DeploymentPolling {
    public var locator: GhLocator
    public var runner: CommandRunner
    public init(locator: GhLocator = GhLocator(), runner: CommandRunner = ProcessCommandRunner()) {
        self.locator = locator; self.runner = runner
    }

    private static func authFailure(_ result: CommandResult) -> Bool {
        let message = result.stderrText.lowercased()
        return GhClient.isAuthFailure(result) || message.contains("bad credentials") || message.contains("http 401")
    }

    /// `successfulSources` counts readable repositories. With no waiting run anywhere there is no
    /// GraphQL request, so `viewer` is nil; the caller binds that result to the inbox's viewer.
    public func fetch(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        let watched = repositories.filter { $0.kind == .repository }
        guard !watched.isEmpty else { return ScopedPollResult(viewer: nil, items: [], issues: [], successfulSources: 0) }
        guard let gh = locator.locate() else { return .failure(.ghMissing) }
        var issues: [ScopedFetchIssue] = [], runs: [WaitingRun] = [], readable = 0
        do {
            for (index, repository) in watched.enumerated() {
                let plan = WaitingRunsPlan(repository: repository)
                let result = try runner.run(executable: gh, arguments: plan.arguments, budget: budget)
                try budget.check()
                if Self.authFailure(result) { return .failure(.signedOut) }
                let message = result.stderrText.lowercased()
                guard result.outputComplete else { issues.append(.malformedSource(DeploymentApprovals.alias(index))); continue }
                if result.exitCode != 0 {
                    if message.contains("rate limit") { issues.append(.rateLimited) }
                    else if ScopedGhClient.deniesAccess(result.stderrText) { issues.append(.accessDenied) }
                    issues.append(.targetUnavailable(index)); continue
                }
                guard let page = WaitingRunsParser.parse(result.stdout, plan: plan, index: index) else {
                    issues.append(.malformedSource(DeploymentApprovals.alias(index))); continue
                }
                readable += 1
                if page.capped { issues.append(.capped(DeploymentApprovals.alias(index))) }
                runs += page.runs
            }
            guard !runs.isEmpty else { return ScopedPollResult(viewer: nil, items: [], issues: issues, successfulSources: readable) }
            let plan = PendingRequestsPlan(runs: runs, expectedAccount: expectedAccount)
            let result = try runner.run(executable: gh, arguments: plan.arguments, budget: budget)
            if Self.authFailure(result) { return .failure(.signedOut) }
            guard result.outputComplete else { return .failure(.incompleteOutput) }
            if result.exitCode != 0 && result.stderrText.lowercased().contains("rate limit") { return .failure(.rateLimited) }
            let parsed = PendingRequestsParser.parse(result.stdout, plan: plan)
            try budget.check()
            if parsed.issues.contains(.identityMismatch) { return parsed }
            guard parsed.viewer != nil else { return ScopedPollResult(viewer: nil, items: [], issues: issues + parsed.issues, successfulSources: 0) }
            var all = issues + parsed.issues
            if result.exitCode != 0 { all.append(ScopedGhClient.deniesAccess(result.stderrText) ? .accessDenied : .transport) }
            return ScopedPollResult(viewer: parsed.viewer, items: parsed.items, issues: all, successfulSources: readable,
                                    waitingOnOthers: parsed.waitingOnOthers)
        } catch CommandError.outputLimitExceeded { return .failure(.outputLimit) }
        catch CommandError.timedOut { return .failure(.deadline) }
        catch CommandError.cancelled { return .failure(.cancelled) }
        catch { return .failure(.transport) }
    }
}
