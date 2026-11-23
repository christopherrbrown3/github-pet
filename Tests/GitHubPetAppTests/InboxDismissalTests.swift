import Foundation
import Testing
@testable import GitHubPet
@testable import GitHubPetCore

private struct DismissalActionsFixture: ActionsPolling {
    let hasFailure: Bool

    func fetch(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        let viewer = ScopeViewer(account: ScopeSimulation.accountA, login: "demo-a_sim")
        guard hasFailure else {
            return ScopedPollResult(viewer: viewer, items: [], issues: [.targetUnavailable(0)], successfulSources: 0)
        }
        let item = InboxItem(id: "actions:fixture", kind: .workflowFailure, repository: "demo-a/pet", title: "Fixture run",
                             url: URL(string: "https://github.com/demo-a/pet/actions/runs/1"), updatedAt: .distantPast, isDemo: true)
        return ScopedPollResult(viewer: viewer, items: [item], issues: [], successfulSources: 1)
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct InboxDismissalTests {
    private let date = Date(timeIntervalSince1970: 1_763_208_000)

    private func makeDemo(_ defaults: EphemeralDefaults) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["app", "--fixtures", "--placeholder"], environment: [:])
        options.defaultsSuite = defaults.name
        options.userDefaultsOverride = defaults
        return AppModel(options: options, runtime: .init(now: { date }, systemReducedMotion: { false },
                                                         schedulesTimers: false))
    }

    private func makeSimulated(actions: (any ActionsPolling)? = nil) -> AppModel {
        let options = LaunchOptions.parse(arguments: ["app", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        let instant = ContinuousClock.now
        return AppModel(options: options, runtime: .init(now: { date }, systemReducedMotion: { false },
                                                         schedulesTimers: false,
                                                         repositoryBudget: { CommandBudget(timeout: 20, now: { instant }) },
                                                         scopeSimulationHoldLimit: nil, actionsClient: actions))
    }

    private func dismiss(_ item: InboxItem, in app: AppModel) throws {
        let context = try #require(app.inboxDismissalContext)
        app.dismissInboxItem(item.id, in: context)
    }

    private func restore(_ row: DismissedInboxRow, in app: AppModel) throws {
        let context = try #require(app.inboxDismissalContext)
        app.restoreInboxItem(row.id, in: context)
    }

    private func settled(_ app: AppModel) async throws {
        await app.repositoryPollSettled()
        try #require(!app.repositoryFetchInFlight)
    }

    /// #148: Demo lists invented Waiting on others rows (two PRs and a deployment) apart from the
    /// inbox: never the badge or unseen, last known through a failure, and only PRs dismiss.
    @Test func demoWaitingRowsStayOutOfTheBadgeAndFollowTheSourceState() throws {
        let app = makeDemo(EphemeralDefaults(name: "dismissals.app.waiting"))
        #expect(app.waitingItems == FixtureSimulator.defaultWaitingItems())
        #expect(app.items.count == FixtureSimulator.defaultItems().count && app.badge == "\(app.items.count)")
        #expect(app.authoredWaitingCount == 2 && app.deploymentsWaitingCount == 1 && app.waitingGroup.count == "3")
        #expect(app.waitingItems.allSatisfy { !app.isUnseen($0) && $0.attention != nil })
        let deployment = try #require(app.waitingItems.first { $0.kind == .deploymentApproval })
        #expect(!app.canDismissInboxItem(deployment), "deployment rows are never dismissible, as in Needs you")
        app.setPartialPolls(true)
        #expect(app.waitingGroup.count == "3+" && app.waitingGroup.note != nil)
        app.setPartialPolls(false)
        app.simulateDisconnect()
        #expect(app.waitingItems.count == 3 && app.waitingGroup.count == "?" && app.waitingGroup.lastKnown)
        app.simulateReconnect()
        // Everything dismissed in Needs you still lists what is waiting on others.
        for item in app.items { try dismiss(item, in: app) }
        #expect(app.items.isEmpty && app.allCurrentInboxItemsDismissed && app.waitingItems.count == 3)
    }

    @Test func allDismissedPersistsAcrossRelaunchAndRestoresQuietly() throws {
        let defaults = EphemeralDefaults(name: "dismissals.app.relaunch")
        let key = BaselineKey(source: .fixtures, identity: .demo, scope: .everything)
        let app = makeDemo(defaults)
        let original = app.items
        let baseline = try #require(EventBaselineStore(defaults: defaults).load(for: key))
        for item in original { try dismiss(item, in: app) }
        #expect(app.items.isEmpty && app.showsCompleteDismissalState)
        #expect(EventBaselineStore(defaults: defaults).load(for: key) == baseline)

        let relaunched = makeDemo(defaults)
        #expect(relaunched.items.isEmpty && relaunched.showsCompleteDismissalState)
        #expect(relaunched.dismissedInboxRows.compactMap(\.item).count == original.count)
        for row in relaunched.dismissedInboxRows { try restore(row, in: relaunched) }
        #expect(relaunched.items == original && relaunched.dismissedInboxRows.isEmpty)
        #expect(relaunched.unseenCount == 0 && relaunched.activeClip == nil)
        #expect(EventBaselineStore(defaults: defaults).load(for: key) == baseline)
        #expect(try InboxDismissalStore(defaults: defaults).load(for: .demo).isEmpty)
    }

    @Test func absentDismissalsSurviveScopeAndRestoreWithoutFetchingOrReplaying() throws {
        let defaults = EphemeralDefaults(name: "dismissals.app.absence")
        let app = makeDemo(defaults)
        let target = try #require(app.items.first { $0.kind == .assignedIssue })
        try dismiss(target, in: app)
        let selected = try MonitoringScope(selected: [MonitoringTarget(repository: "example/pet-tools")])
        #expect(app.applyRepositoryScope(selected, identity: .demo, generation: app.monitoringScopeGeneration))
        let row = try #require(app.dismissedInboxRows.first)
        #expect(row.item == nil && row.record.number == 18)
        #expect(!app.allCurrentInboxItemsDismissed && app.badge == "1")
        let beforeRestore = app.lastSuccess
        try restore(row, in: app)
        #expect(app.dismissedInboxRows.isEmpty && !app.items.contains(target) && app.lastSuccess == beforeRestore)
        #expect(app.applyRepositoryScope(.everything, identity: .demo, generation: app.monitoringScopeGeneration))
        #expect(app.items.contains(target) && app.unseenCount == 0 && app.activeClip == nil)
    }

    @Test func degradedSourceQualityTakesPrecedenceOverAllDismissed() throws {
        let app = makeDemo(EphemeralDefaults(name: "dismissals.app.quality"))
        for item in app.items { try dismiss(item, in: app) }
        app.setPartialPolls(true)
        #expect(app.dataState == .partial && app.badge == "0+" && app.items.isEmpty)
        #expect(!app.allCurrentInboxItemsDismissed && app.dismissedInboxRows.count == 3)
        app.markStale()
        #expect(app.dataState == .stale && app.badge == "?" && !app.allCurrentInboxItemsDismissed)
        app.simulateDisconnect()
        guard case .error = app.dataState else { Issue.record("Expected a fetch error"); return }
        #expect(app.badge == "?" && !app.allCurrentInboxItemsDismissed && app.dismissedInboxRows.count == 3)
        app.setPartialPolls(false)
        app.simulateReconnect()
        #expect(app.showsCompleteDismissalState && app.unseenCount == 0 && app.activeClip == nil)
    }

    @Test func entitlementDismissalKeepsOtherAttentionAndIncidentClip() throws {
        let app = makeDemo(EphemeralDefaults(name: "dismissals.app.clips"))
        app.injectEntitlementEvent()
        let entitlement = try #require(app.items.first { $0.kind == .entitlement })
        #expect(app.activeClip?.event.item.id == entitlement.id && app.isUnseen(entitlement))
        try dismiss(entitlement, in: app)
        #expect(app.activeClip == nil && app.unseenCount == 0)
        app.replaySnapshot()
        try restore(try #require(app.dismissedInboxRows.first), in: app)
        #expect(app.items.contains(entitlement) && app.activeClip == nil && !app.isUnseen(entitlement))

        let originalIncidentCount = app.serviceIncidents.count
        app.injectServiceIncident(.major)
        let incidentClip = try #require(app.activeClip)
        #expect(incidentClip.origin == .serviceIncident)
        app.injectWorkflowFailure()
        let actionsFixture = try #require(app.items.first { $0.kind == .ciFailure })
        #expect(!app.canDismissInboxItem(actionsFixture))
        try dismiss(actionsFixture, in: app)
        try dismiss(entitlement, in: app)
        #expect(app.items.contains(actionsFixture) && app.isUnseen(actionsFixture))
        #expect(app.serviceIncidents.count == originalIncidentCount + 1 && app.incidentMarker != nil)
        #expect(app.activeClip == incidentClip)
    }

    @Test func verifiedAccountIsolationAndAuthoredRevisionsPreserveTheLedger() async throws {
        let app = makeSimulated()
        defer { app.cleanupScopeSimulation() }
        #expect(app.inboxDismissalContext == nil, "remembered account alone does not grant access")
        try await settled(app)
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        let authored = try #require(app.items.first { $0.kind == .authoredPullRequest })
        let contextA = try #require(app.inboxDismissalContext)
        try dismiss(authored, in: app)
        app.simulateScopeAuthored(.checksFailing); try await settled(app)
        #expect(app.unseenCount == 0 && app.activeClip == nil)
        let entry = try #require(app.dismissedInboxRows.first)
        #expect(entry.item?.attention == "Changes requested, Checks failing")

        app.simulateScopeAccount(true); try await settled(app)
        #expect(app.inboxDismissalContext?.identity == .github(ScopeSimulation.accountB))
        #expect(app.dismissedInboxRows.isEmpty && app.items.contains { $0.kind == .authoredPullRequest })
        app.restoreInboxItem(entry.id, in: contextA)
        app.simulateScopeAccount(false); try await settled(app)
        #expect(app.inboxDismissalContext?.identity == .github(ScopeSimulation.accountA))
        #expect(app.dismissedInboxRows.map(\.id) == [entry.id] && app.unseenCount == 0)
        app.restoreInboxItem(entry.id, in: contextA)
        #expect(app.dismissedInboxRows.map(\.id) == [entry.id], "a stale action from the same account is rejected")
        try restore(entry, in: app)
        app.requestRefresh(); try await settled(app)
        #expect(app.items.contains { $0.id == authored.id } && app.unseenCount == 0 && app.activeClip == nil)
        app.simulateScopeInject(); try await settled(app)
        #expect(app.unseenCount == 1, "a different genuinely new row can still announce")
    }

    @Test func hiddenMatchesAndIndependentActionsRemainVisibleOrUncertain() async throws {
        for hasFailure in [false, true] {
            let app = makeSimulated(actions: DismissalActionsFixture(hasFailure: hasFailure))
            defer { app.cleanupScopeSimulation() }
            try await settled(app)
            let identity = try #require(app.monitoringScopeIdentity)
            let scope = try MonitoringScope(selected: [MonitoringTarget(repository: "demo-a/pet")])
            #expect(app.applyRepositoryScope(scope, identity: identity, generation: app.monitoringScopeGeneration))
            try await settled(app)
            app.settings.watchWorkflowFailures = true
            try await settled(app)
            app.simulateScopeVisibility(.hidden); try await settled(app)
            let review = try #require(app.items.first { $0.kind == .reviewRequest })
            try dismiss(review, in: app)
            #expect(app.hiddenResultCount == 3 && app.hiddenResultsNote != nil)
            #expect(!app.allCurrentInboxItemsDismissed)
            if hasFailure {
                let failure = try #require(app.items.first)
                #expect(app.items.count == 1 && failure.kind == .workflowFailure && !app.canDismissInboxItem(failure))
                #expect(app.dataState == .ready && app.badge == "1")
            } else {
                #expect(app.items.isEmpty && app.dataState == .partial && app.badge == "0+")
                #expect(app.actionsQuality != nil)
            }
        }
    }
}

private extension AppModel {
    var showsCompleteDismissalState: Bool {
        guard let message = dismissedInboxMessage else { return false }
        return dataState == .ready && badge == "0" && mascotBadge == "0"
            && inboxCountDescription == message && statusAccessibilityLabel.contains(message)
            && summaryLines.contains(message) && hoverLines(compact: false).contains(message)
            && hoverLines(compact: true).contains { $0.contains("Current items dismissed") }
    }
}
