import Foundation
import Testing
@testable import GitHubPetCore

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func utc(_ hour: Int, _ minute: Int, day: Int = 12) -> Date {
    utcCalendar().date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

@Suite struct QuietHoursTests {
    @Test func disabledNeverQuiet() {
        #expect(!QuietHours(enabled: false).contains(utc(23, 0), calendar: utcCalendar()))
    }

    @Test func wrapsPastMidnightWithHalfOpenBoundaries() {
        let quiet = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        let cal = utcCalendar()
        #expect(!quiet.contains(utc(21, 59), calendar: cal))
        #expect(quiet.contains(utc(22, 0), calendar: cal))
        #expect(quiet.contains(utc(0, 0), calendar: cal))
        #expect(quiet.contains(utc(6, 59), calendar: cal))
        #expect(!quiet.contains(utc(7, 0), calendar: cal))
    }

    @Test func sameDayWindow() {
        let quiet = QuietHours(enabled: true, startMinute: 12 * 60, endMinute: 13 * 60)
        let cal = utcCalendar()
        #expect(quiet.contains(utc(12, 30), calendar: cal))
        #expect(!quiet.contains(utc(13, 0), calendar: cal))
        #expect(!quiet.contains(utc(11, 59), calendar: cal))
    }

    @Test func equalStartAndEndMeansNoQuietTime() {
        let quiet = QuietHours(enabled: true, startMinute: 600, endMinute: 600)
        #expect(!quiet.contains(utc(10, 0), calendar: utcCalendar()))
    }

    @Test func usesCalendarTimeZone() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let quiet = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        // 14:00 UTC is 23:00 in Tokyo.
        #expect(quiet.contains(utc(14, 0), calendar: tokyo))
        #expect(!quiet.contains(utc(14, 0), calendar: utcCalendar()))
    }

    @Test func wallClockIsPreservedAcrossDaylightSavingFallBack() {
        // 2026-11-01 is the US fall-back day: 22:00 local must still be 22:00, not 21:00.
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = la.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        let quiet = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        let tenPM = la.date(bySettingHour: 22, minute: 0, second: 0, of: day)!
        #expect(la.component(.hour, from: tenPM) == 22)
        #expect(quiet.contains(tenPM, calendar: la))
        #expect(!quiet.contains(tenPM.addingTimeInterval(-60), calendar: la))
        // The naive "midnight + seconds" approach is an hour off on this day.
        let naive = la.startOfDay(for: day).addingTimeInterval(22 * 3600)
        #expect(la.component(.hour, from: naive) == 21)
    }

    @Test func minutesAreClamped() {
        let quiet = QuietHours(enabled: true, startMinute: -5, endMinute: 99_999)
        #expect(quiet.startMinute == 0)
        #expect(quiet.endMinute == 24 * 60 - 1)
    }
}

@Suite struct SnoozeTests {
    @Test func snoozeExpiresExactlyAtDeadline() {
        var settings = PetSettings()
        let now = utc(10, 0)
        settings.snoozeUntil = SnoozeOption.oneHour.until(from: now)
        #expect(settings.isSnoozed(at: now))
        #expect(!settings.alertsAllowed(at: now, calendar: utcCalendar()))
        #expect(settings.isSnoozed(at: utc(10, 59)))
        #expect(!settings.isSnoozed(at: utc(11, 0)))
        #expect(settings.alertsAllowed(at: utc(11, 0), calendar: utcCalendar()))
    }

    @Test func untilTomorrowMorning() {
        let until = SnoozeOption.untilTomorrowMorning.until(from: utc(23, 30), calendar: utcCalendar())
        #expect(until == utc(9, 0, day: 13))
    }

    @Test func quietHoursAlsoBlockAlerts() {
        var settings = PetSettings()
        settings.quietHours = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(!settings.alertsAllowed(at: utc(23, 0), calendar: utcCalendar()))
        #expect(settings.alertsAllowed(at: utc(12, 0), calendar: utcCalendar()))
    }
}

@Suite struct SettingsPersistenceTests {
    private func freshDefaults() -> UserDefaults {
        let name = "GitHubPetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsWhenNothingStored() {
        let settings = SettingsStore(defaults: freshDefaults()).load()
        #expect(settings == PetSettings())
        #expect(settings.mascotVisible)
        #expect(!settings.reducedMotion)
        #expect(!settings.privacyMode)
        #expect(settings.dataSource == .fixtures)
    }

    @Test func roundTripsEveryField() {
        let defaults = freshDefaults()
        var settings = PetSettings()
        settings.mascotVisible = false
        settings.mascotSize = 192
        settings.mascotOriginX = 100
        settings.mascotOriginY = 240
        settings.privacyMode = true
        settings.reducedMotion = true
        settings.snoozeUntil = Date(timeIntervalSince1970: 1_800_000_000)
        settings.quietHours = QuietHours(enabled: true, startMinute: 60, endMinute: 120)
        settings.dataSource = .githubCLI
        SettingsStore(defaults: defaults).save(settings)
        #expect(SettingsStore(defaults: defaults).load() == settings)
    }

    @Test func corruptPayloadFallsBackToDefaults() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: SettingsStore.key)
        #expect(SettingsStore(defaults: defaults).load() == PetSettings())
    }

    @Test func partialAndUnknownKeysAreTolerated() throws {
        let json = #"{"schemaVersion":2,"privacyMode":true,"mascotSize":"huge","futureKey":1,"dataSource":"carrier-pigeon"}"#
        let settings = try JSONDecoder().decode(PetSettings.self, from: Data(json.utf8))
        #expect(settings.privacyMode)
        #expect(settings.mascotSize == PetSettings().mascotSize)
        #expect(settings.dataSource == .fixtures)
    }

    @Test func outOfRangeValuesAreClamped() throws {
        let json = #"{"mascotSize":5000,"mascotOriginX":10}"#
        let settings = try JSONDecoder().decode(PetSettings.self, from: Data(json.utf8))
        #expect(settings.mascotSize == 256)
        #expect(settings.mascotOriginX == nil, "half a position is discarded")
    }
}
