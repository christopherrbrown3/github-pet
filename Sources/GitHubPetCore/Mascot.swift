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
        // Zero visible is known, but it is not the verified-empty "all clear" (no badge) state.
        case .hiddenOnly: return "0"
        case .partial: return "\(count)+"
        default: return "?"
        }
    }

    /// Spoken/accessible description of the count and its quality.
    public static func countDescription(dataState: DataState, count: Int) -> String {
        switch dataState {
        case .ready: return count == 1 ? "1 item" : "\(count) items"
        case .empty: return "all clear"
        case .hiddenOnly(let hidden): return "no visible items, " + HiddenResults.matchesHidden(hidden)
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
        if let attention = item.attention { parts.append(attention) }
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
                                      demo: Bool = false, demoSource: String = "fixtures",
                                      emptyInboxMessage: String? = nil) -> [String] {
        let quality: String
        switch dataState {
        case .ready:
            let noun = items.count == 1 ? "item" : "items"
            quality = emptyInboxMessage ?? ("\(items.count) \(noun)" + (unseenCount > 0 ? " · \(unseenCount) new" : ""))
        case .partial:
            let badge = MascotPolicy.badge(dataState: dataState, count: items.count) ?? "?"
            quality = "\(badge) items · \(dataState.statusText)"
        default:
            quality = dataState.statusText
        }
        return demo ? ["\(demoLabel) data (\(demoSource))", quality] : [quality, "Open the Inbox for details"]
    }

    public static func summary(dataState: DataState, items: [InboxItem], unseenCount: Int,
                               privacy: Bool, demo: Bool = false, demoSource: String = "fixtures", maxLines: Int = 3,
                               emptyInboxMessage: String? = nil) -> [String] {
        // `demoSource` names where invented data comes from: fixtures, or the simulated scope launch.
        var lines: [String] = demo ? ["\(demoLabel) data (\(demoSource))"] : []
        switch dataState {
        case .ready, .partial:
            let badge = MascotPolicy.badge(dataState: dataState, count: items.count) ?? ""
            let noun = items.count == 1 && dataState == .ready ? "item" : "items"
            lines.append(emptyInboxMessage ?? ("\(badge) \(noun)" + (unseenCount > 0 ? " · \(unseenCount) new" : "")))
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
    public static func statusLabel(dataState: DataState, count: Int, demo: Bool, needsAttention: Bool,
                                   countDescription: String? = nil) -> String {
        var parts = ["GitHub Pet"]
        if demo { parts.append("\(PrivacyText.demoLabel) data") }
        parts.append(countDescription ?? MascotPolicy.countDescription(dataState: dataState, count: count))
        if needsAttention { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}

/// One-shot event clips: at most one active clip and a short pending queue. Critical
/// events jump the queue; duplicate IDs are ignored; clips never loop.
/// At most one event gesture at a time (#29). A batch of new events plays one gesture, led by its
/// most severe event; events arriving while it plays merge into it (no restart, no queue, no
/// backlog). Each source retains at most one clip at its original time bounds. Urgency chooses
/// the visible clip; a scope reset can remove repositories without restarting public incidents.
///
/// #138 adds a clip kind: tier-1 clips order by severity, then kind rank (urgent > incident-start >
/// incident-end > new-item, the wave included), then the earlier start. A kind's length comes from
/// the pack when it has that clip, else today's state duration.
public struct EventClipQueue: Sendable {
    public enum Origin: Hashable, Sendable { case repository, serviceIncident }

    /// What a tier-1 clip plays, low to high rank. `newItem` is the #29 wave when the pack has no
    /// `new-item` clip; incident kinds are chosen only when the pack has those clips.
    public enum Kind: Int, Comparable, CaseIterable, Sendable {
        case newItem = 0, incidentEnd, incidentStart, urgent

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var clipID: MascotClipID? {
            switch self {
            case .newItem: return .newItem
            case .incidentEnd: return .incidentEnd
            case .incidentStart: return .incidentStart
            case .urgent: return nil
            }
        }

        /// A repository event's kind: critical plays urgent, anything else the wave (or new-item).
        public static func `default`(for event: InboxEvent) -> Self { event.severity == .critical ? .urgent : .newItem }
    }

    public struct Clip: Equatable, Sendable {
        public var event: InboxEvent
        public var origin: Origin
        public var kind: Kind
        public var startedAt: Date
        public var endsAt: Date

        public init(event: InboxEvent, startedAt: Date, origin: Origin = .repository, kind: Kind? = nil,
             duration: TimeInterval? = nil) {
            self.event = event
            self.origin = origin
            self.kind = kind ?? .default(for: event)
            self.startedAt = startedAt
            self.endsAt = startedAt.addingTimeInterval(duration ?? EventClipQueue.duration(of: self.kind == .urgent ? .urgent : .attention))
        }

        /// Pack state used to play this clip (and its fallback).
        public var state: MascotState { kind == .urgent ? .urgent : .attention }

        /// Order between clips: severity, then kind rank, then the earlier start wins.
        func outranks(_ other: Clip) -> Bool {
            if event.severity != other.event.severity { return event.severity > other.event.severity }
            if kind != other.kind { return kind > other.kind }
            return startedAt < other.startedAt
        }
    }

    /// Attention plays the finite double wave (1.9 s); urgent keeps its 2.0 s one-shot.
    public static func duration(of state: MascotState) -> TimeInterval {
        state == .attention ? TimeInterval(AttentionGesture.friendlyDoubleWave.durationMs) / 1000 : 2.0
    }

    // At most two independently timed clips. Clearing repositories must not discard a
    // concurrent incident that merged behind a higher-priority repository gesture.
    private var byOrigin: [Origin: Clip] = [:]
    public var active: Clip? {
        let repository = byOrigin[.repository], service = byOrigin[.serviceIncident]
        guard let repository else { return service }
        guard let service else { return repository }
        return service.outranks(repository) ? service : repository
    }

    public init() {}

    /// Start a gesture for a batch of new events, or merge them into the one playing. With motion
    /// reduced or alerts disallowed nothing plays: the inbox and static mood still show the change,
    /// and nothing is replayed later.
    /// - Parameters:
    ///   - kind: the clip kind for this batch (#138), or nil for today's (urgent or the wave).
    ///   - duration: a kind's length from the pack, or nil for today's state duration.
    public mutating func enqueue(_ events: [InboxEvent], now: Date, playable: Bool, origin: Origin = .repository,
                                 kind: Kind? = nil, duration: (Kind) -> TimeInterval? = { _ in nil }) {
        tick(now: now)
        guard playable, let top = events.map(\.severity).max(),
              let lead = events.first(where: { $0.severity == top }) else { return }
        // An incident is never urgent: its state comes from its kind, not its severity.
        let resolved = kind ?? (origin == .serviceIncident ? .newItem : .default(for: lead))
        let next = Clip(event: lead, startedAt: now, origin: origin, kind: resolved, duration: duration(resolved))
        if let current = byOrigin[origin] {
            // Merge (#29): only a higher severity or kind restarts this source's clip.
            if (lead.severity, resolved) > (current.event.severity, current.kind) { byOrigin[origin] = next }
            return
        }
        byOrigin[origin] = next
    }

    /// Advance time; returns the clip that should be showing, if any.
    @discardableResult
    public mutating func tick(now: Date) -> Clip? {
        // Hidden source state exists only to preserve incidents across an explicit scope
        // reset. Natural completion coalesces the whole batch, never promotes a backlog.
        if let visible = active, now >= visible.endsAt {
            byOrigin.removeAll()
            return nil
        }
        byOrigin = byOrigin.filter { now < $0.value.endsAt }
        return active
    }

    public mutating func clear(origin: Origin? = nil) {
        if let origin { byOrigin.removeValue(forKey: origin) } else { byOrigin.removeAll() }
    }

    public mutating func clear(origin: Origin, matching predicate: (InboxEvent) -> Bool) {
        if let clip = byOrigin[origin], predicate(clip.event) { clear(origin: origin) }
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
    /// Clip and looping-state frames (#138 frame sequences) may be this short.
    public static let minimumClipDurationMs = MascotPack.clipDurationRange.lowerBound

    public static func frameIndex(durationsMs: [Int], loop: Bool, elapsedMs: Int, reducedMotion: Bool,
                                  minimumMs: Int = minimumDurationMs) -> Int {
        guard !reducedMotion, durationsMs.count > 1, elapsedMs >= 0 else { return 0 }
        let durations = durationsMs.map { max($0, minimumMs) }
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

    /// #166: the first elapsed millisecond after `elapsedMs` at which `frameIndex` returns another
    /// frame, or nil once it never changes again (a single frame, reduced motion, a finished one-shot).
    public static func nextChangeMs(durationsMs: [Int], loop: Bool, elapsedMs: Int, reducedMotion: Bool,
                                    minimumMs: Int = minimumDurationMs) -> Int? {
        guard !reducedMotion, durationsMs.count > 1 else { return nil }
        let durations = durationsMs.map { max($0, minimumMs) }
        let total = durations.reduce(0, +)
        let t = max(elapsedMs, 0)
        let cycleStart = loop ? t - t % total : 0
        guard loop || t < total - durations[durations.count - 1] else { return nil }
        var boundary = cycleStart
        for duration in durations {
            boundary += duration
            if boundary > t { return boundary }
        }
        return nil
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
    /// A v2 clip or held pose (#138) drawn instead of the state's own frame; `state` stays the mood
    /// for everything that isn't the art.
    public var clip: ClipFrame?
    /// Accessory overlays worn in this pose (drawn above the art, leaning with it).
    public var accessories: [MascotAccessoryID]
    /// A rig clip (#138) blends in from these channels: whatever was showing when it started.
    public var rigBlendFrom: [String: Double]?

    public init(state: MascotState, frame: Int?, clipElapsed: TimeInterval?, angle: Double = 0,
                clip: ClipFrame? = nil, accessories: [MascotAccessoryID] = []) {
        self.state = state
        self.frame = frame
        self.clipElapsed = clipElapsed
        self.angle = angle
        self.clip = clip
        self.accessories = accessories
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
    ///
    /// #138 (all optional; a pack without a clip keeps today's behaviour):
    /// - Drag masks everything while held (its clocks underneath keep running).
    /// - The higher of the scheduler clip and the EventClipQueue clip plays; an actionable repository
    ///   batch plays `new-item` in place of the wave when the pack has it.
    /// - Doze holds when nothing else plays.
    /// - Reduced motion shows static substitutions only: drag or doze's static pose, and accessories.
    public static func pose(mood: MascotState, clip: EventClipQueue.Clip?, now: Date, reducedMotion: Bool,
                            idleEpoch: Date, gesture: AttentionGesture? = nil, stage: ClipStage = .empty,
                            library: ClipLibrary = .empty, accessories: [MascotAccessoryID] = [],
                            durationsMs: (MascotState) -> [Int]) -> MascotPose {
        let worn = accessories.filter(library.accessories.contains)
        // An incident is showing (the marker's accessories are passed in), whether or not the pack draws
        // the hat as an overlay: a pack with an incident idle loop draws the helmet itself (#138).
        let incident = !accessories.isEmpty
        // Chris's incident rule (#138): with a drawn-helmet loop, the pet wears the helmet throughout an
        // incident. The loop replaces idle, attention and urgent; one-shots that would show the pet
        // without it are suppressed; the user's own reactions (drag, drop, poke, dizzy) and the incident
        // clips still play.
        let helmetLoop = incident && library.has(.incidentIdle)
        func allowed(_ id: MascotClipID) -> Bool { !helmetLoop || IncidentRule.playsDuringIncident.contains(id) }
        func wearing(_ pose: MascotPose) -> MascotPose {
            var pose = pose
            if let clip = pose.clip, library.hidesAccessories.contains(clip.id) { return pose }
            pose.accessories = worn
            return pose
        }
        let spring = stage.springAngle(at: now)
        func clipPose(_ requested: MascotClipID, since start: Date, loop: Bool, state: MascotState = mood,
                      angle: Double = 0) -> MascotPose? {
            // During an incident a reaction plays its helmet variant when the pack draws one.
            let variant = IncidentRule.variant(of: requested)
            let id = helmetLoop && library.has(variant) ? variant : requested
            guard let durations = library.durationsMs[id] else { return nil }
            let elapsed = max(0, now.timeIntervalSince(start))
            let frame = FrameClock.frameIndex(durationsMs: durations, loop: loop, elapsedMs: Int(elapsed * 1000),
                                              reducedMotion: false, minimumMs: FrameClock.minimumClipDurationMs)
            // Dizzy wobbles 0, −5°, +5°, −5°, 0 at its frame starts, eased like #29.
            var lean = angle
            if requested == .dizzy { lean = DizzyLean.angle(durationsMs: durations, elapsedMs: elapsed * 1000) }
            let limit = library.leanLimit
            return wearing(MascotPose(state: state, frame: nil, clipElapsed: loop ? nil : elapsed,
                                      angle: min(max(lean + spring, -limit), limit),
                                      clip: ClipFrame(id: id, frame: frame, elapsed: elapsed)))
        }
        if reducedMotion {
            for (id, active) in [(MascotClipID.drag, stage.dragStart != nil), (.doze, stage.dozeStart != nil),
                                 (.incidentIdle, helmetLoop)]
            where active && library.has(id) {
                let variant = IncidentRule.variant(of: id)
                let shown = helmetLoop && library.has(variant) ? variant : id
                return wearing(MascotPose(state: mood, frame: nil, clipElapsed: nil, clip: ClipFrame(id: shown, frame: nil, elapsed: 0)))
            }
            return wearing(MascotPose(state: mood, frame: nil, clipElapsed: nil))
        }
        if let start = stage.dragStart, allowed(.drag), let pose = clipPose(.drag, since: start, loop: true, angle: stage.dragAngle) {
            return pose
        }
        let event = clip.flatMap { now >= $0.startedAt && now < $0.endsAt ? $0 : nil }
        if let scheduled = stage.scheduled, now >= scheduled.startedAt, now < scheduled.endsAt,
           scheduled.priority > event.map(ClipPriority.of) ?? .min, allowed(scheduled.id),
           let pose = clipPose(scheduled.id, since: scheduled.startedAt, loop: false) {
            return pose
        }
        // Tier 1 by kind: incident-start/-end are only chosen when the pack has them; new-item
        // replaces the wave for repository batches only (an incident escalation keeps the wave).
        if let event, let id = event.kind.clipID, event.kind != .newItem || event.origin == .repository, allowed(id),
           let pose = clipPose(id, since: event.startedAt, loop: false, state: .attention) {
            return pose
        }
        if event == nil, mood == .idle, allowed(.doze), let start = stage.dozeStart, let pose = clipPose(.doze, since: start, loop: true) {
            return pose
        }
        // During an incident the helmet loop stands in for every mood and for suppressed gestures (#138).
        if helmetLoop, let pose = clipPose(.incidentIdle, since: idleEpoch, loop: true) {
            return pose
        }
        return wearing(legacyPose(mood: mood, clip: event, now: now, idleEpoch: idleEpoch, gesture: gesture,
                                  durationsMs: durationsMs))
    }

    /// #166: when the mood's own art next changes. Without a clip, drag, spring or doze (which the
    /// view redraws continuously) `pose` is the idle loop or a held static pose, so it changes only
    /// at a frame boundary: the first instant after `date` at which `pose` shows another idle frame,
    /// or nil while it holds (reduced motion, attention and urgent). The view schedules its next
    /// redraw here instead of polling the idle loop at a fixed rate.
    public static func nextIdleFrameChange(after date: Date, mood: MascotState, reducedMotion: Bool, idleEpoch: Date,
                                           minimumMs: Int = FrameClock.minimumDurationMs,
                                           durationsMs: (MascotState) -> [Int]) -> Date? {
        guard mood == .idle else { return nil }
        // The same millisecond `legacyPose` reads, so the boundary lands on its frame change.
        let elapsedMs = Int(max(0, date.timeIntervalSince(idleEpoch)) * 1000)
        guard let next = FrameClock.nextChangeMs(durationsMs: durationsMs(.idle), loop: true, elapsedMs: elapsedMs,
                                                 reducedMotion: reducedMotion, minimumMs: minimumMs) else { return nil }
        // Half a millisecond in, so rounding at the epoch's magnitude can't land on the old frame.
        return idleEpoch.addingTimeInterval((Double(next) + 0.5) / 1000)
    }

    /// Dizzy's wobble (#138): 0, −5°, +5°, −5°, 0 reached at its frame starts with the #29 easing.
    enum DizzyLean {
        static let angles: [Double] = [0, -5, 5, -5, 0]

        static func angle(durationsMs: [Int], elapsedMs: Double) -> Double {
            var start = 0
            let steps = durationsMs.enumerated().map { index, duration -> AttentionGesture.Step in
                defer { start += duration }
                return AttentionGesture.Step(startMs: start, frame: index, angle: angles[min(index, angles.count - 1)])
            }
            guard !steps.isEmpty else { return 0 }
            return AttentionGesture(steps: steps, durationMs: start).angle(atMs: elapsedMs)
        }
    }

    static func legacyPose(mood: MascotState, clip: EventClipQueue.Clip?, now: Date, idleEpoch: Date,
                           gesture: AttentionGesture?, durationsMs: (MascotState) -> [Int]) -> MascotPose {
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
