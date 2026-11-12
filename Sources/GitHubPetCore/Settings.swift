import Foundation

public enum DataSourceMode: String, Codable, CaseIterable, Sendable {
    case fixtures
    case githubCLI
}

/// Daily quiet window in local minutes since midnight. Wraps past midnight when
/// `startMinute > endMinute`; `startMinute == endMinute` means no quiet time.
public struct QuietHours: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var startMinute: Int
    public var endMinute: Int

    public init(enabled: Bool = false, startMinute: Int = 22 * 60, endMinute: Int = 7 * 60) {
        self.enabled = enabled
        self.startMinute = QuietHours.clampMinute(startMinute)
        self.endMinute = QuietHours.clampMinute(endMinute)
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinute != endMinute else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }

    static func clampMinute(_ minute: Int) -> Int {
        min(max(minute, 0), 24 * 60 - 1)
    }
}

/// Everything the user can change. Decoding tolerates missing keys so older or newer
/// stored payloads fall back to defaults field by field.
public struct PetSettings: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let mascotSizeRange: ClosedRange<Double> = 64...256

    public var mascotVisible = true
    public var mascotSize: Double = 128
    /// Bottom-left window origin in screen coordinates; nil means the default spot.
    public var mascotOriginX: Double?
    public var mascotOriginY: Double?
    public var privacyMode = false
    public var reducedMotion = false
    public var snoozeUntil: Date?
    public var quietHours = QuietHours()
    public var dataSource: DataSourceMode = .fixtures

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, mascotVisible, mascotSize, mascotOriginX, mascotOriginY
        case privacyMode, reducedMotion, snoozeUntil, quietHours, dataSource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PetSettings()
        mascotVisible = (try? c.decodeIfPresent(Bool.self, forKey: .mascotVisible)) ?? defaults.mascotVisible
        mascotSize = (try? c.decodeIfPresent(Double.self, forKey: .mascotSize)) ?? defaults.mascotSize
        mascotOriginX = try? c.decodeIfPresent(Double.self, forKey: .mascotOriginX)
        mascotOriginY = try? c.decodeIfPresent(Double.self, forKey: .mascotOriginY)
        privacyMode = (try? c.decodeIfPresent(Bool.self, forKey: .privacyMode)) ?? defaults.privacyMode
        reducedMotion = (try? c.decodeIfPresent(Bool.self, forKey: .reducedMotion)) ?? defaults.reducedMotion
        snoozeUntil = try? c.decodeIfPresent(Date.self, forKey: .snoozeUntil)
        quietHours = (try? c.decodeIfPresent(QuietHours.self, forKey: .quietHours)) ?? defaults.quietHours
        dataSource = (try? c.decodeIfPresent(DataSourceMode.self, forKey: .dataSource)) ?? defaults.dataSource
        self = sanitized()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schemaVersion)
        try c.encode(mascotVisible, forKey: .mascotVisible)
        try c.encode(mascotSize, forKey: .mascotSize)
        try c.encodeIfPresent(mascotOriginX, forKey: .mascotOriginX)
        try c.encodeIfPresent(mascotOriginY, forKey: .mascotOriginY)
        try c.encode(privacyMode, forKey: .privacyMode)
        try c.encode(reducedMotion, forKey: .reducedMotion)
        try c.encodeIfPresent(snoozeUntil, forKey: .snoozeUntil)
        try c.encode(quietHours, forKey: .quietHours)
        try c.encode(dataSource, forKey: .dataSource)
    }

    /// Clamp out-of-range values (size, non-finite coordinates, quiet-hour minutes).
    public func sanitized() -> PetSettings {
        var copy = self
        if !copy.mascotSize.isFinite { copy.mascotSize = PetSettings().mascotSize }
        copy.mascotSize = min(max(copy.mascotSize, Self.mascotSizeRange.lowerBound),
                              Self.mascotSizeRange.upperBound)
        if let x = copy.mascotOriginX, !x.isFinite { copy.mascotOriginX = nil }
        if let y = copy.mascotOriginY, !y.isFinite { copy.mascotOriginY = nil }
        if copy.mascotOriginX == nil || copy.mascotOriginY == nil {
            copy.mascotOriginX = nil
            copy.mascotOriginY = nil
        }
        copy.quietHours = QuietHours(enabled: copy.quietHours.enabled,
                                     startMinute: copy.quietHours.startMinute,
                                     endMinute: copy.quietHours.endMinute)
        return copy
    }

    public func isSnoozed(at now: Date) -> Bool {
        guard let snoozeUntil else { return false }
        return snoozeUntil > now
    }

    /// Whether the mascot and menu-bar icon may draw attention to new events right now.
    /// The inbox itself always updates regardless.
    public func alertsAllowed(at now: Date, calendar: Calendar = .current) -> Bool {
        !isSnoozed(at: now) && !quietHours.contains(now, calendar: calendar)
    }
}

/// Persists `PetSettings` as one JSON blob in a `UserDefaults` domain.
public final class SettingsStore {
    public static let key = "GitHubPet.settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PetSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(PetSettings.self, from: data) else {
            return PetSettings()
        }
        return settings
    }

    public func save(_ settings: PetSettings) {
        guard let data = try? JSONEncoder().encode(settings.sanitized()) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}

public enum SnoozeOption: CaseIterable, Sendable {
    case oneHour, fourHours, untilTomorrowMorning

    public var title: String {
        switch self {
        case .oneHour: return "1 hour"
        case .fourHours: return "4 hours"
        case .untilTomorrowMorning: return "Until tomorrow 9:00"
        }
    }

    public func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour: return now.addingTimeInterval(3600)
        case .fourHours: return now.addingTimeInterval(4 * 3600)
        case .untilTomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }
}
