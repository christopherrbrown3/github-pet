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
