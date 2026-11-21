import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private final class FrozenClock: @unchecked Sendable {
    private let instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { instant }
}

/// Scripted Actions replies for the simulated account (called from the poll's GCD thread).
private final class ScriptedActions: ActionsPolling, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: [String]] = [:]
    func set(_ repository: String, _ suites: [String]) { lock.lock(); failures[repository] = suites; lock.unlock() }
    func fetch(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        lock.lock(); defer { lock.unlock() }
        let items = repositories.flatMap { target -> [InboxItem] in
            let name = "\(target.owner)/\(target.name!)"
            return (failures[name] ?? []).map { suite in
                InboxItem(id: "actions:\(suite)", kind: .workflowFailure, repository: name, title: "CI failed on main",
                          url: URL(string: "https://github.com/\(name)/actions/runs/1"), updatedAt: Date(timeIntervalSince1970: 1_763_200_000))
            }
        }
        return ScopedPollResult(viewer: ScopeViewer(account: ScopeSimulation.accountA, login: "demo-a_sim"), items: items,
                                issues: [], successfulSources: repositories.count)
    }
}

/// #10 follow-ups: what the badge and status say beside workflow-failure rows, and relaunch.
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct ActionsDisplayStateTests {
    private let pet = try! MonitoringTarget(repository: "demo-a/pet")

    private func model(_ actions: ScriptedActions) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        let clock = FrozenClock()
        return AppModel(options: options, runtime: AppModel.Runtime(now: { Date(timeIntervalSince1970: 1_763_208_000) },
            systemReducedMotion: { true }, schedulesTimers: false,
            repositoryBudget: { CommandBudget(timeout: 20, now: { clock.now() }) }, scopeSimulationHoldLimit: nil,
            actionsClient: actions))
    }
    private func settled(_ app: AppModel) async throws {
        await app.repositoryPollSettled()
        try #require(!app.repositoryFetchInFlight, "repository poll settled")
    }
    private func watchPet(_ app: AppModel) async throws {
        try await settled(app)
        let identity = try #require(app.monitoringScopeIdentity)
        #expect(app.applyRepositoryScope(try MonitoringScope(selected: [pet]), identity: identity,
                                         generation: app.monitoringScopeGeneration))
        try await settled(app)
        app.settings.watchWorkflowFailures = true
        try await settled(app)
    }

    /// A hidden-only inbox (#35) beside workflow-failure rows: the badge counts the rows and the
    /// status reflects them, instead of "0" and "No visible items".
    @Test func hiddenOnlyInboxWithFailureRowsCountsThem() async throws {
        let actions = ScriptedActions()
        let app = model(actions); defer { app.cleanupScopeSimulation() }
        try await watchPet(app)
        app.simulateScopeVisibility(.hiddenOnly); try await settled(app)
        #expect(app.dataState == .hiddenOnly(3) && app.badge == "0", "control: no failure rows yet")

        actions.set("demo-a/pet", ["CS_1"])
        app.requestRefresh(); try await settled(app)
        #expect(app.items.map(\.id) == ["actions:CS_1"])
        #expect(app.dataState == .ready && app.badge == "1", "the failure row is counted")
        #expect(!app.dataState.statusText.hasPrefix("No visible items"))
        #expect(app.hiddenResultsNote == "3 matching items aren't visible to your account", "hidden matches still reported")

        actions.set("demo-a/pet", [])
        app.requestRefresh(); try await settled(app)
        #expect(app.dataState == .hiddenOnly(3) && app.badge == "0", "back to hidden-only once the failure is gone")
    }

    /// QA: after a relaunch the Actions watch starts a fresh baseline, so failures that already
    /// exist seed silently; a failure that appears afterwards announces once.
    @Test func relaunchSeedsExistingWorkflowFailuresSilently() async throws {
        let actions = ScriptedActions()
        actions.set("demo-a/pet", ["CS_before_quit"])
        let first = model(actions)
        try await watchPet(first)
        first.cleanupScopeSimulation()

        let relaunch = model(actions); defer { relaunch.cleanupScopeSimulation() }
        try await watchPet(relaunch)
        #expect(relaunch.items.contains { $0.id == "actions:CS_before_quit" })
        #expect(relaunch.unseenCount == 0 && !relaunch.unseen.contains("actions:CS_before_quit"), "seeded silently after relaunch")
        actions.set("demo-a/pet", ["CS_before_quit", "CS_after_relaunch"])
        relaunch.requestRefresh(); try await settled(relaunch)
        relaunch.requestRefresh(); try await settled(relaunch)
        #expect(relaunch.unseenCount == 1 && relaunch.unseen.contains("actions:CS_after_relaunch"), "a later failure announces once")
    }
}
