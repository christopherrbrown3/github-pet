import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

/// #9 through the real AppModel path with the offline simulated scope (no gh, no network).
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct AuthoredPullRequestAppTests {
    private func simulated(features: FeatureSet = .current) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["app", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        return AppModel(options: options, runtime: AppModel.Runtime(
            now: { Date(timeIntervalSince1970: 1_763_208_000) }, systemReducedMotion: { false },
            schedulesTimers: false, scopeSimulationHoldLimit: nil, features: features))
    }
    /// Waits on explicit model state, not elapsed time: the poll task is done, every simulated
    /// request has been received, and the first load has landed. A stalled CI run (#127) only makes
    /// this wait longer, up to a bound, instead of letting the assertions read a half-applied poll.
    private func settled(_ model: AppModel, timeout: Duration = .seconds(60)) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            await model.repositoryPollSettled()
            if !model.repositoryFetchInFlight && model.simulatedScopeQuiescent && model.dataState != .loading { return }
            try #require(ContinuousClock.now < deadline, "timed out waiting for the simulated poll to settle")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func authoredRows(_ app: AppModel) -> [InboxItem] { app.items.filter { $0.kind == .authoredPullRequest } }

    @Test func needsActionRowsAlertOnceAndWaitingStaysInformational() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        let reviewRows = app.items.count
        #expect(app.authoredWaitingNote == nil)

        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        #expect(app.dataState == .ready, "a PR GitHub is still checking (UNKNOWN) never makes the inbox Partial")
        #expect(authoredRows(app).map(\.attention) == ["Changes requested"])
        #expect(app.items.count == reviewRows + 1 && app.badge == "\(reviewRows + 1)", "waiting PRs are not counted")
        #expect(app.unseenCount == 1, "a genuinely new attention state announces once")
        #expect(app.authoredWaitingCount == 3)
        #expect(app.authoredWaitingNote == "3 of your pull requests are waiting on others or being checked by GitHub")
        let firstID = try #require(authoredRows(app).first?.id)
        app.markAllSeen()

        app.simulateScopeAuthored(.churn); try await settled(app)
        #expect(authoredRows(app).map(\.id) == [firstID] && app.unseenCount == 0, "comment churn is not a new event")

        app.simulateScopeAuthored(.reviewUnavailable); try await settled(app)
        #expect(app.dataState == .ready && authoredRows(app).map(\.attention) == ["Changes requested"])
        #expect(authoredRows(app).map(\.id) == [firstID] && app.unseenCount == 0)
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        #expect(authoredRows(app).map(\.id) == [firstID] && app.unseenCount == 0)

        app.simulateScopeAuthored(.checksFailing); try await settled(app)
        #expect(authoredRows(app).map(\.attention) == ["Changes requested, Checks failing"])
        #expect(authoredRows(app).first?.id == firstID && app.unseenCount == 1, "same row; the gained reason announces")
        app.refresh(); try await settled(app)
        #expect(app.unseenCount == 1, "unchanged poll: no replay")
        app.markAllSeen()
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        #expect(authoredRows(app).map(\.attention) == ["Changes requested"] && app.unseenCount == 0,
                "losing a reason (checks fixed) never announces")

        app.markAllSeen()
        app.simulateAssignmentMode(.direct); try await settled(app)
        #expect(authoredRows(app).map(\.id) == [firstID] && app.unseenCount == 0)
        app.simulateScopeAuthored(.newRound); try await settled(app)
        #expect(authoredRows(app).map(\.id) == [firstID] && app.unseenCount == 1, "a later changes-requested round announces once (#60)")
        app.refresh(); try await settled(app)
        #expect(app.unseenCount == 1)

        app.simulateScopeAuthored(.off); try await settled(app)
        #expect(authoredRows(app).isEmpty && app.authoredWaitingCount == 0 && app.authoredWaitingNote == nil)
    }

    /// #148: the waiting PRs are listed under Waiting on others through the real live path (simulated
    /// scope): never Needs you rows, the badge or announcements; the group's count is its rows;
    /// Dismiss hides one like any other row, and Restore brings it back quietly.
    @Test func waitingPRsAreListedNeverCountedAndDismissLikeOtherRows() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        #expect(app.waitingItems.isEmpty)
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        let badge = app.badge, unseen = app.unseenCount, rows = app.items
        #expect(app.waitingItems.map(\.title).sorted() == ["Simulated authored approved", "Simulated authored checking",
                                                           "Simulated authored draft"])
        #expect(Set(app.waitingItems.map(\.attention)) == ["Checks running", "Draft", "Review pending"],
                "approved with checks running still waits (#153)")
        #expect(app.waitingItems.compactMap(\.detail) == ["Review pending, checks running, checking for conflicts"])
        #expect(app.waitingItems.allSatisfy { $0.isDemo && $0.kind == .authoredPullRequest })
        #expect(Set(app.items.map(\.id)).isDisjoint(with: app.waitingItems.map(\.id)), "never both Needs you and waiting")
        let group = app.waitingGroup
        #expect(group.isShown && group.count == "3" && group.count == "\(group.items.count)")
        #expect(InboxOverview(dataState: app.dataState, items: app.items, authoredWaiting: app.authoredWaitingCount,
                              deploymentsWaiting: app.deploymentsWaitingCount, deploymentsComplete: app.actionsQuality == nil,
                              serviceState: app.serviceState, incidents: app.serviceIncidents).waiting.value == group.count,
                "the tile's count equals the listed rows")

        let draft = try #require(app.waitingItems.first { $0.attention == "Draft" })
        #expect(app.canDismissInboxItem(draft))
        let context = try #require(app.inboxDismissalContext)
        app.dismissInboxItem(draft.id, in: context)
        #expect(!app.waitingItems.contains { $0.id == draft.id } && app.waitingGroup.count == "2")
        #expect(app.dismissedInboxRows.contains { $0.item?.id == draft.id })
        #expect(app.items == rows && app.badge == badge && app.unseenCount == unseen && !app.allCurrentInboxItemsDismissed)
        app.refresh(); try await settled(app)
        #expect(!app.waitingItems.contains { $0.id == draft.id }, "a dismissal survives the next poll")
        let row = try #require(app.dismissedInboxRows.first { $0.item?.id == draft.id })
        app.restoreInboxItem(row.id, in: context)
        #expect(app.waitingItems.contains { $0.id == draft.id } && app.unseenCount == unseen, "restored quietly")
    }

    /// QA W8b (#148): a failed live poll keeps the last known waiting rows from the session, shown
    /// as last known with an unknown count; the next good poll makes them current again.
    @Test func aFailedLivePollKeepsLastKnownWaitingRows() async throws {
        final class Failing: @unchecked Sendable { var on = false }
        let failing = Failing()
        var options = LaunchOptions.parse(arguments: ["app", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        let app = AppModel(options: options, runtime: AppModel.Runtime(
            now: { Date(timeIntervalSince1970: 1_763_208_000) }, systemReducedMotion: { false }, schedulesTimers: false,
            // A zero-time budget: the simulated live client returns a real .deadline failure.
            repositoryBudget: { CommandBudget(timeout: failing.on ? 0 : 20) }, scopeSimulationHoldLimit: nil))
        defer { app.cleanupScopeSimulation() }
        try await settled(app)
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        let known = app.waitingItems
        #expect(known.count == 3 && app.waitingGroup.count == "3")

        failing.on = true
        app.refresh()
        await app.repositoryPollSettled()
        if case .error = app.dataState {} else { Issue.record("the live poll failed: \(app.dataState)") }
        #expect(app.waitingItems == known, "last known rows are kept, not emptied")
        let group = app.waitingGroup
        #expect(group.isShown && group.lastKnown && group.count == "?" && group.note == "Unknown until the next successful update.")

        failing.on = false
        app.refresh(); try await settled(app)
        #expect(app.dataState == .ready && app.waitingItems == known && app.waitingGroup.count == "3" && !app.waitingGroup.lastKnown)
    }

    /// #148 (PM): a dismissal made in the quiet Waiting on others group applies only while the PR
    /// waits. Once it needs you it shows in Needs you, badges and announces as usual; a dismissal
    /// made on the Needs you row still hides it exactly as before.
    @Test func waitingDismissalNeverHidesThePROnceItNeedsYou() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        app.markAllSeen()
        let badge = try #require(app.badge.flatMap(Int.init))
        let draft = try #require(app.waitingItems.first { $0.attention == "Draft" })
        let context = try #require(app.inboxDismissalContext)
        app.dismissInboxItem(draft.id, in: context)
        #expect(!app.waitingItems.contains { $0.id == draft.id } && app.badge == "\(badge)")

        app.simulateScopeAuthored(.draftReady); try await settled(app)
        let ready = try #require(authoredRows(app).first { $0.title == draft.title }, "the PR that needs you is shown")
        #expect(ready.attention == "Merge conflict, Checks failing")
        #expect(app.badge == "\(badge + 1)" && app.isUnseen(ready), "it badges and announces")
        #expect(!app.waitingItems.contains { $0.title == draft.title })

        // A dismissal on the Needs you row behaves as before: hidden, and not back in the quiet group.
        app.markAllSeen()
        app.dismissInboxItem(ready.id, in: context)
        #expect(!app.items.contains { $0.id == ready.id } && app.badge == "\(badge)")
        #expect(!app.waitingItems.contains { $0.title == draft.title })
        app.refresh(); try await settled(app)
        #expect(!app.items.contains { $0.id == ready.id } && app.badge == "\(badge)" && app.unseenCount == 0)

        // Back to waiting: the earlier waiting dismissal still applies there.
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        #expect(!app.waitingItems.contains { $0.id == draft.id })
    }

    /// #153: an approved PR waits while its checks run; once ready to merge it needs you: a Needs
    /// you row saying so, counted in the badge, announced once. A dismissal made while it waited
    /// never hides it once ready; back to waiting, that dismissal applies again.
    @Test func waitingApprovedPRDismissedThenReadyShowsBadgesAndAlertsOnce() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        app.markAllSeen()
        let badge = try #require(app.badge.flatMap(Int.init))
        let approved = try #require(app.waitingItems.first { $0.title == "Simulated authored approved" })
        #expect(approved.attention == "Checks running" && !app.items.contains { $0.title == approved.title })
        let context = try #require(app.inboxDismissalContext)
        app.dismissInboxItem(approved.id, in: context)
        #expect(!app.waitingItems.contains { $0.id == approved.id } && app.badge == "\(badge)" && app.unseenCount == 0)

        app.simulateScopeAuthored(.approvedReady); try await settled(app)
        let ready = try #require(authoredRows(app).first { $0.title == approved.title }, "shown in Needs you")
        #expect(ready.attention == "Approved, ready to merge" && ready.kind.severity == .actionable)
        #expect(InboxGroup(kind: ready.kind) == .yourPullRequests)
        #expect(app.badge == "\(badge + 1)" && app.unseenCount == 1 && app.isUnseen(ready), "it badges and announces once")
        #expect(!app.waitingItems.contains { $0.title == approved.title } && app.authoredWaitingCount == 2)
        app.refresh(); try await settled(app)
        #expect(app.unseenCount == 1 && app.badge == "\(badge + 1)", "unchanged poll: no replay")
        app.markAllSeen()
        app.refresh(); try await settled(app)
        #expect(app.unseenCount == 0 && authoredRows(app).contains { $0.id == ready.id })

        // Checks running again: back to waiting, where the earlier waiting dismissal still hides it.
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        #expect(!authoredRows(app).contains { $0.title == approved.title } && app.badge == "\(badge)")
        #expect(!app.waitingItems.contains { $0.id == approved.id })
        app.simulateScopeAuthored(.approvedReady); try await settled(app)
        #expect(authoredRows(app).contains { $0.id == ready.id } && app.unseenCount == 0, "the same ready commit never re-announces")
    }

    /// Flag-on path (#94 keeps privacy mode in the code base).
    @Test func privacyModeHidesAuthoredTitlesAndRepositories() async throws {
        let app = simulated(features: .allOn); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        #expect(app.settings.privacyMode, "privacy mode is on by default")
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        let row = try #require(authoredRows(app).first)
        let surfaces = app.summaryLines + app.hoverLines(compact: false) + app.hoverLines(compact: true)
            + [PrivacyText.title(row, privacy: app.inboxPrivacy), PrivacyText.subtitle(row, privacy: app.inboxPrivacy),
               app.statusAccessibilityLabel, app.authoredWaitingNote ?? ""]
        for text in surfaces {
            #expect(!text.contains("Simulated authored") && !text.contains("demo-a/pet"), "\(text)")
        }
        #expect(PrivacyText.subtitle(row, privacy: app.inboxPrivacy).contains("Changes requested"))
        app.settings.privacyMode = false
        #expect(PrivacyText.title(row, privacy: app.inboxPrivacy) == "Simulated authored needs")
    }

    @Test func accountSwitchClearsTheWaitingCount() async throws {
        let app = simulated(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        app.simulateScopeAuthored(.changesRequested); try await settled(app)
        #expect(app.authoredWaitingCount == 3)
        app.simulateScopeAccount(true); try await settled(app)
        // Account B's selected scope (demo-b/pet repository) also has authored fixtures: its own,
        // freshly baselined, never A's.
        #expect(app.monitoringScopeIdentity == .github(ScopeSimulation.accountB))
        #expect(app.unseenCount == 0, "account switch re-baselines silently")
        #expect(authoredRows(app).allSatisfy { $0.id.contains(ScopeSimulation.accountB.viewerID) })
    }
}
