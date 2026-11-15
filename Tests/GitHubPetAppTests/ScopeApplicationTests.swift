import Foundation
import Testing
import GitHubPetCore
@testable import GitHubPet

@Suite(.serialized) @MainActor struct ScopeApplicationTests {
    private func model() -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        return AppModel(options: options)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() && ContinuousClock.now < end { await Task.yield() }
        try #require(predicate(), "bounded simulated completion")
    }
    private func settled(_ model: AppModel) async throws { try await wait { !model.repositoryFetchInFlight } }

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
        #expect(!unseen.isEmpty && burst != nil && clip?.origin == .serviceIncident)
        app.simulateScopeApply(false); try await settled(app)
        #expect(app.serviceIncidents == incidents && app.serviceState == state && app.serviceLastSuccess == lastSuccess)
        #expect(app.unseenIncidents == unseen && app.markerBurst == burst && app.activeClip == clip)
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
