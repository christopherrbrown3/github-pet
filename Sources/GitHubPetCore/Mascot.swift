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

    /// Badge text. Unknown never looks like zero: `?` whenever the count is not known
    /// (loading, stale, error, CLI missing or signed out), `N+` for a partial lower bound,
    /// `N` for a fresh known count, and no badge only for a verified, fresh empty inbox.
    public static func badge(dataState: DataState, count: Int) -> String? {
        switch dataState {
        case .ready: return "\(count)"
        case .empty: return nil
        case .partial: return "\(count)+"
        default: return "?"
        }
    }

    /// Spoken/accessible description of the count and its quality.
    public static func countDescription(dataState: DataState, count: Int) -> String {
        switch dataState {
        case .ready: return count == 1 ? "1 item" : "\(count) items"
        case .empty: return "all clear"
        case .partial: return "at least \(count) items, some sources unavailable"
        case .stale: return "count unknown, data is stale"
        case .loading: return "count unknown, loading"
        default: return "count unknown, \(dataState.statusText)"
        }
    }
}

/// Privacy-aware text for rows, the hover summary and accessibility labels.
public enum PrivacyText {
    /// Label for invented fixture data. Never hidden by privacy mode.
    public static let demoLabel = "Demo"

    /// Row secondary line: optional Demo tag, category, and repository unless private.
    public static func subtitle(_ item: InboxItem, privacy: Bool) -> String {
        var parts: [String] = []
        if item.isDemo { parts.append(demoLabel) }
        parts.append(item.kind.genericLabel)
        if let repo = repository(item, privacy: privacy) { parts.append(repo) }
        return parts.joined(separator: " · ")
    }

    public static func title(_ item: InboxItem, privacy: Bool) -> String {
        privacy ? item.kind.genericLabel : item.title
    }

    public static func repository(_ item: InboxItem, privacy: Bool) -> String? {
        privacy ? nil : item.repository
    }

    /// At most two lines for small mascots (hover beside a small character, #27): Demo or the
    /// count, and the count's quality. Unknown, partial, stale and failed data stay explicit;
    /// item details are left to the Inbox.
    public static func compactSummary(dataState: DataState, items: [InboxItem], unseenCount: Int,
                                      demo: Bool = false) -> [String] {
        let quality: String
        switch dataState {
        case .ready:
            let noun = items.count == 1 ? "item" : "items"
            quality = "\(items.count) \(noun)" + (unseenCount > 0 ? " · \(unseenCount) new" : "")
        case .partial:
            let badge = MascotPolicy.badge(dataState: dataState, count: items.count) ?? "?"
            quality = "\(badge) items · \(dataState.statusText)"
        default:
            quality = dataState.statusText
        }
        return demo ? ["\(demoLabel) data (fixtures)", quality] : [quality, "Open the Inbox for details"]
    }

    public static func summary(dataState: DataState, items: [InboxItem], unseenCount: Int,
                               privacy: Bool, demo: Bool = false, maxLines: Int = 3) -> [String] {
        var lines: [String] = demo ? ["\(demoLabel) data (fixtures)"] : []
        switch dataState {
        case .ready, .partial:
            let badge = MascotPolicy.badge(dataState: dataState, count: items.count) ?? ""
            let noun = items.count == 1 && dataState == .ready ? "item" : "items"
            lines.append("\(badge) \(noun)" + (unseenCount > 0 ? " · \(unseenCount) new" : ""))
            if dataState == .partial { lines.append(dataState.statusText) }
        default:
            lines.append(dataState.statusText)
        }
        if dataState.hasUsableItems {
            for item in items.prefix(maxLines) {
                let tag = item.isDemo ? "\(demoLabel) · " : ""
                if let repo = repository(item, privacy: privacy) {
                    lines.append("\(tag)\(item.kind.genericLabel): \(repo) — \(title(item, privacy: privacy))")
                } else {
                    lines.append(tag + item.kind.genericLabel)
                }
            }
        }
        return lines
    }
}

public enum AccessibilityText {
    /// e.g. "GitHub Pet, Demo data, at least 2 items, some sources unavailable".
    public static func statusLabel(dataState: DataState, count: Int, demo: Bool, needsAttention: Bool) -> String {
        var parts = ["GitHub Pet"]
        if demo { parts.append("\(PrivacyText.demoLabel) data") }
        parts.append(MascotPolicy.countDescription(dataState: dataState, count: count))
        if needsAttention { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}

/// One-shot event clips: at most one active clip and a short pending queue. Critical
/// events jump the queue; duplicate IDs are ignored; clips never loop.
public struct EventClipQueue: Sendable {
    public static let maxPending = 4
    /// Long enough for the v1 pack's one-shot sequences (1.9 s) and within the 0.8–2.0 s budget.
    public static let clipDuration: TimeInterval = 2.0

    public struct Clip: Equatable, Sendable {
        public var event: InboxEvent
        public var startedAt: Date
        public var endsAt: Date

        init(event: InboxEvent, startedAt: Date) {
            self.event = event
            self.startedAt = startedAt
            self.endsAt = startedAt.addingTimeInterval(EventClipQueue.clipDuration)
        }

        /// Pack state used to play this clip.
        public var state: MascotState { event.severity == .critical ? .urgent : .attention }
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
            active = Clip(event: first, startedAt: now)
        }
        tick(now: now)
    }

    /// Advance time; returns the clip that should be showing, if any.
    @discardableResult
    public mutating func tick(now: Date) -> Clip? {
        if let current = active, now >= current.endsAt { active = nil }
        if active == nil, !pending.isEmpty {
            active = Clip(event: pending.removeFirst(), startedAt: now)
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

/// What the mascot shows at an instant: a state plus either a frame index or its static pose.
public struct MascotPose: Equatable, Sendable {
    public var state: MascotState
    /// nil means the state's `staticFallback`.
    public var frame: Int?
    /// Seconds into the active event clip, if one is playing.
    public var clipElapsed: TimeInterval?

    public init(state: MascotState, frame: Int?, clipElapsed: TimeInterval?) {
        self.state = state
        self.frame = frame
        self.clipElapsed = clipElapsed
    }
}

/// Pure animation policy shared by the artwork pack and the placeholder.
///
/// - An active event clip plays its state's one-shot sequence from the clip's own start,
///   so every new event replays it even if the mood is already `attention`.
/// - Without a clip, `idle` loops; `attention` and `urgent` hold their static pose, so a mood
///   change alone (e.g. while snoozed, when clips are suppressed) never animates.
/// - Reduced motion always shows the mood's static pose.
public enum MascotAnimator {
    public static func pose(mood: MascotState, clip: EventClipQueue.Clip?, now: Date, reducedMotion: Bool,
                            idleEpoch: Date, durationsMs: (MascotState) -> [Int]) -> MascotPose {
        if reducedMotion { return MascotPose(state: mood, frame: nil, clipElapsed: nil) }
        if let clip, now >= clip.startedAt, now < clip.endsAt {
            let elapsed = now.timeIntervalSince(clip.startedAt)
            let frame = FrameClock.frameIndex(durationsMs: durationsMs(clip.state), loop: false,
                                              elapsedMs: Int(elapsed * 1000), reducedMotion: false)
            return MascotPose(state: clip.state, frame: frame, clipElapsed: elapsed)
        }
        guard mood == .idle else { return MascotPose(state: mood, frame: nil, clipElapsed: nil) }
        let elapsedMs = Int(max(0, now.timeIntervalSince(idleEpoch)) * 1000)
        return MascotPose(state: .idle, frame: FrameClock.frameIndex(durationsMs: durationsMs(.idle), loop: true,
                                                                    elapsedMs: elapsedMs, reducedMotion: false),
                          clipElapsed: nil)
    }
}
