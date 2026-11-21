import Foundation

/// The three Settings panes (#87). Order is the tab order.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case mascot, alerts, github

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mascot: return "Mascot"
        case .alerts: return "Alerts"
        case .github: return "GitHub"
        }
    }

    public var symbol: String {
        switch self {
        case .mascot: return "pawprint"
        case .alerts: return "bell.badge"
        case .github: return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// What snooze and quiet hours are doing right now, in words. Both only silence interruptions
/// (mascot motion and menu-bar attention); fetching and the inbox are never affected.
public struct AlertSuppression: Equatable, Sendable {
    public var snoozeUntil: Date?
    public var quietHoursOn: Bool
    public var quietHoursActive: Bool
    public var quietWindow: String

    public init(_ settings: PetSettings, at now: Date, calendar: Calendar = .current, features: FeatureSet = .current) {
        snoozeUntil = settings.isSnoozed(at: now, features: features) ? settings.snoozeUntil : nil
        quietHoursOn = features.quietHours && settings.quietHours.enabled
            && settings.quietHours.startMinute != settings.quietHours.endMinute
        quietHoursActive = settings.quietHoursActive(at: now, calendar: calendar, features: features)
        quietWindow = Self.label(settings.quietHours.startMinute, calendar) + " to "
            + Self.label(settings.quietHours.endMinute, calendar)
    }

    public var isSnoozed: Bool { snoozeUntil != nil }
    public var interruptionsSuppressed: Bool { isSnoozed || quietHoursActive }

    public var snoozeLine: String {
        guard let snoozeUntil else { return "Not snoozed" }
        return "Snoozed until \(snoozeUntil.formatted(date: .abbreviated, time: .shortened))"
    }

    public var quietHoursLine: String {
        if !quietHoursOn { return "Quiet hours are off" }
        return quietHoursActive ? "Quiet hours are active now (\(quietWindow))"
                                : "Quiet hours are on (\(quietWindow)), not active now"
    }

    /// One summary line for the top of the Alerts pane.
    public var summaryLine: String {
        interruptionsSuppressed ? "Interruptions are silenced right now." : "Interruptions are allowed right now."
    }

    public static let explanation =
        "Snooze and quiet hours suppress interruptions only. GitHub Pet keeps fetching, the inbox keeps updating, and counts stay accurate; the mascot and menu-bar icon just stay calm."

    private static func label(_ minute: Int, _ calendar: Calendar) -> String {
        let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date(timeIntervalSince1970: 0)) ?? Date(timeIntervalSince1970: 0)
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The GitHub CLI connection as the GitHub pane states it. Every non-connected state says what
/// is wrong and what to do; none is ever presented as a healthy, empty inbox.
public struct GhConnectionSummary: Equatable, Sendable {
    public enum Level: Equatable, Sendable { case connected, checking, demo, needsSetup, problem }

    public var level: Level
    public var title: String
    public var detail: String
    /// The icon's SF Symbol name.
    public var symbol: String

    public init(state: DataState, source: DataSourceMode) {
        guard source == .githubCLI else {
            level = .demo; symbol = "testtube.2"; title = "Demo data (offline)"
            detail = "Showing fixtures. Choose GitHub CLI as the source to see your own GitHub activity."
            return
        }
        switch state {
        case .loading:
            level = .checking; symbol = "arrow.triangle.2.circlepath"; title = "Checking the GitHub CLI…"
            detail = "Asking gh for your GitHub activity."
        case .ready, .empty, .hiddenOnly:
            level = .connected; symbol = "checkmark.circle.fill"; title = "Connected through gh"
            detail = "GitHub data is current."
        case .partial:
            level = .problem; symbol = "exclamationmark.triangle.fill"; title = "Connected, partial data"
            detail = "Some sources did not answer. Counts may be incomplete. Recheck to try again."
        case .stale:
            level = .problem; symbol = "clock.badge.exclamationmark"; title = "Connected, data is stale"
            detail = "The last update failed, so these are older results. Recheck to try again."
        case .ghMissing:
            level = .needsSetup; symbol = "terminal"; title = "GitHub CLI not found"
            detail = "GitHub Pet reads GitHub only through the gh command. Install it, then Recheck."
        case .unauthenticated:
            level = .needsSetup; symbol = "person.crop.circle.badge.exclamationmark"; title = "Not signed in to gh"
            detail = "Sign in with gh in Terminal, then Recheck. GitHub Pet never sees your token."
        case .error(let message):
            level = .problem; symbol = "xmark.octagon.fill"; title = "GitHub CLI error"
            detail = message.isEmpty ? "gh failed. Recheck to try again." : "\(message). Recheck to try again."
        }
    }
}

/// The public GitHub status feed as its own source row in the GitHub pane.
public enum StatusSourceSummary {
    public static func line(state: ServiceStatusState, incidentCount: Int, source: DataSourceMode) -> String {
        guard source == .githubCLI else { return "Demo incidents (fixtures)" }
        return state.statusText(count: incidentCount)
    }
}

/// One switch per feature hidden from the UI for the beta (#94 privacy mode / Show details,
/// #95 snooze, #107 quiet hours). Flip one to `true` to bring the feature back: every entry point
/// checks it through `FeatureSet`, and the implementation and tests stay in place.
public enum FeatureFlags {
    public static let privacyMode = false
    public static let snooze = false
    public static let quietHours = false
}

/// Which hideable features are available. While one is hidden its *effective* value is off
/// (privacy off, snooze inactive, quiet hours disabled), whatever an earlier build stored, so no
/// one is stuck in a state they can't see or undo. Stored preferences are never rewritten.
public struct FeatureSet: Equatable, Sendable {
    public var privacyMode: Bool
    public var snooze: Bool
    public var quietHours: Bool

    public init(privacyMode: Bool, snooze: Bool, quietHours: Bool) {
        self.privacyMode = privacyMode
        self.snooze = snooze
        self.quietHours = quietHours
    }

    /// The build's switches.
    public static let current = FeatureSet(privacyMode: FeatureFlags.privacyMode, snooze: FeatureFlags.snooze,
                                           quietHours: FeatureFlags.quietHours)
    public static let allOn = FeatureSet(privacyMode: true, snooze: true, quietHours: true)
    public static let allOff = FeatureSet(privacyMode: false, snooze: false, quietHours: false)

    /// The Alerts pane has something besides the review filter only while one of these is shown.
    public var showsAlertsPane: Bool { privacyMode || snooze || quietHours }

    /// Settings panes in tab order. With every alert feature hidden, the review filter moves to
    /// the GitHub pane and there is no Alerts tab.
    public var settingsPanes: [SettingsPane] {
        showsAlertsPane ? [.mascot, .alerts, .github] : [.mascot, .github]
    }
}
