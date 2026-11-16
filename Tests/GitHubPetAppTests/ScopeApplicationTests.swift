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

// Hang guard only: every wait below is an explicit handshake, so passing never depends on
// runner speed; the limit just turns a lost handshake into a diagnosable failure.
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct ScopeApplicationTests {
    private final class Inputs {
        var date = Date(timeIntervalSince1970: 1_763_208_000)
        var reducedMotion = false
        let budgetClock = FixtureBudgetClock()
        var expireNextBudget = false
        var defaultsSuite: String?
    }
    private func model(inputs: Inputs = Inputs()) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        inputs.defaultsSuite = options.defaultsSuite
        return AppModel(options: options, runtime: AppModel.Runtime(now: { inputs.date },
            systemReducedMotion: { inputs.reducedMotion }, schedulesTimers: false,
            repositoryBudget: {
                let timeout: TimeInterval = inputs.expireNextBudget ? 0 : 20
                inputs.expireNextBudget = false
                return CommandBudget(timeout: timeout, now: { inputs.budgetClock.now() })
            }, scopeSimulationHoldLimit: nil))
    }
    private func settled(_ model: AppModel) async throws {
        await model.repositoryPollSettled()
        try #require(!model.repositoryFetchInFlight, "current repository poll settled")
    }
    private func held(_ model: AppModel) async throws {
        await model.scopeRepliesHeld(1)
        try #require(model.simulatedHeldReplies == 1, "one simulated reply held")
    }
    /// Delivers held replies and awaits their arrival at the model (current or discarded).
    private func deliver(_ model: AppModel) async {
        let received = model.receivedScopeReplies
        model.simulateScopeDeliver()
        await model.scopeRepliesReceived(received + 1)
    }

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
        app.simulateScopeHold(); try await held(app)
        app.simulateScopeApply(false); try await settled(app)
        app.simulateScopeInject(); try await settled(app)
        #expect(app.items.count == 3 && app.unseenCount == 1 && app.activeClip?.origin == .repository)
        inputs.date.addTimeInterval(8) // deterministic analogue of a stalled cooperative executor
        app.tick()
        #expect(app.activeClip == nil && app.unseenCount == 1 && app.items.count == 3)
        await deliver(app); #expect(app.discardedScopeReplies == 1)
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
        var options = LaunchOptions.parse(arguments: ["app", "--fixtures", "--placeholder"], environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "scope.host-motion.tests.\(UUID().uuidString)")
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
    @Test func simulatedLiveControlsCannotChangeFixtureIdentityOrScope() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        app.settings.dataSource = .fixtures
        let generation = app.monitoringScopeGeneration, scope = app.activeMonitoringScope, rows = app.items
        app.simulateScopeReload(corrupt: true, forgetViewer: true)
        app.simulateScopeAccount(true)
        app.simulateScopeApply(true)
        app.simulateScopeHold()
        app.simulateScopeInject()
        app.simulateScopePartial(true)
        app.simulateScopeRepair()
        #expect(app.monitoringScopeIdentity == .demo)
        #expect(app.monitoringScopeGeneration == generation && app.activeMonitoringScope == scope)
        #expect(app.items == rows && !app.repositoryFetchInFlight)
        app.settings.dataSource = .githubCLI; try await settled(app)
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA && app.items.count == 1)
    }
    @Test func teardownRejectsHeldReplyBeforeDeletingIsolatedDefaults() async throws {
        let inputs = Inputs(), app = model(inputs: inputs)
        try await settled(app)
        app.simulateScopeHold(); try await held(app)
        let calls = app.simulatedRequests.count, received = app.receivedScopeReplies
        let suite = try #require(inputs.defaultsSuite)
        app.cleanupScopeSimulation()
        await app.scopeRepliesReceived(received + 1)
        #expect(app.receivedScopeReplies == received + 1)
        #expect(app.discardedScopeReplies == 1)
        #expect(!app.repositoryFetchInFlight && app.simulatedRequests.count == calls)
        #expect(UserDefaults(suiteName: suite)?.persistentDomain(forName: suite)?.isEmpty != false,
                "late replies cannot resurrect a deleted simulation domain")
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist")
        #expect(!FileManager.default.fileExists(atPath: plist.path), "normal quit leaves no simulation plist behind")
    }
    @Test func launchFlagIsExplicitAndIsolatedAndKnownSelectedIsFirstRequest() async throws {
        #expect(!LaunchOptions.parse(arguments: ["app"], environment: [:]).simulatesMonitoringScope)
        let options = LaunchOptions.parse(arguments: ["app", "--simulate-monitoring-scope", "--defaults-suite", "real-domain"], environment: [:])
        #expect(options.defaultsSuite?.hasPrefix("dev.github-pet.scope-simulation.") == true)
        #expect(options.userDefaults is EphemeralDefaults, "the simulated domain never reaches cfprefsd or disk")
        var overridden = options
        overridden.userDefaultsOverride = .standard
        let isolated = AppModel(options: overridden, runtime: AppModel.Runtime(schedulesTimers: false))
        defer { isolated.cleanupScopeSimulation() }
        #expect(isolated.simulationDomain?.hasPrefix("dev.github-pet.scope-simulation.") == true)
        #expect(UserDefaults.standard.object(forKey: "GitHubPet.monitoring-scope.v1.github.com.U_scope_demo_A") == nil,
                "a programmatic override cannot route simulation into the real domain")
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
        #expect(app.simulatedRequests.suffix(2).map(\.identityOnly) == [true, false], "unknown viewer bootstrap asks identity only")
        #expect(app.simulatedRequests.last?.scope == ScopeSimulation.selectedA)
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
        app.simulateScopeHold(); try await held(app)
        app.simulateScopeApply(false); try await settled(app)
        #expect(app.items.count == 2 && app.unseenCount == 0)
        app.simulateScopeInject(); try await settled(app)
        #expect(app.items.count == 3 && app.unseenCount == 1)
        await deliver(app); #expect(app.discardedScopeReplies == 1)
        #expect(app.items.count == 3 && app.unseenCount == 1 && app.activeClip?.origin == .repository)
    }
    @Test func corruptSelectedNeverBroadensAndPartialRecoveryIsSilentThenNewOnce() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        app.simulateScopeReload(corrupt: true); try await settled(app)
        #expect(app.items.isEmpty && app.dataState != .empty && app.activeMonitoringScope == nil)
        #expect(app.scopeQuality != nil && app.scopeSummary.contains("configuration error"))
        // Paused: reload and Refresh ask only who the viewer is (no search aliases, never Everything).
        let pausedFrom = app.simulatedRequests.count - 1
        app.refresh(); try await settled(app)
        app.refresh(); try await settled(app)
        let paused = app.simulatedRequests[pausedFrom...]
        #expect(paused.count == 3 && paused.allSatisfy { $0.identityOnly && $0.searchAliases.isEmpty && $0.expected == ScopeSimulation.accountA })
        #expect(app.items.isEmpty && app.scopeSummary.contains("configuration error"))
        // An account switch while paused is still detected and restores B's own selection.
        app.simulateScopeAccount(true); try await settled(app)
        #expect(app.simulatedRequests.suffix(2).map(\.identityOnly) == [true, false])
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedB && app.items.map(\.repository) == ["demo-b/pet"])
        #expect(app.unseenCount == 0)
        app.simulateScopeAccount(false); try await settled(app)
        #expect(app.items.isEmpty && app.scopeSummary.contains("configuration error"))
        app.simulateScopeRepair(); try await settled(app)
        #expect(app.simulatedRequests.last?.identityOnly == false && app.unseenCount == 0 && app.items.count == 1, "repair resumes silently")
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
    /// #35 through the real app path (simulated gh replies -> session -> engine -> model).
    @Test func hiddenMatchesAreInformationalAndNeverAllClearThroughTheApp() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        app.simulateScopeVisibility(.hidden); try await settled(app)
        #expect(app.dataState == .ready && app.items.count == 1 && app.hiddenResultCount == 3)
        #expect(app.hiddenResultsNote == "3 matching items aren't visible to your account")
        #expect(app.badge == "1" && app.scopeQuality == nil && app.mascotState == .idle, "no Partial badge, quality or mood change")
        app.simulateScopeVisibility(.hiddenOnly); try await settled(app)
        #expect(app.dataState == .hiddenOnly(3) && app.items.isEmpty && app.badge == "0")
        #expect(app.dataState.statusText == "No visible items · 3 matches hidden from your account" && app.hiddenResultsNote == nil)
        app.simulateScopeVisibility(.capped); try await settled(app)
        #expect(app.dataState == .partial && app.hiddenResultCount == 0 && app.badge == "1+")
        // Settle between the two changes: a refresh while a poll is pending launches nothing, and
        // that poll reads the simulation on its own thread, so under load it could miss partial.
        app.simulateScopeVisibility(.hidden); try await settled(app)
        app.simulateScopePartial(true); try await settled(app)
        #expect(app.dataState == .partial && app.hiddenResultCount == 0 && app.hiddenResultsNote == nil, "errors keep Partial")
        app.simulateScopePartial(false); try await settled(app)
        #expect(app.dataState == .ready && app.unseenCount == 0 && app.hiddenResultCount == 3, "recovery is silent")
        app.simulateScopeInject(); try await settled(app)
        #expect(app.unseenCount == 1, "a genuinely new visible row still alerts once")
        app.settings.privacyMode = false
        #expect(app.hiddenResultsNote?.contains("demo") == false, "counts only, never names")
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
        app.simulateScopeHold(); try await held(app)
        app.settings.dataSource = .fixtures
        #expect(app.monitoringScopeIdentity == .demo)
        #expect(!app.applyRepositoryScope(.everything, identity: identity, generation: generation))
        await deliver(app); #expect(app.discardedScopeReplies == 1)
        #expect(app.monitoringScopeIdentity == .demo && app.scopeSummary.hasPrefix("Demo scope"))
        #expect(!app.repositoryFetchInFlight)
        app.settings.dataSource = .githubCLI; try await settled(app)
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA)
    }
}
