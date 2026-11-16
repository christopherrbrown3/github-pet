import Foundation
import AppKit
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

/// #60: a Refresh during an in-flight poll is queued once (never dropped, never stacked), and
/// waking the Mac refreshes the live source once. Waits are explicit handshakes.
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct RefreshCoalescingTests {
    private let launch = Date(timeIntervalSince1970: 1_763_208_000)

    private func simulated() -> AppModel {
        var options = LaunchOptions.parse(arguments: ["app", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        return AppModel(options: options, runtime: AppModel.Runtime(
            now: { self.launch }, systemReducedMotion: { false }, schedulesTimers: false,
            scopeSimulationHoldLimit: nil, wakeCenter: NotificationCenter(), wakeRefreshDelay: .milliseconds(20)))
    }
    private func settled(_ model: AppModel) async throws {
        await model.repositoryPollSettled()
        try #require(!model.repositoryFetchInFlight, "current repository poll settled")
    }
    private func held(_ model: AppModel) async throws {
        await model.scopeRepliesHeld(1)
        try #require(model.simulatedHeldReplies == 1 && model.repositoryFetchInFlight)
    }
    /// Delivers held replies and awaits every repository poll they lead to.
    private func deliverAndSettle(_ model: AppModel) async throws {
        let received = model.receivedScopeReplies
        model.simulateScopeDeliver()
        await model.scopeRepliesReceived(received + 1)
        try await settled(model)
    }

    // FAIL before #60: the click during the held poll was a silent no-op (no follow-up request).
    @Test func refreshDuringInFlightPollRunsOnceAfterTheReplyLands() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        #expect(!app.refreshing)
        app.simulateScopeHold(); try await held(app)
        #expect(app.refreshing, "the Refresh control shows Refreshing… while a poll is in flight")
        let before = app.simulatedRequests.count
        app.requestRefresh(); app.requestRefresh(); app.requestRefresh()
        #expect(app.refreshQueued)
        #expect(app.simulatedRequests.count == before, "nothing new is launched while the poll is in flight")
        try await deliverAndSettle(app)
        #expect(app.simulatedRequests.count == before + 1, "exactly one queued refresh ran after the reply")
        #expect(!app.refreshQueued && !app.refreshing)
        app.refresh(); try await settled(app)
        #expect(app.simulatedRequests.count == before + 2, "nothing else was left queued")
    }

    @Test func refreshWithNothingInFlightRunsImmediately() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        let before = app.simulatedRequests.count
        app.requestRefresh()
        #expect(!app.refreshQueued)
        try await settled(app)
        #expect(app.simulatedRequests.count == before + 1)
    }

    @Test func scopeChangeDiscardsTheQueuedRefreshAndReplacesThePoll() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        app.simulateScopeHold(); try await held(app)
        let before = app.simulatedRequests.count
        app.requestRefresh()
        #expect(app.refreshQueued)
        app.simulateScopeApply(false); try await settled(app)
        #expect(app.simulatedRequests.count == before + 1, "Apply replaced the poll; the old queued click did not run")
        #expect(!app.refreshQueued)
        let received = app.receivedScopeReplies, discarded = app.discardedScopeReplies
        app.simulateScopeDeliver(); await app.scopeRepliesReceived(received + 1)
        #expect(app.discardedScopeReplies == discarded + 1, "the superseded reply is still discarded")
        #expect(app.simulatedRequests.count == before + 1 && !app.repositoryFetchInFlight)
    }

    @Test func accountChangeDropsTheQueuedRefresh() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        app.simulateScopeHold(); try await held(app)
        app.requestRefresh()
        let before = app.simulatedRequests.count
        app.simulateScopeAccount(true); try await settled(app)
        #expect(app.monitoringScopeIdentity == .github(ScopeSimulation.accountB))
        #expect(!app.refreshQueued)
        let launched = app.simulatedRequests.count - before
        let received = app.receivedScopeReplies
        app.simulateScopeDeliver(); await app.scopeRepliesReceived(received + 1)
        #expect(app.simulatedRequests.count - before == launched && !app.repositoryFetchInFlight,
                "the stale click never runs against the new account")
    }

    // FAIL before #60: there was no wake refresh.
    @Test func wakesCollapseIntoOneLiveRefresh() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        let before = app.simulatedRequests.count
        app.handleWake(); app.handleWake(); app.handleWake()
        await app.wakeRefreshSettled()
        try await settled(app)
        #expect(app.simulatedRequests.count == before + 1)
    }

    @Test func wakeDuringInFlightPollIsQueuedNotStacked() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        app.simulateScopeHold(); try await held(app)
        let before = app.simulatedRequests.count
        app.handleWake(); await app.wakeRefreshSettled()
        app.requestRefresh()
        #expect(app.refreshQueued && app.simulatedRequests.count == before)
        try await deliverAndSettle(app)
        #expect(app.simulatedRequests.count == before + 1)
    }

    @Test func wakeNeverRefreshesFixturesAndOnlyNormalLaunchesObserveIt() async throws {
        let sim = simulated(); defer { sim.cleanupScopeSimulation() }
        try await settled(sim)
        #expect(!sim.observesWake, "simulated launches never observe system wake")

        let center = NotificationCenter()
        var options = LaunchOptions.parse(arguments: ["app", "--fixtures", "--placeholder"], environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "refresh.wake.tests.\(UUID().uuidString)")
        let fixtures = AppModel(options: options, runtime: AppModel.Runtime(
            now: { self.launch }, systemReducedMotion: { false }, schedulesTimers: false,
            wakeCenter: center, wakeRefreshDelay: .milliseconds(20)))
        #expect(fixtures.observesWake)
        fixtures.injectEntitlementEvent()
        let rows = fixtures.items
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await Task.yield()
        fixtures.handleWake(); await fixtures.wakeRefreshSettled()
        #expect(fixtures.items == rows && fixtures.unseenCount == 1, "fixtures are not refreshed on wake")

        var snapshot = LaunchOptions.parse(arguments: ["app", "--render-snapshots",
            FileManager.default.temporaryDirectory.appendingPathComponent("wake-\(UUID().uuidString)").path, "--placeholder"],
            environment: [:])
        snapshot.userDefaultsOverride = EphemeralDefaults(name: "refresh.wake.snapshot.\(UUID().uuidString)")
        let render = AppModel(options: snapshot, runtime: AppModel.Runtime(
            now: { self.launch }, systemReducedMotion: { false }, schedulesTimers: false, wakeCenter: center))
        #expect(!render.observesWake, "snapshot launches never observe system wake")
    }
}
