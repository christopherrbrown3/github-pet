import Foundation
import Testing
@testable import GitHubPetCore

/// #94 privacy mode, #95 snooze, #107 quiet hours: hidden for the beta behind one switch each.
/// While hidden their effective values are off whatever is stored; shown, they behave as before.
@Suite struct HiddenFeaturesTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    /// 2027-01-15 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_800_014_400)

    /// Everything an earlier build could have left on: privacy, an active snooze and quiet hours
    /// covering now.
    private var upgraded: PetSettings {
        var settings = PetSettings()
        settings.privacyMode = true
        settings.snoozeUntil = noon.addingTimeInterval(4 * 3600)
        settings.quietHours = QuietHours(enabled: true, startMinute: 11 * 60, endMinute: 13 * 60)
        return settings
    }

    @Test func hiddenFeaturesAreEffectivelyOff() {
        let settings = upgraded
        #expect(!settings.effectivePrivacyMode(features: .allOff))
        #expect(!settings.isSnoozed(at: noon, features: .allOff))
        #expect(!settings.quietHoursActive(at: noon, calendar: utc, features: .allOff))
        #expect(settings.alertsAllowed(at: noon, calendar: utc, features: .allOff))
        let state = AlertSuppression(settings, at: noon, calendar: utc, features: .allOff)
        #expect(!state.isSnoozed && !state.quietHoursOn && !state.quietHoursActive && !state.interruptionsSuppressed)
    }

    @Test func shownFeaturesBehaveAsBefore() {
        let settings = upgraded
        #expect(settings.effectivePrivacyMode(features: .allOn))
        #expect(settings.isSnoozed(at: noon, features: .allOn))
        #expect(settings.quietHoursActive(at: noon, calendar: utc, features: .allOn))
        #expect(!settings.alertsAllowed(at: noon, calendar: utc, features: .allOn))
        #expect(AlertSuppression(settings, at: noon, calendar: utc, features: .allOn).interruptionsSuppressed)
    }

    @Test func eachSwitchGatesOnlyItsOwnFeature() {
        var settings = upgraded
        let onlySnooze = FeatureSet(privacyMode: false, snooze: true, quietHours: false)
        #expect(!settings.alertsAllowed(at: noon, calendar: utc, features: onlySnooze))
        #expect(!settings.effectivePrivacyMode(features: onlySnooze))
        let onlyQuiet = FeatureSet(privacyMode: false, snooze: false, quietHours: true)
        settings.snoozeUntil = nil
        #expect(!settings.alertsAllowed(at: noon, calendar: utc, features: onlyQuiet))
        settings.quietHours.enabled = false
        #expect(settings.alertsAllowed(at: noon, calendar: utc, features: onlyQuiet))
        let onlyPrivacy = FeatureSet(privacyMode: true, snooze: false, quietHours: false)
        #expect(upgraded.effectivePrivacyMode(features: onlyPrivacy))
        #expect(upgraded.alertsAllowed(at: noon, calendar: utc, features: onlyPrivacy))
    }

    @Test func storedValuesSurviveAHiddenRoundTrip() throws {
        // Upgrading never rewrites what an earlier build stored: load and save keep every value,
        // so bringing a feature back restores the user's own choice.
        let defaults = EphemeralDefaults(name: "hidden-features.tests.\(UUID().uuidString)")
        let store = SettingsStore(defaults: defaults)
        store.save(upgraded)
        let loaded = store.load()
        #expect(loaded.privacyMode && loaded.snoozeUntil == upgraded.snoozeUntil && loaded.quietHours == upgraded.quietHours)
        store.save(loaded)
        #expect(store.load() == upgraded.sanitized())
    }

    @Test func storedSnoozeOrQuietHoursNeverCancelAGestureWhileHidden() {
        let start = PetSettings()
        #expect(!GestureCancellation.shouldCancel(from: start, to: upgraded, at: noon, calendar: utc, features: .allOff))
        #expect(GestureCancellation.shouldCancel(from: start, to: upgraded, at: noon, calendar: utc, features: .allOn))
    }

    @Test func alertsTabOnlyWhileOneOfItsFeaturesIsShown() {
        #expect(FeatureSet.allOff.settingsPanes == [.mascot, .github])
        #expect(!FeatureSet.allOff.showsAlertsPane)
        #expect(FeatureSet.allOn.settingsPanes == [.mascot, .alerts, .github])
        for features in [FeatureSet(privacyMode: true, snooze: false, quietHours: false),
                         FeatureSet(privacyMode: false, snooze: true, quietHours: false),
                         FeatureSet(privacyMode: false, snooze: false, quietHours: true)] {
            #expect(features.settingsPanes == [.mascot, .alerts, .github])
        }
    }
}
