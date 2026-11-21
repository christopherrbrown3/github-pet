import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private final class FrozenClock: @unchecked Sendable {
    private let instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { instant }
}

/// Scripted deployment replies for the simulated account (called from the poll's GCD thread).
private final class ScriptedDeployments: DeploymentPolling, @unchecked Sendable {
    private let lock = NSLock()
    private var approvable: [String] = []
    private var waiting = 0
    private(set) var calls = 0
    func set(approvable: [String], waiting: Int) { lock.lock(); self.approvable = approvable; self.waiting = waiting; lock.unlock() }
    func fetch(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        let items = approvable.map { run in
            InboxItem(id: "deploy:\(run)", kind: .deploymentApproval, repository: "demo-a/pet",
                      title: "Deploy is waiting for your approval to production",
                      url: URL(string: "https://github.com/demo-a/pet/actions/runs/7"), updatedAt: Date(timeIntervalSince1970: 1_763_200_000))
        }
        return ScopedPollResult(viewer: ScopeViewer(account: ScopeSimulation.accountA, login: "demo-a_sim"), items: items,
                                issues: [], successfulSources: repositories.count, waitingOnOthers: waiting)
    }
}
private final class CountingFailures: ActionsPolling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func fetch(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        lock.lock(); count += 1; lock.unlock()
        return ScopedPollResult(viewer: ScopeViewer(account: ScopeSimulation.accountA, login: "demo-a_sim"), items: [],
                                issues: [], successfulSources: repositories.count)
    }
}

/// #10 slice 2 through the real engine, unseen state and Actions quality (offline simulated launch).
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct DeploymentApprovalsAppTests {
    private let pet = try! MonitoringTarget(repository: "demo-a/pet")

    private func model(_ deployments: ScriptedDeployments, failures: CountingFailures = CountingFailures()) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        let clock = FrozenClock()
        return AppModel(options: options, runtime: AppModel.Runtime(now: { Date(timeIntervalSince1970: 1_763_208_000) },
            systemReducedMotion: { true }, schedulesTimers: false,
            repositoryBudget: { CommandBudget(timeout: 20, now: { clock.now() }) }, scopeSimulationHoldLimit: nil,
            actionsClient: failures, deploymentsClient: deployments))
    }
    private func settled(_ app: AppModel) async throws {
        await app.repositoryPollSettled()
        try #require(!app.repositoryFetchInFlight, "repository poll settled")
    }
    private func selectPet(_ app: AppModel) async throws {
        try await settled(app)
        let identity = try #require(app.monitoringScopeIdentity)
        #expect(app.applyRepositoryScope(try MonitoringScope(selected: [pet]), identity: identity,
                                         generation: app.monitoringScopeGeneration))
        try await settled(app)
    }
    private func approvals(_ app: AppModel) -> [InboxItem] { app.items.filter { $0.kind == .deploymentApproval } }

    @Test func approvalsSeedSilentlyAnnounceNewOnesOnceAndOthersAreOnlyCounted() async throws {
        let deployments = ScriptedDeployments(), failures = CountingFailures()
        let app = model(deployments, failures: failures); defer { app.cleanupScopeSimulation() }
        try await selectPet(app)
        deployments.set(approvable: ["WFR_existing"], waiting: 2)
        let before = app.unseenCount
        app.settings.watchDeploymentApprovals = true
        try await settled(app)
        #expect(approvals(app).map(\.id) == ["deploy:WFR_existing"], "existing approvals are shown")
        #expect(app.unseenCount == before, "…but seeded silently")
        #expect(app.deploymentsWaitingNote == "2 deployments are waiting for other reviewers or a wait timer")
        #expect(failures.calls == 0, "workflow failures stay off unless their own toggle is on")

        deployments.set(approvable: ["WFR_existing", "WFR_new"], waiting: 5)
        app.requestRefresh(); try await settled(app)
        #expect(app.unseenCount == before + 1, "a new approvable deployment announces once")
        #expect(app.deploymentsWaitingNote == "5 deployments are waiting for other reviewers or a wait timer", "the count changed without an alert")
        app.requestRefresh(); try await settled(app)
        #expect(app.unseenCount == before + 1)
        #expect(app.badge == String(app.items.count), "approvals are counted like other rows")
    }

    @Test func turningOnAnotherActionsPartReseedsSilently() async throws {
        let deployments = ScriptedDeployments(), failures = CountingFailures()
        let app = model(deployments, failures: failures); defer { app.cleanupScopeSimulation() }
        try await selectPet(app)
        deployments.set(approvable: ["WFR_1"], waiting: 0)
        app.settings.watchDeploymentApprovals = true
        try await settled(app)
        deployments.set(approvable: ["WFR_1", "WFR_2"], waiting: 0)
        app.settings.watchWorkflowFailures = true
        try await settled(app)
        #expect(failures.calls >= 1 && approvals(app).count == 2)
        #expect(!app.unseen.contains("deploy:WFR_2"), "a coverage change seeds silently, like turning the watch on")
        app.settings.watchDeploymentApprovals = false
        try await settled(app)
        #expect(approvals(app).isEmpty && app.deploymentsWaitingNote == nil, "turning it off removes rows and the count")
    }

    @Test func settingsNoteNamesTheSourceForDeploymentsOnly() {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--fixtures"], environment: [:])
        options.forcePlaceholder = true
        options.userDefaultsOverride = EphemeralDefaults(name: "dev.github-pet.tests.deployments.\(UUID().uuidString)")
        let deployments = ScriptedDeployments()
        let app = AppModel(options: options, runtime: AppModel.Runtime(schedulesTimers: false, loginItemBackend: InertLogin(),
                                                                       deploymentsClient: deployments))
        app.settings.watchDeploymentApprovals = true
        #expect(app.workflowWatchNote == "Deployment approvals are watched with the GitHub CLI source.")
        app.refresh()
        #expect(deployments.calls == 0, "the Demo fixture source never queries deployments")
    }
}

private struct InertLogin: LoginItemBackend {
    var status: LoginItemStatus { .disabled }
    func register() throws {}
    func unregister() throws {}
}
