import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

@Suite(.timeLimit(.minutes(2))) @MainActor struct AssignmentModeTests {
    private let date = Date(timeIntervalSince1970: 1_763_208_000)

    private func demo(_ defaults: EphemeralDefaults) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["app", "--fixtures", "--placeholder"], environment: [:])
        options.userDefaultsOverride = defaults
        return AppModel(options: options, runtime: AppModel.Runtime(now: { date }, systemReducedMotion: { false },
                                                                     schedulesTimers: false))
    }

    private func scoped() -> AppModel {
        let options = LaunchOptions.parse(arguments: ["app", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        let now = ContinuousClock.now
        return AppModel(options: options, runtime: AppModel.Runtime(now: { date }, systemReducedMotion: { false },
            schedulesTimers: false, repositoryBudget: { CommandBudget(timeout: 20, now: { now }) }, scopeSimulationHoldLimit: nil))
    }

    @Test func demoKeepsPersonalIssuesAndPersistsTheChoiceAcrossRelaunch() throws {
        let defaults = EphemeralDefaults(name: "assignment-mode.tests.\(UUID().uuidString)")
        let app = demo(defaults)
        #expect(app.settings.assignmentMode == .all && app.items.count == 3)
        #expect(app.addEntitlementRepository("example/pet-tools") == nil)
        #expect(app.items.contains { $0.kind == .entitlement })

        app.settings.assignmentMode = .direct
        #expect(app.items.map(\.kind) == [.reviewRequest, .assignedIssue])
        #expect(app.unseenCount == 0 && app.activeClip == nil)
        let relaunched = demo(defaults)
        #expect(relaunched.settings.assignmentMode == .direct && relaunched.items == app.items)
        #expect(relaunched.unseenCount == 0 && relaunched.activeClip == nil)

        relaunched.settings.assignmentMode = .all
        #expect(relaunched.items.contains { $0.kind == .entitlement })
        #expect(relaunched.unseenCount == 0 && relaunched.activeClip == nil)
        relaunched.injectEntitlementEvent()
        #expect(relaunched.unseenCount == 1)
        relaunched.markAllSeen()
        relaunched.replaySnapshot()
        #expect(relaunched.unseenCount == 0)
    }

    @Test func relaunchWithAPendingReviewReseedUsesOnlyFreshCompleteNonReviewEvidence() throws {
        let direct = BaselineKey(source: .fixtures, identity: .demo, scope: .everything, assignmentMode: .direct)
        for quality in [SourceQuality.ready, .partial, .stale, .error] {
            let defaults = EphemeralDefaults(name: "assignment-relaunch.tests.\(UUID().uuidString)")
            let store = EventBaselineStore(defaults: defaults)
            var settings = PetSettings()
            settings.assignmentMode = .direct
            SettingsStore(defaults: defaults).save(settings)
            // The comparison predates the new direct review and personal issue, with one old team review.
            store.save(EventBaseline(key: direct.value, digests: [EventBaseline.digest("reviewRequest:team")],
                                     baselineEstablished: true, quality: quality, lastSuccess: date - 60,
                                     reviewReachPending: true))

            let app = demo(defaults)
            #expect(app.settings.assignmentMode == .direct && app.dataState == .ready)
            let unseen = app.items.filter(app.isUnseen).map(\.kind)
            #expect(unseen == (quality == .ready ? [.assignedIssue] : []))
            #expect(store.load(for: direct)?.reviewReachPending == nil)
            app.markAllSeen()
            app.replaySnapshot()
            #expect(app.unseenCount == 0)
        }
    }

    @Test func scopedModeKeepsDualAndPersonalReviewsAuthoredAttentionAndIncidents() async throws {
        let app = scoped(); defer { app.cleanupScopeSimulation() }
        await app.repositoryPollSettled()
        app.simulateScopeApply(false)
        await app.repositoryPollSettled()
        #expect(app.addEntitlementRepository("demo-outside/pet") == nil)
        #expect(app.addEntitlementRepository("demo-a/pet") == nil)
        app.simulateScopeAuthored(.changesRequested)
        await app.repositoryPollSettled()
        app.simulateScopeInject()
        await app.repositoryPollSettled()
        // #138: an incident plays a clip only when the marker appears from none, so clear the fixture's first.
        app.resolveServiceIncidents()
        app.injectServiceIncident(.major)
        await app.repositoryPollSettled()
        let incidents = app.serviceIncidents
        let incidentAttention = app.activeClip
        #expect(!incidents.isEmpty)
        #expect(incidentAttention?.origin == .serviceIncident)
        let all = app.items
        #expect(Set(all.filter { $0.kind == .entitlement }.map(\.repository)) == ["demo-a/pet", "demo-outside/pet"])

        app.settings.assignmentMode = .direct
        await app.repositoryPollSettled()
        #expect(app.simulatedRequests.last?.assignmentMode == .direct)
        #expect(app.simulatedRequests.last?.scope == .everything)
        #expect(app.items == all.filter { $0.repository != "demo-outside/pet" })
        #expect(app.items.contains { $0.kind == .authoredPullRequest })
        #expect(app.items.contains { $0.kind == .reviewRequest && $0.repository == "demo-a/new-pet" })
        #expect(app.serviceIncidents == incidents && app.activeClip == incidentAttention)
        #expect(app.items.filter(app.isUnseen).map(\.kind) == [.authoredPullRequest])

        app.simulateScopeApply(true)
        await app.repositoryPollSettled()
        #expect(app.simulatedRequests.last?.assignmentMode == .direct)
        #expect(app.simulatedRequests.last?.scope == ScopeSimulation.selectedA)
        app.simulateScopeAccount(true)
        await app.repositoryPollSettled()
        #expect(app.simulatedRequests.last?.assignmentMode == .direct)
        #expect(app.simulatedRequests.last?.expected == ScopeSimulation.accountB)
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedB)
        #expect(app.items.allSatisfy { $0.repository == "demo-b/pet" } && app.unseenCount == 0)
        app.settings.dataSource = .fixtures
        #expect(app.settings.assignmentMode == .direct && app.monitoringScopeIdentity == .demo && app.unseenCount == 0)
        app.settings.dataSource = .githubCLI
        await app.repositoryPollSettled()
        #expect(app.simulatedRequests.last?.assignmentMode == .direct && app.unseenCount == 0)

        app.simulateScopeReload(forgetViewer: true, account: ScopeSimulation.accountB)
        await app.repositoryPollSettled()
        let bootstrap = app.simulatedRequests.suffix(2)
        #expect(bootstrap.first?.identityOnly == true && bootstrap.first?.searchAliases.isEmpty == true)
        #expect(bootstrap.last?.assignmentMode == .direct && bootstrap.last?.expected == ScopeSimulation.accountB)
        #expect(app.unseenCount == 0)
    }

    @Test func heldModeChangeKeepsNonReviewAttentionAndFirstReplyCanAnnounceANewAssignment() async throws {
        let app = scoped(); defer { app.cleanupScopeSimulation() }
        await app.repositoryPollSettled()
        app.simulateScopeApply(false)
        await app.repositoryPollSettled()
        app.simulateAssignedIssue()
        await app.repositoryPollSettled()
        app.simulateScopeAuthored(.changesRequested)
        await app.repositoryPollSettled()
        app.simulateScopeInject()
        await app.repositoryPollSettled()
        let originalClip = try #require(app.activeClip)
        #expect(originalClip.event.item.kind == .assignedIssue && app.unseenCount == 3)
        let kept = app.items.filter { $0.kind != .reviewRequest }
        let identity = try #require(app.monitoringScopeIdentity)
        let defaults = EphemeralDefaults.named(try #require(app.simulationDomain))
        let store = EventBaselineStore(defaults: defaults)
        let all = BaselineKey(source: .githubCLI, identity: identity, scope: .everything)
        let oldBaseline = try #require(store.load(for: all))

        app.simulateScopeHold()
        await app.scopeRepliesHeld(1)
        app.simulateAssignedIssue()
        app.simulateScopeInject()
        app.simulateScopeHold(refresh: false)
        app.simulateAssignmentMode(.direct)
        await app.scopeRepliesHeld(2)
        #expect(app.dataState == .loading && app.items == kept && app.hiddenResultCount == 0)
        #expect(app.unseenCount == 2 && app.activeClip == originalClip)
        let direct = BaselineKey(source: .githubCLI, identity: identity, scope: .everything, assignmentMode: .direct)
        let pending = try #require(store.load(for: direct))
        #expect(pending.reviewReachPending == true && pending.digests == oldBaseline.digests)
        #expect(pending.quality == oldBaseline.quality && pending.lastSuccess == oldBaseline.lastSuccess)
        #expect(SettingsStore(defaults: defaults).load().assignmentMode == .direct)

        app.simulateScopeDeliverOne(newest: true)
        await app.repositoryPollSettled()
        #expect(app.dataState == .ready && app.items.count == 6 && app.unseenCount == 3)
        #expect(app.items.filter(app.isUnseen).filter { $0.kind == .assignedIssue }.count == 2)
        #expect(!app.items.contains { $0.repository == "demo-outside/pet" || ($0.kind == .reviewRequest && app.isUnseen($0)) })
        #expect(store.load(for: direct)?.reviewReachPending == nil)
        let firstDirect = app.items
        let received = app.receivedScopeReplies
        app.simulateScopeDeliverOne(newest: false)
        await app.scopeRepliesReceived(received + 1)
        #expect(app.items == firstDirect && app.unseenCount == 3 && app.discardedScopeReplies == 1)

        app.markAllSeen()
        app.refresh()
        await app.repositoryPollSettled()
        #expect(app.unseenCount == 0)
        app.simulateScopeInject()
        await app.repositoryPollSettled()
        #expect(app.items.filter(app.isUnseen).map(\.kind) == [.reviewRequest])
        app.simulateAssignmentMode(.all)
        await app.repositoryPollSettled()
        #expect(app.items.contains { $0.repository == "demo-outside/pet" })
        #expect(app.unseenCount == 0 && app.activeClip == originalClip)
    }

    @Test func switchingBackBeforeAHeldReplySettlesSeedsSilentlyAndRejectsTheOldReply() async throws {
        let app = scoped(); defer { app.cleanupScopeSimulation() }
        await app.repositoryPollSettled()
        app.simulateScopeApply(false)
        await app.repositoryPollSettled()
        let generation = app.monitoringScopeGeneration
        app.simulateScopeHold()
        await app.scopeRepliesHeld(1)
        app.requestRefresh()
        app.simulateScopeHold(refresh: false)
        app.settings.assignmentMode = .direct
        await app.scopeRepliesHeld(2)
        #expect(app.dataState == .loading && app.items.isEmpty)
        app.simulateScopeInject()

        app.settings.assignmentMode = .all
        await app.repositoryPollSettled()
        #expect(app.monitoringScopeGeneration == generation)
        #expect(app.simulatedRequests.suffix(3).map(\.assignmentMode) == [.all, .direct, .all])
        #expect(app.items.count == 3 && app.unseenCount == 0 && app.activeClip == nil)
        let received = app.receivedScopeReplies
        app.simulateScopeDeliver()
        await app.scopeRepliesReceived(received + 2)
        #expect(app.discardedScopeReplies == 2 && app.items.count == 3 && app.unseenCount == 0)
        #expect(app.simulatedRequests.suffix(3).map(\.assignmentMode) == [.all, .direct, .all])
    }

    @Test func directModeRetainsQualityAndAnnouncesOnlyAfterComparableRecovery() async {
        let app = scoped(); defer { app.cleanupScopeSimulation() }
        await app.repositoryPollSettled()
        app.simulateScopePartial(true)
        await app.repositoryPollSettled()
        app.settings.assignmentMode = .direct
        await app.repositoryPollSettled()
        #expect(app.dataState == .partial && app.scopeQuality != nil && app.unseenCount == 0)

        app.simulateScopeVisibility(.hiddenOnly)
        await app.repositoryPollSettled()
        #expect(app.dataState == .partial && app.items.isEmpty)
        app.simulateScopePartial(false)
        await app.repositoryPollSettled()
        #expect(app.dataState == .hiddenOnly(3) && app.unseenCount == 0)

        app.markStale()
        #expect(app.dataState == .stale)
        app.simulateScopeVisibility(.complete)
        await app.repositoryPollSettled()
        #expect(app.dataState == .ready && app.unseenCount == 0)
        app.simulateScopeInject()
        await app.repositoryPollSettled()
        #expect(app.unseenCount == 1)
        #expect(app.activeClip?.event.item.kind == .reviewRequest)
        app.markAllSeen()
        app.replaySnapshot()
        await app.repositoryPollSettled()
        #expect(app.unseenCount == 0)
        app.simulateAssignmentMode(.all)
        await app.repositoryPollSettled()
        #expect(app.unseenCount == 0 && app.activeClip == nil)
    }
}
