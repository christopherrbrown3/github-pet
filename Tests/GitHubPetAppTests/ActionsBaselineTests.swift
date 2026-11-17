import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private final class FrozenClock: @unchecked Sendable {
    private let instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { instant }
}

/// Scripted Actions replies for the simulated account. Called from the poll's GCD thread.
private final class ScriptedActions: ActionsPolling, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: [String]] = [:]   // repository -> failing suite IDs
    private var failNext = false
    func set(_ repository: String, _ suites: [String]) { lock.lock(); failures[repository] = suites; lock.unlock() }
    func failCycle() { lock.lock(); failNext = true; lock.unlock() }
    func fetch(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        lock.lock(); defer { lock.unlock() }
        if failNext { failNext = false; return .failure(.transport) }
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

/// #10 MED-1 / LOW-1 through the real engine, baseline and unseen state (offline simulated launch).
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct ActionsBaselineTests {
    private let pet = try! MonitoringTarget(repository: "demo-a/pet")
    private let tools = try! MonitoringTarget(repository: "demo-a/tools")

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
    private func select(_ app: AppModel, _ targets: [MonitoringTarget]) async throws {
        let identity = try #require(app.monitoringScopeIdentity)
        #expect(app.applyRepositoryScope(try MonitoringScope(selected: targets), identity: identity,
                                         generation: app.monitoringScopeGeneration))
        try await settled(app)
    }
    private func actionRows(_ app: AppModel) -> [InboxItem] { app.items.filter { $0.id.hasPrefix("actions:") } }

    @Test func enablingTheWatchSeedsExistingFailuresSilentlyThenAnnouncesNewOnesOnce() async throws {
        let actions = ScriptedActions()
        let app = model(actions); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        try await select(app, [pet])
        actions.set("demo-a/pet", ["CS_existing"])
        let before = app.unseenCount
        app.settings.watchWorkflowFailures = true
        try await settled(app)
        #expect(actionRows(app).map(\.id) == ["actions:CS_existing"], "existing failures are shown")
        #expect(app.unseenCount == before, "…but seeded silently, like an initial sync")

        actions.set("demo-a/pet", ["CS_existing", "CS_new"])
        app.requestRefresh(); try await settled(app)
        #expect(app.unseenCount == before + 1, "a failure that appears afterwards announces once")
        app.requestRefresh(); try await settled(app)
        #expect(app.unseenCount == before + 1, "and only once")
    }

    @Test func addingAWatchedRepositorySeedsItsExistingFailuresSilently() async throws {
        let actions = ScriptedActions()
        let app = model(actions); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        try await select(app, [pet])
        app.settings.watchWorkflowFailures = true
        try await settled(app)
        let before = app.unseenCount
        actions.set("demo-a/tools", ["CS_tools_existing"])
        try await select(app, [pet, tools])
        #expect(actionRows(app).map(\.id) == ["actions:CS_tools_existing"])
        #expect(app.unseenCount <= before, "the newly watched repository's existing failure doesn't announce")
        #expect(!app.unseen.contains("actions:CS_tools_existing"))
    }

    @Test func anActionsErrorCycleKeepsTheLastKnownRowsAndIsPartial() async throws {
        let actions = ScriptedActions()
        let app = model(actions); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        try await select(app, [pet])
        actions.set("demo-a/pet", ["CS_known"])
        app.settings.watchWorkflowFailures = true
        try await settled(app)
        actions.failCycle()
        app.requestRefresh(); try await settled(app)
        let rows = actionRows(app)
        #expect(rows.map(\.id) == ["actions:CS_known"], "the previous failure stays")
        #expect(rows.first?.title.hasSuffix(ActionsLastKnown.staleSuffix) == true, "marked last known")
        #expect(app.dataState == .partial, "never a clean result while Actions are unverified")
        app.requestRefresh(); try await settled(app)
        #expect(actionRows(app).first?.title == "CI failed on main" && app.dataState != .partial, "fresh again next cycle")
    }
}
