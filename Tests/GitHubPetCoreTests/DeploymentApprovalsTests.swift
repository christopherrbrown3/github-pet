import Foundation
import Testing
@testable import GitHubPetCore

private let viewerA = try! ScopeAccount(viewerID: "U_deploy_A")
private let viewerB = try! ScopeAccount(viewerID: "U_deploy_B")
private let pet = try! MonitoringTarget(repository: "example/pet")
private let tools = try! MonitoringTarget(repository: "example/tools")

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private func run(_ node: String, repo: String = "example/pet", status: String = "waiting", url: String? = nil) -> [String: Any] {
    ["node_id": node, "status": status, "name": "Deploy", "updated_at": "2026-11-17T10:00:00Z",
     "html_url": url ?? "https://github.com/\(repo)/actions/runs/7"]
}
private func page(_ runs: [[String: Any]], total: Int? = nil) -> Data { json(["total_count": total ?? runs.count, "workflow_runs": runs]) }
private func request(_ canApprove: Any?, environment: String = "production") -> [String: Any] {
    ["currentUserCanApprove": canApprove ?? NSNull(), "environment": ["name": environment]]
}
private func pending(_ runs: [[[String: Any]]], viewer: ScopeAccount = viewerA, totals: [Int]? = nil) -> Data {
    var data: [String: Any] = ["viewer": ["id": viewer.viewerID, "login": "deployer"]]
    for (index, requests) in runs.enumerated() {
        data["run\(index)"] = ["__typename": "WorkflowRun",
                               "pendingDeploymentRequests": ["totalCount": totals?[index] ?? requests.count, "nodes": requests]]
    }
    return json(["data": data])
}
private func waiting(_ node: String, index: Int = 0, repo: String = "example/pet") -> WaitingRun {
    WaitingRun(nodeID: node, repositoryIndex: index, repository: repo, workflow: "Deploy",
               url: URL(string: "https://github.com/\(repo)/actions/runs/7")!, updatedAt: Date(timeIntervalSince1970: 0))
}

private final class Runner: CommandRunner, @unchecked Sendable {
    var replies: [CommandResult]
    private(set) var calls: [[String]] = []
    init(_ replies: [CommandResult]) { self.replies = replies }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append(arguments); return replies.removeFirst()
    }
}
private func client(_ runner: Runner) -> DeploymentGhClient {
    DeploymentGhClient(locator: GhLocator(environment: [GhLocator.overrideVariable: "/fixture/gh"], isExecutable: { _ in true }),
                       runner: runner)
}

@Suite struct DeploymentApprovalsTests {
    @Test func waitingRunsRequestIsAReadOnlyBoundedGet() {
        #expect(WaitingRunsPlan(repository: pet).arguments == ["api", "--hostname", "github.com", "-X", "GET",
                                                                "repos/example/pet/actions/runs", "-f", "status=waiting", "-f", "per_page=10"])
    }

    @Test func waitingRunsPagesAreValidatedAndCapped() throws {
        let plan = WaitingRunsPlan(repository: pet)
        let ok = try #require(WaitingRunsParser.parse(page([run("WFR_1"), run("WFR_2")]), plan: plan, index: 0))
        #expect(ok.runs.map(\.nodeID) == ["WFR_1", "WFR_2"] && !ok.capped && ok.runs[0].repository == "example/pet")
        #expect(WaitingRunsParser.parse(page([run("WFR_1")], total: 12), plan: plan, index: 0)?.capped == true)
        #expect(WaitingRunsParser.parse(page([]), plan: plan, index: 0) == WaitingRunsParser.Page(runs: [], capped: false))
        for bad in [page([run("WFR_1", status: "queued")]), page([run("WFR_1", url: "https://evil.example/example/pet/actions/runs/7")]),
                    page([run("WFR_1", repo: "other/repo")]), page([run("bad id!")]),
                    page((0..<11).map { run("WFR_\($0)") }), json(["total_count": 1]), Data("not json".utf8)] {
            #expect(WaitingRunsParser.parse(bad, plan: plan, index: 0) == nil)
        }
    }

    @Test func pendingRequestsQueryIsBoundAndUsesVariablesOnly() {
        let plan = PendingRequestsPlan(runs: [waiting("WFR_1"), waiting("WFR_2", index: 1, repo: "example/tools")], expectedAccount: viewerA)
        let query = plan.arguments[5]
        #expect(query.contains("viewer { id login }") && query.contains("pendingDeploymentRequests(first: 10)")
                && query.contains("currentUserCanApprove"))
        #expect(!query.contains("WFR_"), "run IDs only as variables")
        #expect(Array(plan.arguments.suffix(4)) == ["-f", "run0=WFR_1", "-f", "run1=WFR_2"])
    }

    @Test func gitHubDecidesWhoCanApprove() {
        let plan = PendingRequestsPlan(runs: [waiting("WFR_mine"), waiting("WFR_theirs"), waiting("WFR_timer"), waiting("WFR_mixed")],
                                       expectedAccount: viewerA)
        let result = PendingRequestsParser.parse(pending([
            [request(true, environment: "production")],
            [request(false)],
            [],
            [request(false, environment: "staging"), request(true, environment: "production"), request(true, environment: "eu")],
        ]), plan: plan)
        #expect(result.complete && result.waitingOnOthers == 2, "not approvable by you: Waiting on others")
        // #148: those runs are listed under Waiting on others, saying why, never as approvals.
        #expect(result.waiting.map(\.id).sorted() == ["deploy:WFR_theirs", "deploy:WFR_timer"])
        #expect(result.waiting.allSatisfy { $0.kind == .deploymentApproval && $0.attention == DeploymentApprovals.waitingReason
                                            && $0.title == "Deploy is waiting for deployment approval" && $0.attentionKeys.isEmpty })
        #expect(DeploymentApprovals.waitingReason == "Waiting for deployment approval by others or a wait timer")
        #expect(result.items.map(\.id) == ["deploy:WFR_mine", "deploy:WFR_mixed"])
        #expect(result.items.allSatisfy { $0.kind == .deploymentApproval })
        #expect(result.items[0].title == "Deploy is waiting for your approval to production")
        #expect(result.items[1].title == "Deploy is waiting for your approval to eu, production")
        #expect(InboxEvent(item: result.items[0]).severity == .actionable && ItemKind.deploymentApproval.genericLabel == "Deployment approval")
    }

    @Test func unreadableRequestsFailClosed() {
        let plan = PendingRequestsPlan(runs: [waiting("WFR_1")], expectedAccount: viewerA)
        #expect(PendingRequestsParser.parse(pending([[request(nil)]]), plan: plan).issues == [.malformedRow("deploy0")])
        #expect(PendingRequestsParser.parse(pending([[request(1)]]), plan: plan).issues == [.malformedRow("deploy0")], "JSON 1 is not a boolean")
        let capped = PendingRequestsParser.parse(pending([[request(false)]], totals: [12]), plan: plan)
        #expect(capped.issues == [.capped("deploy0")] && !capped.complete)
        let vanished = PendingRequestsParser.parse(json(["data": ["viewer": ["id": viewerA.viewerID, "login": "d"], "run0": NSNull()]]), plan: plan)
        #expect(vanished.issues == [.malformedRow("deploy0")])
        let switched = PendingRequestsParser.parse(pending([[request(true)]], viewer: viewerB), plan: plan)
        #expect(switched.issues == [.identityMismatch] && switched.items.isEmpty)
    }

    @Test func clientQueriesEachRepositoryThenOnceForAllWaitingRunsAndNeverWrites() {
        let runner = Runner([CommandResult(exitCode: 0, stdout: page([])),
                             CommandResult(exitCode: 0, stdout: page([run("WFR_9", repo: "example/tools")])),
                             CommandResult(exitCode: 0, stdout: pending([[request(true)]]))])
        let result = client(runner).fetch(repositories: [pet, tools], expectedAccount: viewerA, budget: CommandBudget(timeout: 20))
        #expect(runner.calls.count == 3 && result.complete && result.items.map(\.id) == ["deploy:WFR_9"])
        #expect(result.items[0].repository == "example/tools" && result.successfulSources == 2)
        let all = runner.calls.flatMap { $0 }.joined(separator: " ")
        #expect(!all.contains("POST") && !all.contains("PUT") && !all.contains("pending_deployments") && !all.contains("approve "),
                "read-only: no approval or review request is ever sent")
        #expect(runner.calls.filter { $0.contains("GET") }.count == 2)
    }

    @Test func clientWithoutWaitingRunsMakesNoGraphQLRequest() {
        let runner = Runner([CommandResult(exitCode: 0, stdout: page([])), CommandResult(exitCode: 0, stdout: page([]))])
        let result = client(runner).fetch(repositories: [pet, tools], expectedAccount: viewerA, budget: CommandBudget(timeout: 20))
        #expect(runner.calls.count == 2 && result.viewer == nil && result.items.isEmpty && result.issues.isEmpty && result.successfulSources == 2)
    }

    @Test func clientKeepsReadableRepositoriesAndClassifiesTransport() {
        let notFound = CommandResult(exitCode: 1, stderr: Data("gh: Not Found (HTTP 404)".utf8))
        let partial = client(Runner([notFound, CommandResult(exitCode: 0, stdout: page([]))]))
            .fetch(repositories: [pet, tools], expectedAccount: viewerA, budget: CommandBudget(timeout: 20))
        #expect(partial.issues == [.targetUnavailable(0)] && partial.successfulSources == 1)
        let saml = CommandResult(exitCode: 1, stderr: Data("HTTP 403: Resource protected by organization SAML enforcement.".utf8))
        #expect(client(Runner([saml])).fetch(repositories: [pet], expectedAccount: viewerA, budget: CommandBudget(timeout: 20)).issues
                == [.accessDenied, .targetUnavailable(0)])
        #expect(client(Runner([CommandResult(exitCode: 4)])).fetch(repositories: [pet], expectedAccount: viewerA,
                                                                    budget: CommandBudget(timeout: 20)).issues == [.signedOut])
        let garbled = client(Runner([CommandResult(exitCode: 0, stdout: Data("{}".utf8))]))
            .fetch(repositories: [pet], expectedAccount: viewerA, budget: CommandBudget(timeout: 20))
        #expect(garbled.issues == [.malformedSource("deploy0")])
    }

    @Test func combiningBindsViewersAndKeepsTheWaitingCount() {
        let viewer = ScopeViewer(account: viewerA, login: "a")
        let deployments = ScopedPollResult(viewer: nil, items: [], issues: [], successfulSources: 2)
        let joined = ScopedPollResult.combiningActions(failures: nil, deployments: deployments, fallbackViewer: viewer)
        #expect(joined.complete && joined.viewer == viewer, "no waiting runs: bound to the inbox viewer, complete")
        let counted = ScopedPollResult.combiningActions(failures: ScopedPollResult(viewer: viewer, items: [], issues: [], successfulSources: 1),
            deployments: ScopedPollResult(viewer: viewer, items: [], issues: [], successfulSources: 1, waiting: (1...2).map {
                InboxItem(id: "deploy:RUN_\($0)", kind: .deploymentApproval, repository: "example/pet", title: "Deploy",
                          url: nil, updatedAt: Date(timeIntervalSince1970: Double($0)))
            }), fallbackViewer: viewer)
        #expect(counted.complete && counted.waitingOnOthers == 2 && counted.successfulSources == 2)
        let mismatch = ScopedPollResult.combiningActions(failures: ScopedPollResult(viewer: viewer, items: [], issues: [], successfulSources: 1),
            deployments: ScopedPollResult(viewer: ScopeViewer(account: viewerB, login: "b"), items: [], issues: [], successfulSources: 1),
            fallbackViewer: viewer)
        #expect(mismatch.issues == [.identityMismatch] && !mismatch.complete)
        let failed = ScopedPollResult.combiningActions(failures: .failure(.transport), deployments: deployments, fallbackViewer: viewer)
        #expect(!failed.complete && failed.issues == [.transport])
    }

    @Test func waitingNoteAndQualityLineCountRepositoriesOnce() {
        #expect(DeploymentApprovals.waitingNote(0, complete: true) == nil)
        #expect(DeploymentApprovals.waitingNote(1, complete: true) == "1 deployment is waiting for other reviewers or a wait timer")
        #expect(DeploymentApprovals.waitingNote(2, complete: false) == "At least 2 deployments are waiting for other reviewers or a wait timer")
        #expect(ActionsWatch.qualityLine(for: [.malformedSource("actions0"), .malformedSource("deploy0")], watched: 1)
                == "GitHub Actions: 1 repository unavailable; showing last known.")
    }

    /// QA LOW-1 on PR75: a deployments-only problem isn't reported as a workflow-failure problem.
    @Test func qualityLinesNameGitHubActionsNotOnePart() {
        for issues: [ScopedFetchIssue] in [[.malformedSource("deploy0")], [.targetUnavailable(0)], [.capped("deploy0")],
                                          [.rateLimited], [.accessDenied], [.transport], [.identityMismatch]] {
            let line = ActionsWatch.qualityLine(for: issues, watched: 1)
            #expect(line.hasPrefix("GitHub Actions") && !line.contains("Workflow failures"), "\(issues): \(line)")
        }
        #expect(ActionsWatch.notCheckedLine.hasPrefix("GitHub Actions"))
    }

    /// QA LOW-2 on PR75: a run waiting only on a wait timer (no request anyone can approve yet) is
    /// counted, and the line doesn't claim it waits on reviewers.
    @Test func waitTimerRunsAreCountedWithNeutralWording() {
        let plan = PendingRequestsPlan(runs: [waiting("WFR_timer"), waiting("WFR_reviewers")], expectedAccount: viewerA)
        let result = PendingRequestsParser.parse(pending([[], [request(false)]]), plan: plan)
        #expect(result.items.isEmpty && result.waitingOnOthers == 2)
        #expect(DeploymentApprovals.waitingNote(result.waitingOnOthers, complete: true)
                == "2 deployments are waiting for other reviewers or a wait timer")
    }

    @Test func settingIsOptInAndOldSettingsDecodeOff() throws {
        #expect(!PetSettings().watchDeploymentApprovals)
        #expect(try !JSONDecoder().decode(PetSettings.self, from: Data(#"{"schemaVersion":1,"watchWorkflowFailures":true}"#.utf8)).watchDeploymentApprovals)
    }
}
