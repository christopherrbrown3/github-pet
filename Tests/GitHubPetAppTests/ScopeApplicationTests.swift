import Foundation
import AppKit
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private final class FixtureBudgetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
}

@Suite(.serialized) @MainActor struct ScopeApplicationTests {
    private final class Inputs {
        var date = Date(timeIntervalSince1970: 1_763_208_000)
        var reducedMotion = false
        let budgetClock = FixtureBudgetClock()
        var expireNextBudget = false
    }
    private func model(inputs: Inputs = Inputs()) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        return AppModel(options: options, runtime: AppModel.Runtime(now: { inputs.date },
            systemReducedMotion: { inputs.reducedMotion }, schedulesTimers: false,
            repositoryBudget: {
                let timeout: TimeInterval = inputs.expireNextBudget ? 0 : 20
                inputs.expireNextBudget = false
                return CommandBudget(timeout: timeout, now: { inputs.budgetClock.now() })
            }))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() && ContinuousClock.now < end { await Task.yield() }
        try #require(predicate(), "bounded simulated completion")
    }
    private func settled(_ model: AppModel) async throws { try await wait { !model.repositoryFetchInFlight } }

    @Test func hostMotionIsRecordedAndSuppressionNeverErasesSourceTruth() async throws {
        // One CI diagnostic: the old fixture read this live host value implicitly.
        print("Scope fixture host systemReduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); attention assertions use explicit inputs")
        let inputs = Inputs(); inputs.reducedMotion = true
        let app = model(inputs: inputs); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        #expect(app.dataState == .ready && app.items.count == 1 && app.lastSuccess != nil, "new-event test requires a complete initial baseline")
        print("Scope fixture baseline before injection: state=\(app.dataState), rows=\(app.items.count), scopeQuality=\(app.scopeQuality ?? "none")")
        app.simulateScopeInject(); try await settled(app)
        app.injectServiceIncident(.major)
        #expect(app.unseenCount == 1)
        #expect(!app.unseenIncidents.isEmpty)
        #expect(app.incidentMarker?.tier == .major && app.showsAlertIcon)
        #expect(app.markerBurst == nil)
        #expect(app.activeClip == nil, "system motion legitimately suppresses both gestures")
        let unseen = app.unseenIncidents
        app.simulateScopeApply(false); try await settled(app)
        #expect(app.unseenIncidents == unseen)
        #expect(app.incidentMarker?.tier == .major && app.showsAlertIcon)
        #expect(app.markerBurst == nil)
        #expect(app.activeClip == nil)
        inputs.reducedMotion = false
        app.refresh(); try await settled(app)
        #expect(app.activeClip == nil && app.markerBurst == nil, "turning motion back on never replays")
    }
    @Test func expiredGestureLeavesRowsAndUnseenIntactAndLateReplyStillCannotLand() async throws {
        let inputs = Inputs(), app = model(inputs: inputs)
        defer { app.cleanupScopeSimulation() }
        try await settled(app)
        app.simulateScopeHold(); try await wait { app.simulatedHeldReplies == 1 }
        app.simulateScopeApply(false); try await settled(app)
        app.simulateScopeInject(); try await settled(app)
        #expect(app.items.count == 3 && app.unseenCount == 1 && app.activeClip?.origin == .repository)
        inputs.date.addTimeInterval(8) // deterministic analogue of a stalled cooperative executor
        app.tick()
        #expect(app.activeClip == nil && app.unseenCount == 1 && app.items.count == 3)
        app.simulateScopeDeliver(); try await wait { app.discardedScopeReplies == 1 }
        #expect(app.activeClip == nil && app.unseenCount == 1 && app.items.count == 3)
    }
    @Test func scopeApplyPreservesIncidentUnseenAndStaticAttentionAcrossMotionAndExpiry() async throws {
        for reduced in [false, true] {
            for elapsed in [0.0, 8.0] {
                let inputs = Inputs(); inputs.reducedMotion = reduced
                let app = model(inputs: inputs); defer { app.cleanupScopeSimulation() }
                try await settled(app)
                app.injectServiceIncident(.major)
                let unseen = app.unseenIncidents, incidents = app.serviceIncidents
                let state = app.serviceState, lastSuccess = app.serviceLastSuccess
                #expect(!unseen.isEmpty, "new incident must remain unseen irrespective of motion")
                if reduced { #expect(app.markerBurst == nil) } else { #expect(app.markerBurst != nil) }
                inputs.date.addTimeInterval(elapsed)
                app.tick()
                let burst = app.markerBurst, clip = app.activeClip
                if reduced || elapsed == 8 { #expect(app.markerPhase(at: inputs.date, reduced: reduced) == .still) }
                app.simulateScopeApply(false); try await settled(app)
                #expect(app.unseenIncidents == unseen, "Apply cannot acknowledge incidents")
                #expect(app.serviceIncidents == incidents)
                #expect(app.serviceState == state && app.serviceLastSuccess == lastSuccess)
                #expect(app.incidentMarker?.tier == .major)
                #expect(app.showsAlertIcon, "static incident attention survives even without animation")
                #expect(app.markerBurst == burst)
                #expect(app.activeClip == clip, "scope Apply cannot restart/clear an incident gesture")
                if reduced || elapsed == 8 { #expect(app.markerPhase(at: inputs.date, reduced: reduced) == .still) }
            }
        }
    }
    @Test func timedOutInitialFetchMakesNextSnapshotASilentBaselineThenNewOnce() async throws {
        let inputs = Inputs(); inputs.reducedMotion = true; inputs.expireNextBudget = true
        let app = model(inputs: inputs); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        #expect(app.items.isEmpty && app.lastSuccess == nil)
        #expect(app.dataState != .empty && app.scopeQuality?.contains("time limit") == true)
        print("Deadline reproduction initial state=\(app.dataState), rows=\(app.items.count), quality=\(app.scopeQuality ?? "none")")
        app.simulateScopeInject(); try await settled(app)
        #expect(app.items.count == 2 && app.dataState == .ready)
        #expect(app.unseenCount == 0, "first successful reply after timeout establishes a silent baseline")
        app.simulateScopeInject(); try await settled(app)
        #expect(app.items.count == 3 && app.unseenCount == 1, "motion does not erase a genuinely new comparable event")
        #expect(app.activeClip == nil)
    }
    @Test func actualHostMotionPathInNormalFixturesRetainsBothUnseenSources() {
        let name = "scope.host-motion.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let options = LaunchOptions.parse(arguments: ["app", "--fixtures", "--placeholder", "--defaults-suite", name], environment: [:])
        // Keep the production NSWorkspace provider: CI reports this actual host input true.
        let app = AppModel(options: options, runtime: AppModel.Runtime(
            now: { Date(timeIntervalSince1970: 1_763_208_000) }, schedulesTimers: false))
        #expect(!app.simulatesScope && app.dataState == .ready)
        #expect(app.effectiveReducedMotion == NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        app.injectEntitlementEvent()
        #expect(app.unseenCount == 1)
        app.injectServiceIncident(.major)
        #expect(!app.unseenIncidents.isEmpty)
        #expect(app.showsAlertIcon && app.incidentMarker?.tier == .major)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(app.activeClip == nil)
            #expect(app.markerBurst == nil)
        }
        print("Actual host motion=\(app.effectiveReducedMotion), normal production fixture path: repository unseen=\(app.unseenCount), incident unseen=\(app.unseenIncidents.count)")
    }
    @Test func launchFlagIsExplicitAndIsolatedAndKnownSelectedIsFirstRequest() async throws {
        #expect(!LaunchOptions.parse(arguments: ["app"], environment: [:]).simulatesMonitoringScope)
        let options = LaunchOptions.parse(arguments: ["app", "--simulate-monitoring-scope", "--defaults-suite", "real-domain"], environment: [:])
        #expect(options.defaultsSuite?.hasPrefix("dev.github-pet.scope-simulation.") == true)
        let snapshots = LaunchOptions.parse(arguments: ["app", "--simulate-monitoring-scope", "--render-snapshots", "/tmp/scope-unused"], environment: [:])
        #expect(!snapshots.simulatesMonitoringScope && snapshots.forcedSource == "fixtures")
        let before = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("GitHubPet.monitoring-scope") }
        let app = model(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        #expect(app.simulatesScope && app.isDemo && app.items.count == 1 && app.items.allSatisfy(\.isDemo))
        #expect(app.simulatedRequests.first?.scope == ScopeSimulation.selectedA)
        #expect(app.simulatedRequests.first?.expected == ScopeSimulation.accountA)
        #expect(app.unseenCount == 0 && app.activeClip == nil)
        #expect(NSDictionary(dictionary: before).isEqual(to: UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("GitHubPet.monitoring-scope") }))
    }
    @Test func unknownBootstrapIsDiscardedAndAccountsRoundTripSilently() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        app.simulateScopeReload(forgetViewer: true); try await settled(app)
        #expect(app.simulatedRequests.suffix(2).map(\.scope) == [.everything, ScopeSimulation.selectedA])
        #expect(app.items.count == 1 && !app.items.contains { $0.repository == "demo-outside/pet" })
        app.simulateScopeAccount(true); try await settled(app)
        #expect(app.items.count == 1 && app.items.allSatisfy { $0.repository == "demo-b/pet" })
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedB && app.unseenCount == 0)
        app.simulateScopeAccount(false); try await settled(app)
        #expect(app.items.count == 1 && app.items.allSatisfy { $0.repository == "demo-a/pet" })
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA && app.unseenCount == 0 && app.activeClip == nil)
    }
    @Test func lateReplyAfterApplyCannotReplaceNewRowsOrAttention() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        app.simulateScopeHold(); try await wait { app.simulatedHeldReplies == 1 }
        app.simulateScopeApply(false); try await settled(app)
        #expect(app.items.count == 2 && app.unseenCount == 0)
        app.simulateScopeInject(); try await settled(app)
        #expect(app.items.count == 3 && app.unseenCount == 1)
        app.simulateScopeDeliver(); try await wait { app.discardedScopeReplies == 1 }
        #expect(app.items.count == 3 && app.unseenCount == 1 && app.activeClip?.origin == .repository)
    }
    @Test func corruptSelectedNeverBroadensAndPartialRecoveryIsSilentThenNewOnce() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        app.simulateScopeReload(corrupt: true); try await settled(app)
        #expect(app.items.isEmpty && app.dataState != .empty && app.activeMonitoringScope == nil)
        #expect(app.scopeQuality != nil && app.scopeSummary.contains("configuration error"))
        app.simulateScopeRepair(); try await settled(app)
        app.simulateScopePartial(true); try await settled(app)
        app.simulateScopeInject(); try await settled(app)
        #expect(app.dataState == .partial && app.items.count == 2 && app.unseenCount == 0)
        app.simulateScopePartial(false); try await settled(app)
        #expect(app.dataState == .ready && app.unseenCount == 0 && app.activeClip == nil)
        app.simulateScopeInject(); try await settled(app)
        #expect(app.items.count == 3 && app.unseenCount == 1)
        app.refresh(); try await settled(app)
        #expect(app.items.count == 3 && app.unseenCount == 1)
    }
    @Test func scopeApplyPreservesPublicIncidentStateUnseenBurstAndAttention() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        app.simulateScopeInject(); try await settled(app)
        app.injectServiceIncident(.major)
        let incidents = app.serviceIncidents, state = app.serviceState, lastSuccess = app.serviceLastSuccess
        let unseen = app.unseenIncidents, burst = app.markerBurst, clip = app.activeClip
        #expect(!unseen.isEmpty)
        #expect(burst != nil)
        #expect(clip?.origin == .serviceIncident)
        app.simulateScopeApply(false); try await settled(app)
        #expect(app.serviceIncidents == incidents && app.serviceState == state && app.serviceLastSuccess == lastSuccess)
        #expect(app.unseenIncidents == unseen)
        #expect(app.markerBurst == burst)
        #expect(app.activeClip == clip)
        #expect(app.unseenCount == 0)
        #expect(!app.scopeSummary.contains("demo-a") && !app.scopeSummary.contains("demo-b"))
    }
    @Test func sourceSwitchInvalidatesRepliesAndValidationWithoutTouchingRealAccountScope() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        let generation = app.monitoringScopeGeneration, identity = try #require(app.monitoringScopeIdentity)
        app.simulateScopeHold(); try await wait { app.simulatedHeldReplies == 1 }
        app.settings.dataSource = .fixtures
        #expect(app.monitoringScopeIdentity == .demo)
        #expect(!app.applyRepositoryScope(.everything, identity: identity, generation: generation))
        app.simulateScopeDeliver(); try await wait { app.discardedScopeReplies == 1 }
        #expect(app.monitoringScopeIdentity == .demo && app.scopeSummary.hasPrefix("Demo scope"))
        #expect(!app.repositoryFetchInFlight)
        app.settings.dataSource = .githubCLI; try await settled(app)
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA)
    }
}
