import Foundation
import Testing
@testable import GitHubPetCore

@Suite struct SettingsPresentationTests {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(hour: Int) -> Date { utc.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: hour))! }

    @Test func panesAreMascotAlertsGitHubInOrder() {
        #expect(SettingsPane.allCases.map(\.title) == ["Mascot", "Alerts", "GitHub"])
        #expect(Set(SettingsPane.allCases.map(\.symbol)).count == 3)
    }

    @Test func notSnoozedByDefaultAndStateIsExplicit() {
        let state = AlertSuppression(PetSettings(), at: date(hour: 12), calendar: utc)
        #expect(!state.isSnoozed)
        #expect(state.snoozeLine == "Not snoozed")
        #expect(state.quietHoursLine == "Quiet hours are off")
        #expect(!state.interruptionsSuppressed)
    }

    @Test func snoozeSuppressesUntilItExpires() {
        var settings = PetSettings()
        settings.snoozeUntil = date(hour: 14)
        let during = AlertSuppression(settings, at: date(hour: 12), calendar: utc)
        #expect(during.isSnoozed && during.interruptionsSuppressed)
        #expect(during.snoozeLine.hasPrefix("Snoozed until"))
        let after = AlertSuppression(settings, at: date(hour: 15), calendar: utc)
        #expect(!after.isSnoozed && after.snoozeLine == "Not snoozed")
    }

    @Test func quietHoursActiveOnlyInsideTheWindowAndOnlyWhenEnabled() {
        var settings = PetSettings()
        settings.quietHours = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(AlertSuppression(settings, at: date(hour: 23), calendar: utc).quietHoursActive)
        let outside = AlertSuppression(settings, at: date(hour: 12), calendar: utc)
        #expect(!outside.quietHoursActive && outside.quietHoursLine.contains("not active now"))
        settings.quietHours.enabled = false
        #expect(!AlertSuppression(settings, at: date(hour: 23), calendar: utc).quietHoursActive)
        // Equal start and end is no quiet time, even when enabled.
        settings.quietHours = QuietHours(enabled: true, startMinute: 60, endMinute: 60)
        #expect(AlertSuppression(settings, at: date(hour: 1), calendar: utc).quietHoursLine == "Quiet hours are off")
    }

    @Test func suppressionMatchesAlertsAllowedAndNeverMentionsMonitoringStopping() {
        var settings = PetSettings()
        settings.snoozeUntil = date(hour: 14)
        let now = date(hour: 12)
        #expect(AlertSuppression(settings, at: now, calendar: utc).interruptionsSuppressed == !settings.alertsAllowed(at: now, calendar: utc))
        #expect(AlertSuppression.explanation.contains("keeps fetching"))
        #expect(AlertSuppression.explanation.contains("inbox keeps updating"))
    }

    @Test func ghConnectionNamesEveryStateAndNeverCallsFailuresHealthy() {
        func summary(_ state: DataState) -> GhConnectionSummary { GhConnectionSummary(state: state, source: .githubCLI) }
        #expect(summary(.ready).level == .connected)
        #expect(summary(.empty).level == .connected)
        #expect(summary(.loading).level == .checking)
        #expect(summary(.ghMissing).level == .needsSetup)
        #expect(summary(.ghMissing).title == "GitHub CLI not found")
        #expect(summary(.unauthenticated).level == .needsSetup)
        for state in [DataState.partial, .stale, .error("rate limited")] {
            #expect(summary(state).level == .problem)
            #expect(summary(state).detail.contains("Recheck"))
        }
        #expect(summary(.error("rate limited")).detail.contains("rate limited"))
        #expect(GhConnectionSummary(state: .ready, source: .fixtures).level == .demo)
    }

    @Test func ghDetailNeverClaimsTokenAccess() {
        let states: [DataState] = [.loading, .ready, .ghMissing, .unauthenticated, .stale, .partial, .error("x")]
        for state in states {
            let text = GhConnectionSummary(state: state, source: .githubCLI).detail.lowercased()
            #expect(!text.contains("paste") && !text.contains("token:") && !text.contains("pat "))
        }
    }

    @Test func statusSourceIsSeparateAndHonest() {
        #expect(StatusSourceSummary.line(state: .operational, incidentCount: 0, source: .githubCLI) == "No active GitHub incidents")
        #expect(StatusSourceSummary.line(state: .incidents, incidentCount: 2, source: .githubCLI) == "2 active GitHub incidents")
        #expect(StatusSourceSummary.line(state: .stale, incidentCount: 0, source: .githubCLI) == "GitHub status is stale")
        #expect(StatusSourceSummary.line(state: .operational, incidentCount: 0, source: .fixtures) == "Demo incidents (fixtures)")
    }
}

@Suite struct FeatureFlagTests {
    @Test func privacyAndSnoozeStayVisibleUntilIssues94And95() {
        #expect(FeatureFlags.privacyMode && FeatureFlags.snooze)
    }
}
