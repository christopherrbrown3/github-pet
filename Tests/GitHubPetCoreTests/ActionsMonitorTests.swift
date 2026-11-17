import Foundation
import Testing
@testable import GitHubPetCore

private let viewerA = try! ScopeAccount(viewerID: "U_actions_A")
private let viewerB = try! ScopeAccount(viewerID: "U_actions_B")
private let pet = try! MonitoringTarget(repository: "example/pet")
private let tools = try! MonitoringTarget(repository: "example/tools")
private let org = try! MonitoringTarget(organization: "example")

private func suite(_ id: String = "CS_1", status: String = "COMPLETED", conclusion: Any? = "FAILURE",
                   creator: String? = "U_someone", repo: String = "example/pet", workflow: String = "CI",
                   attempt: Int = 1) -> [String: Any] {
    [
        "id": id, "status": status, "conclusion": conclusion ?? NSNull(), "updatedAt": "2026-11-17T10:00:00Z",
        "creator": creator.map { ["id": $0] as Any } ?? NSNull(),
        "workflowRun": ["url": "https://github.com/\(repo)/actions/runs/42", "runAttempt": attempt, "workflow": ["name": workflow]],
    ]
}
private func repository(_ name: String = "example/pet", suites: [[String: Any]] = [], total: Int? = nil,
                        archived: Bool = false, branch: Bool = true) -> [String: Any] {
    var value: [String: Any] = ["nameWithOwner": name, "isArchived": archived]
    value["defaultBranchRef"] = branch ? [
        "name": "main",
        "target": ["__typename": "Commit", "oid": "abc", "checkSuites": ["totalCount": total ?? suites.count, "nodes": suites]],
    ] as Any : NSNull()
    return value
}
private func response(_ repos: [Any], viewer: ScopeAccount? = viewerA, errors: [[String: Any]]? = nil) -> Data {
    var data: [String: Any] = [:]
    if let viewer { data["viewer"] = ["id": viewer.viewerID, "login": "fixture-user"] }
    for (index, repo) in repos.enumerated() { data["repo\(index)"] = repo }
    var envelope: [String: Any] = ["data": data]
    if let errors { envelope["errors"] = errors }
    return try! JSONSerialization.data(withJSONObject: envelope)
}
private func parse(_ repos: [Any], targets: [MonitoringTarget] = [pet], viewer: ScopeAccount? = viewerA,
                   errors: [[String: Any]]? = nil) -> ScopedPollResult {
    ActionsResponseParser.parse(response(repos, viewer: viewer, errors: errors),
                                plan: ActionsQueryPlan(repositories: targets, expectedAccount: viewerA))
}

private final class Runner: CommandRunner, @unchecked Sendable {
    var replies: [CommandResult]
    private(set) var calls: [[String]] = []
    init(_ replies: [CommandResult]) { self.replies = replies }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append(arguments); return replies.removeFirst()
    }
}
private func client(_ runner: Runner) -> ActionsGhClient {
    ActionsGhClient(locator: GhLocator(environment: [GhLocator.overrideVariable: "/fixture/gh"], isExecutable: { _ in true }),
                    runner: runner)
}

@Suite struct ActionsMonitorTests {
    @Test func planSendsOwnersAndNamesOnlyAsVariablesForTheActionsApp() {
        let plan = ActionsQueryPlan(repositories: [pet, org, tools], expectedAccount: viewerA)
        #expect(plan.repositories == [pet, tools], "organizations are not expanded in slice 1")
        #expect(Array(plan.arguments.prefix(4)) == ["api", "graphql", "--hostname", "github.com"])
        let query = plan.arguments[5]
        #expect(query.contains("appId: 15368") && query.contains("checkSuites(first: 20"))
        #expect(query.contains("viewer { id login }") && query.contains("creator { id }"))
        #expect(!query.contains("example") && !query.contains("pet"), "no target text in the query")
        #expect(Array(plan.arguments.suffix(8)) == ["-f", "owner0=example", "-f", "name0=pet", "-f", "owner1=example", "-f", "name1=tools"])
    }

    @Test func coverageWatchesSelectedRepositoriesOnly() throws {
        #expect(ActionsWatch.coverage(enabled: false, scope: try MonitoringScope(selected: [pet])) == .off)
        #expect(ActionsWatch.coverage(enabled: true, scope: .everything) == .needsRepositories(ActionsWatch.needsRepositoriesNote))
        #expect(ActionsWatch.coverage(enabled: true, scope: nil) == .needsRepositories(ActionsWatch.needsRepositoriesNote))
        #expect(ActionsWatch.coverage(enabled: true, scope: try MonitoringScope(selected: [org])) == .needsRepositories(ActionsWatch.needsRepositoriesNote))
        #expect(ActionsWatch.coverage(enabled: true, scope: try MonitoringScope(selected: [pet, tools])) == .repositories([pet, tools], note: nil))
        #expect(ActionsWatch.coverage(enabled: true, scope: try MonitoringScope(selected: [org, pet]))
                == .repositories([pet], note: ActionsWatch.organizationsNotWatchedNote))
    }

    @Test func onlyCompletedGenuineFailuresAreItems() {
        let failing = ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE"]
        let ignored: [(String, Any?)] = [("COMPLETED", "CANCELLED"), ("COMPLETED", "SKIPPED"), ("COMPLETED", "NEUTRAL"),
                                         ("COMPLETED", "STALE"), ("COMPLETED", "SUCCESS"), ("COMPLETED", "ACTION_REQUIRED"),
                                         ("IN_PROGRESS", "FAILURE"), ("QUEUED", nil), ("WAITING", nil)]
        let suites = failing.enumerated().map { suite("CS_f\($0.offset)", conclusion: $0.element) }
            + ignored.enumerated().map { suite("CS_i\($0.offset)", status: $0.element.0, conclusion: $0.element.1) }
        let result = parse([repository(suites: suites)])
        #expect(result.complete && result.successfulSources == 1)
        #expect(Set(result.items.map(\.id)) == ["actions:CS_f0", "actions:CS_f1", "actions:CS_f2"])
        let first = result.items.first { $0.id == "actions:CS_f0" }
        #expect(first?.title == "CI failed on main" && first?.repository == "example/pet")
        #expect(first?.url?.absoluteString == "https://github.com/example/pet/actions/runs/42")
        // A watched repository with nothing failing is a verified, complete empty result.
        let clean = parse([repository(suites: [suite(conclusion: "SUCCESS")])])
        #expect(clean.complete && clean.items.isEmpty)
    }

    @Test func failuresAreActionableUnlessTheViewerTriggeredThem() {
        let result = parse([repository(suites: [suite("CS_mine", creator: viewerA.viewerID), suite("CS_theirs"), suite("CS_nobody", creator: nil)])])
        let kinds = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0.kind) })
        #expect(kinds == ["actions:CS_mine": .ciFailure, "actions:CS_theirs": .workflowFailure, "actions:CS_nobody": .workflowFailure])
        #expect(InboxEvent(item: result.items.first { $0.kind == .workflowFailure }!).severity == .actionable)
        #expect(InboxEvent(item: result.items.first { $0.kind == .ciFailure }!).severity == .critical)
        #expect(ItemKind.workflowFailure.genericLabel == "Workflow failure")
    }

    @Test func reRunsKeepTheirItemAndNewCommitsAreNewItems() {
        let first = parse([repository(suites: [suite("CS_commit1", attempt: 1)])])
        let rerun = parse([repository(suites: [suite("CS_commit1", attempt: 2)])])
        let next = parse([repository(suites: [suite("CS_commit2")])])
        #expect(first.items.map(\.id) == rerun.items.map(\.id), "a failing re-run is the same item: no second alert")
        #expect(first.items.map(\.id) != next.items.map(\.id), "a new failing commit alerts once")
    }

    @Test func capsAndPerRepositoryProblemsAreVisiblyPartial() {
        let capped = parse([repository(suites: (0..<20).map { suite("CS_\($0)") }, total: 25)])
        #expect(!capped.complete && capped.issues == [.capped("actions0")] && capped.items.count == 20)
        let mixed = parse([NSNull(), repository("example/tools", suites: [suite(repo: "example/tools")])], targets: [pet, tools])
        #expect(!mixed.complete && mixed.issues == [.targetUnavailable(0)] && mixed.items.count == 1, "the readable repository stays")
        #expect(parse([repository("other/pet")]).issues == [.malformedTarget(0)])
        let archived = parse([repository(suites: [suite()], archived: true)])
        #expect(archived.complete && archived.items.isEmpty, "archived repositories are not watched")
        #expect(parse([repository(branch: false)]).complete, "no default branch yet: nothing to watch")
        var broken = repository(); broken["defaultBranchRef"] = ["name": "main", "target": ["__typename": "Tree"]]
        #expect(parse([broken]).issues == [.malformedSource("actions0")])
        let tooMany = repository(suites: (0..<21).map { suite("CS_\($0)") })
        #expect(parse([tooMany]).issues == [.malformedSource("actions0")], "more nodes than requested is malformed")
    }

    @Test func unsafeOrForeignRunLinksAreRejected() {
        for url in ["https://evil.example/example/pet/actions/runs/1", "http://github.com/example/pet/actions/runs/1",
                    "https://github.com/other/repo/actions/runs/1", "https://github.com/example/pet/pull/1"] {
            var bad = suite(); bad["workflowRun"] = ["url": url, "runAttempt": 1, "workflow": ["name": "CI"]]
            let result = parse([repository(suites: [bad])])
            #expect(result.items.isEmpty && result.issues == [.malformedRow("actions0")], "\(url)")
        }
    }

    @Test func identityAndErrorEnvelopesFailClosed() {
        let switched = parse([repository(suites: [suite()])], viewer: viewerB)
        #expect(switched.items.isEmpty && switched.issues == [.identityMismatch])
        let missing = parse([repository(suites: [suite()])], viewer: nil)
        #expect(missing.viewer == nil && missing.issues == [.viewerUnavailable] && missing.items.isEmpty)
        let shapes: [([String: Any], ScopedFetchIssue)] = [
            (["type": "FORBIDDEN", "path": ["repo0"], "message": "Resource protected by organization SAML enforcement."], .accessDenied),
            (["type": "RATE_LIMITED", "message": "API rate limit exceeded"], .rateLimited),
            (["message": "fixture failure"], .graphQLError),
        ]
        for (error, issue) in shapes {
            let result = parse([NSNull()], errors: [error])
            #expect(!result.complete && result.issues.first == issue, "\(error)")
        }
    }

    @Test func clientClassifiesTransportWithoutHidingReadableRepositories() {
        let saml = Data("GraphQL: Resource protected by organization SAML enforcement. (repo0)".utf8)
        let partial = response([NSNull(), repository("example/tools", suites: [suite(repo: "example/tools")])])
        let both = client(Runner([CommandResult(exitCode: 1, stdout: partial, stderr: saml)]))
            .fetch(repositories: [pet, tools], expectedAccount: viewerA, budget: CommandBudget(timeout: 20))
        #expect(both.items.count == 1 && both.issues.contains(.accessDenied) && !both.complete)
        #expect(client(Runner([CommandResult(exitCode: 1, stderr: saml)]))
                .fetch(repositories: [pet], expectedAccount: viewerA, budget: CommandBudget(timeout: 20)).issues == [.accessDenied])
        #expect(client(Runner([CommandResult(exitCode: 4)]))
                .fetch(repositories: [pet], expectedAccount: viewerA, budget: CommandBudget(timeout: 20)).issues == [.signedOut])
        #expect(client(Runner([CommandResult(exitCode: 1, stderr: Data("API rate limit exceeded".utf8))]))
                .fetch(repositories: [pet], expectedAccount: viewerA, budget: CommandBudget(timeout: 20)).issues == [.rateLimited])
        let network = client(Runner([CommandResult(exitCode: 1, stdout: response([repository(suites: [suite()])]),
                                                   stderr: Data("network unavailable".utf8))]))
            .fetch(repositories: [pet], expectedAccount: viewerA, budget: CommandBudget(timeout: 20))
        #expect(network.issues == [.transport] && !network.complete, "a failed gh exit never certifies a clean result")
        let nothing = Runner([])
        let none = client(nothing).fetch(repositories: [org], expectedAccount: viewerA, budget: CommandBudget(timeout: 20))
        #expect(nothing.calls.isEmpty && none.items.isEmpty && none.issues.isEmpty, "no watched repository: no request")
    }

    @Test func mergingKeepsTheInboxAndMarksActionsProblemsPartial() {
        let inbox = ScopedPollResult(viewer: ScopeViewer(account: viewerA, login: "a"), items: [], issues: [], successfulSources: 2, hidden: 3)
        let failure = InboxItem(id: "actions:CS_1", kind: .workflowFailure, repository: "example/pet", title: "CI failed on main",
                                url: URL(string: "https://github.com/example/pet/actions/runs/1"), updatedAt: Date(timeIntervalSince1970: 0))
        let actions = ScopedPollResult(viewer: ScopeViewer(account: viewerA, login: "a"), items: [failure], issues: [], successfulSources: 1)
        let merged = inbox.mergingActions(actions)
        #expect(merged.complete && merged.items == [failure] && merged.hidden == 3 && merged.successfulSources == 3)
        let failed = inbox.mergingActions(.failure(.signedOut))
        #expect(!failed.complete && failed.issues == [.transport] && failed.hidden == 0, "Actions unverified: Partial, never all clear")
        let other = inbox.mergingActions(ScopedPollResult(viewer: ScopeViewer(account: viewerB, login: "b"), items: [failure], issues: [], successfulSources: 1))
        #expect(other.issues == [.identityMismatch] && other.items.isEmpty)
        let empty = inbox.mergingActions(ScopedPollResult(viewer: nil, items: [], issues: [], successfulSources: 0))
        #expect(empty == inbox)
    }

    /// PR71 (#9): the inbox poll's "waiting on others" count is informational and independent of
    /// Actions, so every merge outcome keeps it.
    @Test func mergingCarriesTheInboxWaitingOnOthersCount() {
        let viewer = ScopeViewer(account: viewerA, login: "a")
        let inbox = ScopedPollResult(viewer: viewer, items: [], issues: [], successfulSources: 2, hidden: 1, waitingOnOthers: 2)
        let failure = InboxItem(id: "actions:CS_1", kind: .workflowFailure, repository: "example/pet", title: "CI failed on main",
                                url: URL(string: "https://github.com/example/pet/actions/runs/1"), updatedAt: Date(timeIntervalSince1970: 0))
        let clean = inbox.mergingActions(ScopedPollResult(viewer: viewer, items: [failure], issues: [], successfulSources: 1))
        let failed = inbox.mergingActions(.failure(.transport))
        let switched = inbox.mergingActions(ScopedPollResult(viewer: ScopeViewer(account: viewerB, login: "b"), items: [],
                                                             issues: [], successfulSources: 1))
        let none = inbox.mergingActions(ScopedPollResult(viewer: nil, items: [], issues: [], successfulSources: 0))
        for (name, merged) in [("clean", clean), ("failed", failed), ("switched", switched), ("none", none)] {
            #expect(merged.waitingOnOthers == 2, "\(name)")
        }
        #expect(none == inbox)
    }

    /// QA LOW-2 on PR72: a value outside GitHub's known enums fails closed instead of being skipped.
    @Test func unknownStatusOrConclusionMarksTheRowMalformed() {
        for (status, conclusion) in [("COMPLETED", "FAILED_NEW_KIND"), ("FINISHED", "FAILURE"), ("COMPLETED", nil)] as [(String, String?)] {
            let result = parse([repository(suites: [suite(status: status, conclusion: conclusion)])])
            #expect(!result.complete && result.issues == [.malformedRow("actions0")] && result.items.isEmpty, "\(status) \(conclusion ?? "nil")")
        }
        var numeric = suite(); numeric["conclusion"] = 1
        #expect(parse([repository(suites: [numeric])]).issues == [.malformedRow("actions0")])
        #expect(parse([repository(suites: [suite(status: "PENDING", conclusion: nil)])]).complete, "known in-progress states stay quiet")
    }

    /// QA MED-1 on PR72: the watched repositories are part of the baseline key, so turning the
    /// watch on (or changing what it covers) re-baselines silently; without it the key is unchanged.
    @Test func baselineKeyFollowsTheActionsCoverage() throws {
        let scope = try MonitoringScope(selected: [pet, tools])
        let identity = ScopeIdentity.github(viewerA)
        let off = BaselineKey(source: .githubCLI, identity: identity, scope: scope)
        #expect(BaselineKey(source: .githubCLI, identity: identity, scope: scope, actionsRepositories: []) == off)
        let one = BaselineKey(source: .githubCLI, identity: identity, scope: scope, actionsRepositories: [pet])
        let both = BaselineKey(source: .githubCLI, identity: identity, scope: scope, actionsRepositories: [tools, pet])
        #expect(one != off && both != one)
        #expect(both == BaselineKey(source: .githubCLI, identity: identity, scope: scope, actionsRepositories: [pet, tools]), "order-free")
    }

    /// QA LOW-1 on PR72: a cycle that can't read a repository keeps its previous rows, marked.
    @Test func lastKnownRowsSurviveAnErrorCycleOnlyForTheSameAccountAndRepositories() {
        let cache = ActionsLastKnown()
        let viewer = ScopeViewer(account: viewerA, login: "a")
        func failure(_ id: String, _ repo: String) -> InboxItem {
            InboxItem(id: "actions:\(id)", kind: .workflowFailure, repository: repo, title: "CI failed on main",
                      url: URL(string: "https://github.com/\(repo)/actions/runs/1"), updatedAt: Date(timeIntervalSince1970: 0))
        }
        let fresh = ScopedPollResult(viewer: viewer, items: [failure("A", "example/pet"), failure("B", "example/tools")],
                                     issues: [], successfulSources: 2)
        #expect(cache.apply(fresh, repositories: [pet, tools], account: viewerA) == fresh)
        let down = cache.apply(.failure(.transport), repositories: [pet, tools], account: viewerA)
        #expect(down.issues == [.transport] && down.items.map(\.id) == ["actions:A", "actions:B"])
        #expect(down.items.allSatisfy { $0.title == "CI failed on main" + ActionsLastKnown.staleSuffix })
        // One repository unreadable: only its rows carry over; the readable one is fresh.
        let half = ScopedPollResult(viewer: viewer, items: [], issues: [.targetUnavailable(1)], successfulSources: 1)
        #expect(cache.apply(half, repositories: [pet, tools], account: viewerA).items.map(\.id) == ["actions:B"])
        // A different account or watched set never inherits rows.
        #expect(cache.apply(.failure(.transport), repositories: [pet, tools], account: viewerB).items.isEmpty)
        let again = ActionsLastKnown()
        _ = again.apply(fresh, repositories: [pet, tools], account: viewerA)
        #expect(again.apply(.failure(.transport), repositories: [pet], account: viewerA).items.isEmpty)
        #expect(again.apply(.failure(.identityMismatch, viewer: viewer), repositories: [pet], account: viewerA).items.isEmpty)
    }

    @Test func settingIsOptInAndOldSettingsDecodeOff() throws {
        #expect(!PetSettings().watchWorkflowFailures)
        let old = try JSONDecoder().decode(PetSettings.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(!old.watchWorkflowFailures)
        var on = PetSettings(); on.watchWorkflowFailures = true
        #expect(try JSONDecoder().decode(PetSettings.self, from: JSONEncoder().encode(on)).watchWorkflowFailures)
    }
}
