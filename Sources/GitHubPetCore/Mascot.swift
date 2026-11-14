import CoreGraphics
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
    /// Largest count the mascot's badge shows; its slot is sized for "99+".
    public static let mascotBadgeCap = 99

    /// The mascot's badge: like `badge`, but counts above 99 show as "99+" so the label always fits
    /// its reserved slot. The inbox and accessibility text keep the full count.
    public static func mascotBadge(dataState: DataState, count: Int) -> String? {
        guard let full = badge(dataState: dataState, count: count) else { return nil }
        let capped = (dataState == .ready || dataState == .partial) && count > mascotBadgeCap
        return capped ? "\(mascotBadgeCap)+" : full
    }

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
/// At most one event gesture at a time (#29). A batch of new events plays one gesture, led by its
/// most severe event; events arriving while it plays merge into it (no restart, no queue, no
/// backlog). Only an urgent batch preempts an attention gesture, and the interrupted gesture is
/// not replayed. After a gesture ends, a later batch may start a new one.
public struct EventClipQueue: Sendable {
    public struct Clip: Equatable, Sendable {
        public var event: InboxEvent
        public var startedAt: Date
        public var endsAt: Date

        init(event: InboxEvent, startedAt: Date) {
            self.event = event
            self.startedAt = startedAt
            self.endsAt = startedAt.addingTimeInterval(EventClipQueue.duration(of: event.severity == .critical ? .urgent : .attention))
        }

        /// Pack state used to play this clip.
        public var state: MascotState { event.severity == .critical ? .urgent : .attention }
    }

    /// Attention plays the finite double wave (1.9 s); urgent keeps its 2.0 s one-shot.
    public static func duration(of state: MascotState) -> TimeInterval {
        state == .attention ? TimeInterval(AttentionGesture.friendlyDoubleWave.durationMs) / 1000 : 2.0
    }

    public private(set) var active: Clip?

    public init() {}

    /// Start a gesture for a batch of new events, or merge them into the one playing. With motion
    /// reduced or alerts disallowed nothing plays: the inbox and static mood still show the change,
    /// and nothing is replayed later.
    public mutating func enqueue(_ events: [InboxEvent], now: Date, playable: Bool) {
        tick(now: now)
        guard playable, let top = events.map(\.severity).max(),
              let lead = events.first(where: { $0.severity == top }) else { return }
        if let current = active {
            if lead.severity > current.event.severity { active = Clip(event: lead, startedAt: now) }
            return
        }
        active = Clip(event: lead, startedAt: now)
    }

    /// Advance time; returns the clip that should be showing, if any.
    @discardableResult
    public mutating func tick(now: Date) -> Clip? {
        if let current = active, now >= current.endsAt { active = nil }
        return active
    }

    public mutating func clear() {
        active = nil
    }
}

/// The attention "friendly double wave" (design #29, docs/design/notifications/
/// attention-storyboard.json): existing attention frames 00/01/02/01/02/03 with an art-layer lean
/// of 0/−5/+5/−5/+5/0° about the ground anchor [128, 232]. Each step's angle is reached at its
/// start, eased with cubic Bezier (0.2, 0.8, 0.2, 1) over the preceding step; the last 600 ms are
/// still. Finite: 1.9 s, no loop.
public struct AttentionGesture: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public var startMs: Int
        public var frame: Int
        public var angle: Double
    }

    public var steps: [Step]
    public var durationMs: Int
    /// Rotation pivot in canvas pixels.
    public static let pivot = CGPoint(x: 128, y: 232)

    public static let friendlyDoubleWave = AttentionGesture(steps: [
        Step(startMs: 0, frame: 0, angle: 0), Step(startMs: 150, frame: 1, angle: -5),
        Step(startMs: 400, frame: 2, angle: 5), Step(startMs: 600, frame: 1, angle: -5),
        Step(startMs: 850, frame: 2, angle: 5), Step(startMs: 1050, frame: 3, angle: 0),
        Step(startMs: 1300, frame: 3, angle: 0),
    ], durationMs: 1900)

    public var maxAngle: Double { steps.map { abs($0.angle) }.max() ?? 0 }
    /// Attention frames the gesture uses (0...3).
    public var frameCount: Int { (steps.map(\.frame).max() ?? 0) + 1 }

    private func step(atMs t: Double) -> Int {
        steps.lastIndex { Double($0.startMs) <= t } ?? 0
    }

    public func frame(atMs t: Double) -> Int { steps[step(atMs: max(0, t))].frame }

    public func angle(atMs t: Double) -> Double {
        let index = step(atMs: max(0, t))
        guard index + 1 < steps.count else { return steps[index].angle }
        let from = steps[index], to = steps[index + 1]
        let progress = (t - Double(from.startMs)) / Double(to.startMs - from.startMs)
        return from.angle + (to.angle - from.angle) * Self.ease(min(max(progress, 0), 1))
    }

    /// CSS-style cubic Bezier (0.2, 0.8, 0.2, 1): y for a given x in 0...1.
    public static func ease(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let (x1, y1, x2, y2) = (0.2, 0.8, 0.2, 1.0)
        func bezier(_ u: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if bezier(mid, x1, x2) < x { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, y1, y2)
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
    /// Art-layer lean in degrees about the ground anchor (attention gesture); positive leans right.
    public var angle: Double

    public init(state: MascotState, frame: Int?, clipElapsed: TimeInterval?, angle: Double = 0) {
        self.state = state
        self.frame = frame
        self.clipElapsed = clipElapsed
        self.angle = angle
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
    /// - Parameter gesture: the attention gesture to play when the pack supports it (its attention
    ///   state has the frames it uses); otherwise attention plays its manifest one-shot.
    public static func pose(mood: MascotState, clip: EventClipQueue.Clip?, now: Date, reducedMotion: Bool,
                            idleEpoch: Date, gesture: AttentionGesture? = nil,
                            durationsMs: (MascotState) -> [Int]) -> MascotPose {
        if reducedMotion { return MascotPose(state: mood, frame: nil, clipElapsed: nil) }
        if let clip, now >= clip.startedAt, now < clip.endsAt {
            let elapsed = now.timeIntervalSince(clip.startedAt)
            if clip.state == .attention, let gesture {
                let ms = elapsed * 1000
                return MascotPose(state: .attention, frame: gesture.frame(atMs: ms), clipElapsed: elapsed,
                                  angle: gesture.angle(atMs: ms))
            }
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
