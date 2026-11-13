import Foundation

/// When a playing gesture must stop at once (#29): a settings change that newly disallows alerts
/// (snooze set, quiet hours enabled or moved over now) or newly reduces motion. A clock-driven quiet
/// window that simply begins is left to the app's periodic tick. Stopping never re-queues
/// anything, so lifting snooze or quiet hours replays nothing.
public enum GestureCancellation {
    public static func shouldCancel(from old: PetSettings, to new: PetSettings, at now: Date,
                                    calendar: Calendar = .current) -> Bool {
        let newlyQuiet = old.alertsAllowed(at: now, calendar: calendar) && !new.alertsAllowed(at: now, calendar: calendar)
        return newlyQuiet || (new.reducedMotion && !old.reducedMotion)
    }
}

/// Observes one notification for as long as the observer is alive; deinit (or `stop`) removes it.
/// Used for the system Reduce Motion change, so the centre and name are injectable for tests.
public final class SystemNotificationObserver {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    public init(center: NotificationCenter, name: Notification.Name, handler: @escaping () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() }
    }

    public var isObserving: Bool { token != nil }

    public func stop() {
        if let token { center.removeObserver(token) }
        token = nil
    }

    deinit { stop() }
}
