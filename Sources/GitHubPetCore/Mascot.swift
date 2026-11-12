import Foundation

/// Pack states agreed with design (pack schema v1).
public enum MascotState: String, Codable, CaseIterable, Sendable {
    case idle
    case attention
    case urgent
}

public enum MascotPolicy {
    /// Persistent mood. Unknown or degraded data never reads as "all clear": it stays idle
    /// and the native status text carries the quality. Auth/setup problems and critical
    /// items are urgent; unseen new events are attention only while alerts are allowed.
    public static func state(dataState: DataState, items: [InboxItem], unseenCount: Int,
                             alertsAllowed: Bool) -> MascotState {
        switch dataState {
        case .ghMissing, .unauthenticated: return .urgent
        default: break
        }
        if dataState.hasUsableItems && items.contains(where: { $0.kind.severity == .critical }) {
            return .urgent
        }
        if alertsAllowed && unseenCount > 0 { return .attention }
        return .idle
    }

    /// Badge text: nil when the count is unknown, "N+" for a lower bound, otherwise "N".
    public static func badge(dataState: DataState, count: Int) -> String? {
        switch dataState {
        case .ready, .empty: return count > 0 ? "\(count)" : nil
        case .partial: return "\(count)+"
        case .stale: return count > 0 ? "\(count)" : nil
        default: return nil
        }
    }
}

/// Privacy-aware text for rows, the hover summary and accessibility labels.
public enum PrivacyText {
    public static func title(_ item: InboxItem, privacy: Bool) -> String {
        privacy ? item.kind.genericLabel : item.title
    }

    public static func repository(_ item: InboxItem, privacy: Bool) -> String? {
        privacy ? nil : item.repository
    }

    public static func summary(dataState: DataState, items: [InboxItem], unseenCount: Int,
                               privacy: Bool, maxLines: Int = 3) -> [String] {
        var lines: [String] = []
        if let badge = MascotPolicy.badge(dataState: dataState, count: items.count) {
            let noun = items.count == 1 && dataState != .partial ? "item" : "items"
            lines.append("\(badge) \(noun)" + (unseenCount > 0 ? " · \(unseenCount) new" : ""))
        }
        if dataState != .ready || lines.isEmpty {
            lines.append(dataState.statusText)
        }
        if dataState.hasUsableItems {
            for item in items.prefix(maxLines) {
                if let repo = repository(item, privacy: privacy) {
                    lines.append("\(item.kind.genericLabel): \(repo) — \(title(item, privacy: privacy))")
                } else {
                    lines.append(item.kind.genericLabel)
                }
            }
        }
        return lines
    }
}

/// One-shot event clips: at most one active clip and a short pending queue. Critical
/// events jump the queue; duplicate IDs are ignored; clips never loop.
public struct EventClipQueue: Sendable {
    public static let maxPending = 4
    public static let clipDuration: TimeInterval = 1.6

    public struct Clip: Equatable, Sendable {
        public var event: InboxEvent
        public var endsAt: Date
    }

    public private(set) var active: Clip?
    public private(set) var pending: [InboxEvent] = []

    public init() {}

    /// Queue new events. With motion reduced or alerts disallowed nothing is queued:
    /// the inbox and static mood still show the change.
    public mutating func enqueue(_ events: [InboxEvent], now: Date, playable: Bool) {
        guard playable else { return }
        for event in events {
            if active?.event.item.id == event.item.id
                || pending.contains(where: { $0.item.id == event.item.id }) { continue }
            pending.append(event)
        }
        pending.sort { $0.severity > $1.severity }
        if pending.count > Self.maxPending { pending.removeLast(pending.count - Self.maxPending) }
        if let current = active, let first = pending.first, first.severity > current.event.severity {
            pending.removeFirst()
            active = Clip(event: first, endsAt: now.addingTimeInterval(Self.clipDuration))
        }
        tick(now: now)
    }

    /// Advance time; returns the clip that should be showing, if any.
    @discardableResult
    public mutating func tick(now: Date) -> Clip? {
        if let current = active, now >= current.endsAt { active = nil }
        if active == nil, !pending.isEmpty {
            active = Clip(event: pending.removeFirst(), endsAt: now.addingTimeInterval(Self.clipDuration))
        }
        return active
    }

    public mutating func clear() {
        active = nil
        pending.removeAll()
    }
}

/// Picks the frame for a loop or one-shot from per-frame durations (reference
/// `mm_animation_frame`): reduced motion pins frame 0; one-shots hold the last frame.
public enum FrameClock {
    public static let minimumDurationMs = 125

    public static func frameIndex(durationsMs: [Int], loop: Bool, elapsedMs: Int, reducedMotion: Bool) -> Int {
        guard !reducedMotion, durationsMs.count > 1, elapsedMs >= 0 else { return 0 }
        let durations = durationsMs.map { max($0, minimumDurationMs) }
        let total = durations.reduce(0, +)
        var t = elapsedMs
        if loop {
            t %= total
        } else if t >= total {
            return durations.count - 1
        }
        for (index, duration) in durations.enumerated() {
            if t < duration { return index }
            t -= duration
        }
        return durations.count - 1
    }
}
