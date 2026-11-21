import Foundation
import Testing
@testable import GitHubPet
@testable import GitHubPetCore

/// #94, #95, #107 through the real AppModel: upgrading with privacy, an active snooze and quiet
/// hours covering now stored gives full titles and normal alerts while the features are hidden,
/// without touching the stored preferences. In-memory defaults only.
@Suite(.serialized) @MainActor struct HiddenFeaturesAppTests {
    /// 2026-09-21 10:13 UTC; quiet hours below span the whole local day except its last minute.
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func upgradedDefaults() -> EphemeralDefaults {
        let defaults = EphemeralDefaults(name: "hidden-features.app.tests.\(UUID().uuidString)")
        var stored = PetSettings()
        stored.dataSource = .fixtures
        stored.privacyMode = true
        stored.snoozeUntil = now.addingTimeInterval(4 * 3600)
        stored.quietHours = QuietHours(enabled: true, startMinute: 0, endMinute: 24 * 60 - 1)
        SettingsStore(defaults: defaults).save(stored)
        return defaults
    }

    private func app(_ defaults: EphemeralDefaults, features: FeatureSet) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--defaults-suite", "hidden-features-tests", "--placeholder"],
                                          environment: [:])
        options.forcePlaceholder = true
        options.userDefaultsOverride = defaults
        return AppModel(options: options, runtime: AppModel.Runtime(
            now: { [now] in now }, systemReducedMotion: { false }, schedulesTimers: false, features: features))
    }

    @Test func upgradeWithStoredValuesShowsTitlesAndAlertsWhileHidden() throws {
        let defaults = upgradedDefaults()
        let before = try #require(defaults.data(forKey: SettingsStore.key))
        let app = app(defaults, features: .allOff)
        #expect(app.settings.privacyMode && app.settings.snoozeUntil != nil && app.settings.quietHours.enabled)
        #expect(!app.privacyMode && !app.inboxPrivacy)
        #expect(app.alertsAllowed)
        let item = try #require(app.items.first)
        #expect(app.hoverLines(compact: false).contains { $0.contains(item.title) }, "full titles in the hover")
        #expect(PrivacyText.title(item, privacy: app.inboxPrivacy) == item.title)
        // A new event plays its gesture: nothing is silently suppressed.
        app.markAllSeen()
        app.injectEntitlementEvent()
        #expect(app.activeClip != nil && app.showsAlertIcon)
        #expect(defaults.data(forKey: SettingsStore.key) == before, "stored preferences are untouched")
    }

    @Test func sameStoredValuesBehaveAsBeforeWhenShown() throws {
        let app = app(upgradedDefaults(), features: .allOn)
        #expect(app.privacyMode && app.inboxPrivacy && !app.alertsAllowed)
        let item = try #require(app.items.first)
        #expect(!app.hoverLines(compact: false).contains { $0.contains(item.title) })
        app.markAllSeen()
        app.injectEntitlementEvent()
        #expect(app.activeClip == nil && !app.showsAlertIcon)
    }

    @Test func hiddenAlertsPaneOpensTheGitHubPaneWithTheReviewFilter() {
        #expect(SettingsView.visiblePane(.alerts, features: .allOff) == .github)
        #expect(SettingsView.visiblePane(.mascot, features: .allOff) == .mascot)
        #expect(SettingsView.visiblePane(.alerts, features: .allOn) == .alerts)
    }
}
