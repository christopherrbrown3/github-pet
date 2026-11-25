import CoreGraphics
import Foundation

// #138: event clips, held poses (drag, doze), idle variety, interaction reactions and accessory
// overlays on top of the three pack states (design: docs/design/animation-v1.md). Everything here is
// pure policy on the app clock: the app's single tick advances it (#41) and the view samples it.
// Nothing here owns a timer. Every clip is optional: a pack without it behaves as before.

/// A clip or held pose name, as the pack manifest spells it. Clips are data, not an enum, so the
/// design list can change without touching the engine.
public struct MascotClipID: RawRepresentable, Hashable, Comparable, Codable, Sendable, ExpressibleByStringLiteral,
                            CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }

    // Design v1 list (#138).
    public static let drag: Self = "drag"
    public static let doze: Self = "doze"
    public static let incidentStart: Self = "incident-start"
    public static let incidentEnd: Self = "incident-end"
    public static let newItem: Self = "new-item"
    public static let itemCleared: Self = "item-cleared"
    public static let inboxZero: Self = "inbox-zero"
    public static let drop: Self = "drop"
    public static let poke: Self = "poke"
    public static let dizzy: Self = "dizzy"
    public static let idleLook: Self = "idle-look"
    public static let idleStretch: Self = "idle-stretch"
    public static let idleFidget: Self = "idle-fidget"

    /// Held poses live in the manifest's `states` and loop while their condition lasts.
    public static let heldStates: [Self] = [.drag, .doze]
    /// The idle loop while the incident marker shows (frame sequences, #138): the helmet drawn as art
    /// on a looping idle, in place of the idle loop plus the hat overlay.
    public static let incidentIdle: Self = "incident-idle"
    /// Every looping state a v2 pack may add to idle, attention and urgent (drag's helmet variant too).
    public static let loopingStates: [Self] = heldStates + [incidentIdle, "drag-incident"]
}

/// Priority tiers (design #138), highest first: drag masks everything; event clips (tier 1) follow
/// the EventClipQueue severity rules; then inbox reactions, user reactions, idle variety and doze.
public enum ClipTier: Int, Sendable {
    case drag = 0, event, inbox, reaction, idleVariant, doze

    /// Below the event tier: stopped by a drag, never resumed.
    public var isBelowEvents: Bool { rawValue > ClipTier.event.rawValue }
}

/// What starts a scheduler clip (tiers 2–4). Tier-1 clips (urgent, incident-start, incident-end,
/// new-item) play through EventClipQueue with its clip kind, and drag and doze are held poses.
public enum ClipTrigger: String, CaseIterable, Sendable {
    /// The user dismissed a Needs you row.
    case itemDismissed
    /// A fresh poll went from at least one item to verified empty.
    case inboxZero
    case idle
    case dropped
    case poke
    case rapidClicks
}

/// What a clip needs before it may play (Reduce Motion stops all of them).
public enum ClipGate: Sendable {
    /// Event clips and inbox-zero: suppressed by quiet hours and snooze, as today.
    case alerts
    /// The user's own reactions: always.
    case always
}

/// Whether the incident hat stays on during a clip (`hide`: the clip draws its own, e.g. putting it on).
public enum AccessoryVisibility: String, Codable, Sendable { case keep, hide }

/// How the engine treats one clip.
public struct ClipPolicy: Equatable, Sendable {
    public var id: MascotClipID
    public var trigger: ClipTrigger?
    public var tier: ClipTier
    /// Higher wins; preempts lower immediately.
    public var priority: Int
    /// The same clip never starts again within this many seconds.
    public var cooldown: TimeInterval
    public var gate: ClipGate
    /// Longest the clip may play (validated against the pack).
    public var maxDurationMs: Int
    /// Placeholder recipe until the art lands: existing frames of a base state, by index.
    public var placeholder: (state: MascotState, frames: [Int], durationMs: [Int])

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.trigger == rhs.trigger && lhs.tier == rhs.tier && lhs.priority == rhs.priority
            && lhs.cooldown == rhs.cooldown && lhs.maxDurationMs == rhs.maxDurationMs
            && lhs.placeholder.state == rhs.placeholder.state && lhs.placeholder.frames == rhs.placeholder.frames
            && lhs.placeholder.durationMs == rhs.placeholder.durationMs
    }
}

/// Event-clip priorities: the EventClipQueue's urgent one-shot and attention wave sit in tier 1 too.
public enum ClipPriority {
    public static let drag = 1000
    public static let urgent = 450
    public static let incidentStart = 440
    public static let incidentEnd = 430
    /// The attention wave and `new-item`, which replaces it.
    public static let newItem = 420
    public static let inboxZero = 320
    public static let itemCleared = 310
    public static let drop = 230
    // Dizzy sits just above poke: the fifth quick click often lands while a poke still plays.
    public static let dizzy = 221
    public static let poke = 220
    public static let idleVariant = 110
    public static let doze = 50

    /// The EventClipQueue clip's place in the order.
    public static func of(_ clip: EventClipQueue.Clip) -> Int {
        switch clip.kind {
        case .urgent: return urgent
        case .incidentStart: return incidentStart
        case .incidentEnd: return incidentEnd
        case .newItem: return newItem
        }
    }
}

/// What plays while an incident is active, for a pack that draws the helmet (#138, Chris's rule): the
/// user's own reactions and the incident clips. Everything else gives way to the incident idle loop.
public enum IncidentRule {
    public static let playsDuringIncident: Set<MascotClipID> = [.drag, .drop, .poke, .dizzy, .incidentStart, .incidentEnd]
    /// The reactions a pack may also draw wearing the helmet, as `<clip>-incident` (a loop for drag).
    public static let helmetVariants: [MascotClipID] = [.poke, .dizzy, .drop, .drag]

    public static func variant(of id: MascotClipID) -> MascotClipID { MascotClipID(id.rawValue + "-incident") }

    /// The clip a `<clip>-incident` name varies, if it is one.
    public static func base(of id: MascotClipID) -> MascotClipID? {
        helmetVariants.first { variant(of: $0) == id }
    }
}

/// The clips the app knows (design v1, #138). Replacing this table is the only change needed for new
/// IDs, triggers, priorities and cooldowns.
public struct ClipCatalog: Equatable, Sendable {
    public private(set) var clips: [MascotClipID: ClipPolicy]

    public init(_ policies: [ClipPolicy]) {
        clips = Dictionary(policies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public subscript(id: MascotClipID) -> ClipPolicy? { clips[id] }

    public func clips(for trigger: ClipTrigger) -> [ClipPolicy] {
        clips.values.filter { $0.trigger == trigger }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id }
    }

    /// Every clip, highest priority first, then by ID: the render-check order.
    public var ordered: [ClipPolicy] {
        clips.values.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id }
    }

    static func policy(_ id: MascotClipID, _ trigger: ClipTrigger?, _ tier: ClipTier, _ priority: Int,
                       cooldown: TimeInterval = 0, gate: ClipGate, maxMs: Int = ClipLimits.maxClipMs,
                       placeholder: (MascotState, [Int], [Int])) -> ClipPolicy {
        ClipPolicy(id: id, trigger: trigger, tier: tier, priority: priority, cooldown: cooldown, gate: gate,
                   maxDurationMs: maxMs, placeholder: (placeholder.0, placeholder.1, placeholder.2))
    }

    /// Design v1 (#138, docs/design/animation-v1.md). Caps are the longest a pack's clip may play;
    /// placeholders reuse existing frames (design note): idle, attention and urgent.
    public static let v1 = ClipCatalog([
        policy(.incidentStart, nil, .event, ClipPriority.incidentStart, gate: .alerts, maxMs: 2200,
               placeholder: (.urgent, [0, 1, 2, 2, 1, 2], [250, 300, 300, 250, 500, 300])),
        policy(.incidentEnd, nil, .event, ClipPriority.incidentEnd, gate: .alerts, maxMs: 3200,
               placeholder: (.urgent, [2, 1, 0, 1, 0, 0, 0, 0], [250, 250, 300, 300, 300, 300, 700, 300])),
        // Plays in the attention wave's 1.9 s EventClipQueue slot, so it can be no longer.
        policy(.newItem, nil, .event, ClipPriority.newItem, gate: .alerts,
               maxMs: Int(EventClipQueue.duration(of: .attention) * 1000),
               placeholder: (.attention, [0, 1, 2, 1, 0], [200, 200, 350, 350, 800])),
        policy(.inboxZero, .inboxZero, .inbox, ClipPriority.inboxZero, cooldown: 30 * 60, gate: .alerts, maxMs: 2400,
               placeholder: (.attention, [0, 1, 2, 1, 2, 0], [250, 300, 300, 300, 450, 400])),
        policy(.itemCleared, .itemDismissed, .inbox, ClipPriority.itemCleared, cooldown: 8, gate: .always, maxMs: 1500,
               placeholder: (.attention, [0, 1, 2, 0], [200, 300, 400, 300])),
        // 16 frames at 70 ms (#138 frame sequences) for drop and poke.
        policy(.drop, .dropped, .reaction, ClipPriority.drop, gate: .always, maxMs: 1200,
               placeholder: (.attention, [0, 1], [200, 250])),
        policy(.poke, .poke, .reaction, ClipPriority.poke, cooldown: 1.5, gate: .always, maxMs: 1200,
               placeholder: (.attention, [1, 2, 0], [250, 300, 200])),
        policy(.dizzy, .rapidClicks, .reaction, ClipPriority.dizzy, cooldown: 60, gate: .always, maxMs: 1800,
               placeholder: (.urgent, [0, 1, 2, 1, 0], [300, 300, 300, 300, 400])),
        policy(.idleLook, .idle, .idleVariant, ClipPriority.idleVariant, gate: .alerts, maxMs: 2600,
               placeholder: (.idle, [0, 1, 0, 0], [500, 500, 600, 400])),
        policy(.idleStretch, .idle, .idleVariant, ClipPriority.idleVariant, gate: .alerts, maxMs: 2600,
               placeholder: (.attention, [0, 2, 2, 1, 0], [400, 600, 500, 400, 500])),
        policy(.idleFidget, .idle, .idleVariant, ClipPriority.idleVariant, gate: .alerts, maxMs: 2600,
               placeholder: (.idle, [0, 1, 1, 0], [400, 700, 400, 300])),
    ])

    /// Held-pose placeholders: drag 2 × 400 ms, doze 2 × 1200 ms.
    public static let heldPlaceholders: [MascotClipID: (state: MascotState, frames: [Int], durationMs: [Int])] = [
        .drag: (.attention, [0, 1], [400, 400]),
        .doze: (.idle, [1, 0], [1200, 1200]),
    ]
}

/// Longest any one-shot clip may play: long sequences stop being "subtle".
public enum ClipLimits {
    public static let maxClipMs = 6000
}

/// Small deterministic generator for idle timing: seeded per launch, fixed in tests and renders.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Decides which scheduler clip plays. At most one at a time: a higher priority preempts a lower
/// one at once (no resume); a same-or-lower arrival is dropped, never queued, so no backlog plays
/// later. The EventClipQueue's gesture holds the stage at its tier-1 priority (`occupy`). Each clip
/// has its own cooldown, and a dedupe key (e.g. an incident ID) plays at most once per session, so
/// unchanged polls and reconnects never replay it. A request that can't play (motion reduced, alerts
/// off, outranked) still spends its key: nothing replays when the condition lifts.
public struct ClipScheduler: Sendable {
    public struct Config: Equatable, Sendable {
        /// Random gap between idle variants (design: 120–300 s).
        public var idleGap: ClosedRange<TimeInterval>
        /// Dedupe keys remembered (oldest dropped first).
        public var maxKeys: Int

        public init(idleGap: ClosedRange<TimeInterval> = 120...300, maxKeys: Int = 512) {
            self.idleGap = idleGap
            self.maxKeys = maxKeys
        }
    }

    public struct Playing: Equatable, Sendable {
        public var id: MascotClipID
        public var tier: ClipTier
        public var priority: Int
        public var gate: ClipGate
        public var startedAt: Date
        public var endsAt: Date

        public init(id: MascotClipID, tier: ClipTier, priority: Int, gate: ClipGate, startedAt: Date, endsAt: Date) {
            self.id = id
            self.tier = tier
            self.priority = priority
            self.gate = gate
            self.startedAt = startedAt
            self.endsAt = endsAt
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.priority == rhs.priority && lhs.startedAt == rhs.startedAt && lhs.endsAt == rhs.endsAt
        }
    }

    public enum Outcome: Equatable, Sendable {
        case started
        case preempted(MascotClipID)
        /// The pack has no such clip: today's behaviour.
        case unavailable
        case suppressed
        case alreadyPlayed
        case coolingDown
        case outranked
    }

    /// What may play right now.
    public struct Permissions: Equatable, Sendable {
        public var motion: Bool
        public var alerts: Bool
        /// - Parameter motion: Reduce Motion off (system and app) and the mascot shown.
        public init(motion: Bool, alerts: Bool) {
            self.motion = motion
            self.alerts = alerts
        }

        func allow(_ gate: ClipGate) -> Bool { motion && (gate == .always || alerts) }
    }

    public let catalog: ClipCatalog
    public let config: Config
    public private(set) var playing: Playing?
    /// The EventClipQueue gesture (attention wave / new-item / urgent) holding the stage.
    public private(set) var external: (until: Date, priority: Int)?
    /// The mascot is held: drag masks everything below it.
    public private(set) var held = false
    private var lastStarted: [MascotClipID: Date] = [:]
    private var lastIdleVariant: MascotClipID?
    private var playedKeys: Set<String> = []
    private var keyOrder: [String] = []
    public private(set) var nextIdleAt: Date?
    private var rng: SplitMix64

    public init(catalog: ClipCatalog = .v1, config: Config = Config(), seed: UInt64) {
        self.catalog = catalog
        self.config = config
        rng = SplitMix64(seed: seed)
    }

    /// The clip on stage at `now`, if it hasn't ended.
    public func active(at now: Date) -> Playing? {
        guard let playing, now >= playing.startedAt, now < playing.endsAt else { return nil }
        return playing
    }

    /// The next ambient clip is due a fresh 120–300 s after any clip or pointer interaction.
    public mutating func noteActivity(now: Date) {
        nextIdleAt = now.addingTimeInterval(idleGap())
    }

    /// Asks to play the clip `trigger` maps to. `key` dedupes per session; `duration` gives the
    /// clip's length in the pack, or nil when the pack doesn't have it.
    @discardableResult
    public mutating func request(_ trigger: ClipTrigger, key: String? = nil, now: Date, permissions: Permissions,
                                 duration: (MascotClipID) -> TimeInterval?) -> Outcome {
        guard let policy = catalog.clips(for: trigger).first(where: { duration($0.id) != nil }),
              let length = duration(policy.id) else { return .unavailable }
        if let key {
            guard !playedKeys.contains(key) else { return .alreadyPlayed }
            remember(key)
        }
        return start(policy, length: length, now: now, permissions: permissions)
    }

    /// Advances time: expires the clip, stops clips the permissions no longer allow, and starts an
    /// idle variant when one is due.
    /// - Parameter idleAllowed: mood idle, no other clip, not hovered, not held and not dozing.
    @discardableResult
    public mutating func tick(now: Date, permissions: Permissions, idleAllowed: Bool,
                              duration: (MascotClipID) -> TimeInterval?) -> Playing? {
        if let current = playing, now >= current.endsAt || !permissions.allow(current.gate) { playing = nil }
        if let hold = external, now >= hold.until { external = nil }
        guard let due = nextIdleAt else {
            nextIdleAt = now.addingTimeInterval(idleGap())
            return active(at: now)
        }
        guard now >= due else { return active(at: now) }
        // Due: play one if the stage is free, otherwise wait a full new gap (no backlog).
        if idleAllowed, playing == nil, external == nil, !held {
            let available = catalog.clips(for: .idle).filter { duration($0.id) != nil }
            // Never the same variant twice in a row (unless it is the only one).
            let candidates = available.count > 1 ? available.filter { $0.id != lastIdleVariant } : available
            if !candidates.isEmpty {
                let pick = candidates[Int(rng.next() % UInt64(candidates.count))]
                if let length = duration(pick.id), start(pick, length: length, now: now, permissions: permissions) == .started {
                    lastIdleVariant = pick.id
                }
            }
        }
        nextIdleAt = now.addingTimeInterval(idleGap())
        return active(at: now)
    }

    /// The EventClipQueue's gesture is playing until `until`: a lower clip stops (no resume) and lower
    /// arrivals are dropped until it ends.
    public mutating func occupy(until: Date, priority: Int, now: Date) {
        if let current = active(at: now), current.priority < priority { playing = nil }
        if let hold = external, hold.until > now, hold.priority > priority { return }
        if external?.until != until { noteActivity(now: now) }
        external = (until, priority)
    }

    /// The EventClipQueue clip may start only if no higher-or-equal scheduler clip is playing (tier 1
    /// merges per #29: a same-or-lower arrival never restarts the stage).
    public func admitsEvent(priority: Int, now: Date) -> Bool {
        guard let current = active(at: now) else { return true }
        return priority > current.priority
    }

    /// Drag started: everything below tier 1 stops at once (no resume); tier-1 clips keep their clocks
    /// running underneath and show again on release if they haven't ended.
    public mutating func beginHold(now: Date) {
        held = true
        if let current = active(at: now), current.tier.isBelowEvents { playing = nil }
    }

    public mutating func endHold() { held = false }

    /// Reduce Motion switched on: stop now; nothing is re-queued.
    public mutating func cancel() {
        playing = nil
        external = nil
    }

    /// Quiet hours or snooze switched on: alert-gated clips stop; the user's own reactions finish.
    public mutating func cancelAlertClips() {
        if playing?.gate == .alerts { playing = nil }
        external = nil
    }

    /// A new source or account: dedupe keys and cooldowns belong to the old session.
    public mutating func reset() {
        cancel()
        lastStarted.removeAll()
        playedKeys.removeAll()
        keyOrder.removeAll()
    }

    public func hasPlayed(key: String) -> Bool { playedKeys.contains(key) }

    /// Dev replay (#138 `--replay-clips`): plays `id` as its trigger would, through the same gates and
    /// priorities, but ignoring its cooldown so a reviewer can watch every clip on a short cycle.
    @discardableResult
    public mutating func replay(_ id: MascotClipID, now: Date, permissions: Permissions, length: TimeInterval) -> Outcome {
        guard let policy = catalog[id] else { return .unavailable }
        lastStarted[id] = nil
        return start(policy, length: length, now: now, permissions: permissions)
    }

    private func coolingDown(_ policy: ClipPolicy, now: Date) -> Bool {
        guard let last = lastStarted[policy.id] else { return false }
        return now.timeIntervalSince(last) < policy.cooldown
    }

    private mutating func start(_ policy: ClipPolicy, length: TimeInterval, now: Date, permissions: Permissions) -> Outcome {
        guard permissions.allow(policy.gate) else { return .suppressed }
        if coolingDown(policy, now: now) { return .coolingDown }
        if held && policy.tier.isBelowEvents { return .outranked }
        if let hold = external, now < hold.until, hold.priority >= policy.priority { return .outranked }
        let current = active(at: now)
        if let current, current.priority >= policy.priority { return .outranked }
        if let hold = external, hold.priority < policy.priority { external = nil }
        let capped = min(length, Double(policy.maxDurationMs) / 1000)
        playing = Playing(id: policy.id, tier: policy.tier, priority: policy.priority, gate: policy.gate,
                          startedAt: now, endsAt: now.addingTimeInterval(max(capped, 0.1)))
        lastStarted[policy.id] = now
        if policy.tier != .idleVariant { noteActivity(now: now) }
        return current.map { .preempted($0.id) } ?? .started
    }

    private mutating func remember(_ key: String) {
        playedKeys.insert(key)
        keyOrder.append(key)
        if keyOrder.count > config.maxKeys { playedKeys.remove(keyOrder.removeFirst()) }
    }

    private mutating func idleGap() -> TimeInterval {
        let span = config.idleGap.upperBound - config.idleGap.lowerBound
        let unit = Double(rng.next() >> 11) / Double(UInt64(1) << 53)
        return config.idleGap.lowerBound + span * unit
    }
}

/// Doze (#138): after 15 minutes without events or pointer interaction, while the mood is idle and the
/// data is fresh, the mascot holds its doze pose; any event, hover or click wakes it (no wake clip).
/// A held pose, so motion reduced shows its static fallback.
///
/// Never while the incident marker shows or the data isn't fresh (`ready`, `empty`, `hiddenOnly`): a
/// sleeping mascot must not stand in for "nothing is happening" when the app doesn't know. During
/// quiet hours or snooze it enters as soon as the other conditions hold.
public enum DozePolicy {
    public static let after: TimeInterval = 15 * 60

    public static func isDozing(now: Date, lastActivity: Date, mood: MascotState, dataState: DataState,
                                incidentShown: Bool = false, alertsAllowed: Bool = true) -> Bool {
        guard mood == .idle, dataState.countIsKnown, !incidentShown else { return false }
        return !alertsAllowed || now.timeIntervalSince(lastActivity) >= after
    }
}

/// Click reactions (#138): a click pokes; five clicks within 3 s make the mascot dizzy (its 60 s
/// cooldown rate-limits the easter egg). Pure: the caller passes times.
public struct ClickReactions: Sendable {
    public var window: TimeInterval
    public var threshold: Int
    private var recent: [Date] = []

    public init(window: TimeInterval = 3, threshold: Int = 5) {
        self.window = window
        self.threshold = threshold
    }

    /// The trigger a click at `now` raises.
    public mutating func click(at now: Date) -> ClipTrigger {
        recent = recent.filter { now.timeIntervalSince($0) < window && now >= $0 } + [now]
        guard recent.count >= threshold else { return .poke }
        recent.removeAll()
        return .rapidClicks
    }
}

/// Drag lean (#138): while held, the art leans toward the drag direction in proportion to the
/// smoothed horizontal speed, at most the #29 lean (±5° about [128, 232]) so the label lane already
/// has room. Fed from drag events only, never a timer; always upright with motion reduced.
public struct DragLean: Sendable {
    public static let maxDegrees = MascotPack.attentionLeanDegrees
    /// Horizontal speed (points per second) that reaches the full lean.
    public static let fullLeanSpeed: Double = 900
    /// Smallest change the view is told about, so a slow drag doesn't redraw for nothing.
    public static let step: Double = 0.5
    /// Seconds the lean takes to spring back upright after a drop.
    public static let springBack: TimeInterval = 0.2

    public private(set) var angle: Double = 0
    private var velocity: Double = 0
    private var last: (time: TimeInterval, x: Double)?

    public init() {}

    /// Feeds a pointer sample; returns true when the drawn angle changed.
    public mutating func sample(x: Double, time: TimeInterval, reducedMotion: Bool) -> Bool {
        guard !reducedMotion else { return reset() }
        defer { last = (time, x) }
        guard let last, time > last.time else { return false }
        let instant = (x - last.x) / max(time - last.time, 1.0 / 240)
        velocity = velocity * 0.7 + instant * 0.3
        let target = (max(-1, min(1, velocity / Self.fullLeanSpeed)) * Self.maxDegrees / Self.step).rounded() * Self.step
        guard target != angle else { return false }
        angle = target
        return true
    }

    /// Released or cancelled: upright again. Returns true if the angle changed.
    @discardableResult
    public mutating func reset() -> Bool {
        let changed = angle != 0
        angle = 0
        velocity = 0
        last = nil
        return changed
    }
}

/// An accessory overlay's name, as the manifest spells it.
public typealias MascotAccessoryID = MascotClipID

/// Accessory overlays (#138): drawn above the art, below labels, while their condition lasts. Only a
/// real, fresh, confirmed incident (`IncidentMarker.current`) puts the hat on, so stale or failed
/// status never shows gear: the hat leaves with the marker. A still layer, so it also shows with
/// motion reduced.
public enum AccessoryPolicy {
    public static let firefighterHat: MascotAccessoryID = "firefighter-hat"
    public static let all: [MascotAccessoryID] = [firefighterHat]

    public static func accessories(marker: IncidentMarker?) -> [MascotAccessoryID] {
        marker == nil ? [] : [firefighterHat]
    }
}

/// One sampled clip or held-pose frame for the renderer.
public struct ClipFrame: Equatable, Sendable {
    public var id: MascotClipID
    /// nil: the clip's static fallback.
    public var frame: Int?
    public var elapsed: TimeInterval

    public init(id: MascotClipID, frame: Int?, elapsed: TimeInterval) {
        self.id = id
        self.frame = frame
        self.elapsed = elapsed
    }
}

/// What the stage holds beyond the mood and the EventClipQueue clip.
public struct ClipStage: Equatable, Sendable {
    public var scheduled: ClipScheduler.Playing?
    /// When the current drag began (nil: not held).
    public var dragStart: Date?
    public var dragAngle: Double
    /// The lean springs back to 0° over `DragLean.springBack` after release.
    public var released: (at: Date, angle: Double)?
    /// When the doze began (nil: awake).
    public var dozeStart: Date?

    public init(scheduled: ClipScheduler.Playing? = nil, dragStart: Date? = nil, dragAngle: Double = 0,
                released: (at: Date, angle: Double)? = nil, dozeStart: Date? = nil) {
        self.scheduled = scheduled
        self.dragStart = dragStart
        self.dragAngle = dragAngle
        self.released = released
        self.dozeStart = dozeStart
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scheduled == rhs.scheduled && lhs.dragStart == rhs.dragStart && lhs.dragAngle == rhs.dragAngle
            && lhs.released?.at == rhs.released?.at && lhs.released?.angle == rhs.released?.angle
            && lhs.dozeStart == rhs.dozeStart
    }

    /// The release spring's lean at `now` (0 once it has settled).
    public func springAngle(at now: Date) -> Double {
        guard let released, released.angle != 0 else { return 0 }
        let progress = now.timeIntervalSince(released.at) / DragLean.springBack
        guard progress >= 0, progress < 1 else { return 0 }
        return released.angle * (1 - AttentionGesture.ease(progress))
    }

    public static let empty = ClipStage()
}

/// Engine-owned effect sprites (mist, smoke, sparkle, Z): pure functions of a clip's elapsed time
/// on the single clock, in canvas coordinates, from the design storyboards (#138 section 3). Never
/// above canvas y 64 (the label lane) and never part of contours. Drawn code-side until the shared
/// 64×64 sprites land (assets/mascots/shared-fx-v1).
public enum ClipEffects {
    public enum Kind: String, Sendable { case mist, smoke, sparkle, z }

    public struct Particle: Equatable, Sendable {
        public var kind: Kind
        public var x: Double
        public var y: Double
        /// Sprite side in canvas units (at most 64).
        public var size: Double
        public var opacity: Double
    }

    /// No effect reaches above this canvas row (the label lane).
    public static let topLimit: Double = 64

    /// Where the sparkle starts when a frame names no `hand`: the head plus [60, 50].
    public static func hand(head: CGPoint) -> CGPoint { CGPoint(x: head.x + 60, y: head.y + 50) }

    /// - Parameters:
    ///   - nozzle: incident-end's spray emitter for the current frame (no point: no mist).
    ///   - hand: item-cleared's sparkle point.
    ///   - sprayWindow: when the clip sprays (seconds), from its nozzle frames (#138 sequences); the v1
    ///     timing (0.5–1.45 s) when nil.
    public static func particles(clip: MascotClipID, elapsed t: TimeInterval, head: CGPoint, nozzle: CGPoint?,
                                 hand: CGPoint, sprayWindow: ClosedRange<Double>? = nil) -> [Particle] {
        var out: [Particle] = []
        /// 0 → 1 → 0 over [start, start + length).
        func pulse(_ start: Double, _ length: Double) -> Double? {
            let p = (t - start) / length
            return p >= 0 && p < 1 ? sin(p * .pi) : nil
        }
        switch clip {
        case .incidentEnd:
            // A puff every 60 ms through the spray (v1: 500 to 1450 ms), each drifting 40–80 down-left
            // over 500 ms.
            if let nozzle {
                let window = sprayWindow ?? 0.5...1.45
                let span = max(window.upperBound - window.lowerBound, 0.06)
                for emit in stride(from: window.lowerBound, through: window.upperBound, by: 0.06) {
                    let p = (t - emit) / 0.5
                    guard p >= 0, p < 1 else { continue }
                    let distance = 40 + 40 * (emit - window.lowerBound) / span
                    out.append(Particle(kind: .mist, x: nozzle.x - distance * 0.8 * p, y: nozzle.y + distance * 0.6 * p,
                                        size: 34 * (0.6 + 0.8 * p), opacity: 1 - p))
                }
            }
        case .itemCleared:
            // One sparkle from 200 ms, scaling 0 → 1 → 0 over 400 ms; centre never above y 76.
            if let scale = pulse(0.2, 0.4) {
                out.append(Particle(kind: .sparkle, x: hand.x, y: max(hand.y, 76), size: 24 * scale, opacity: 1))
            }
        case .inboxZero:
            // Three sparkles at 1150 ms beside the upper body, 350 ms each.
            if let scale = pulse(1.15, 0.35) {
                for (x, y) in [(48.0, 96.0), (208.0, 110.0), (54.0, 150.0)] {
                    out.append(Particle(kind: .sparkle, x: x, y: y, size: 24 * scale, opacity: 1))
                }
            }
        case .doze:
            // A Z every 1600 ms beside the head on the left, drifting 40 up-left over 2400 ms.
            let first = max(0, Int(((t - 2.4) / 1.6).rounded(.down)) + 1), last = Int((t / 1.6).rounded(.down))
            for index in first...max(first, last) {
                let p = (t - Double(index) * 1.6) / 2.4
                guard p >= 0, p < 1 else { continue }
                out.append(Particle(kind: .z, x: 50 - 28 * p, y: 140 - 28 * p, size: 26 * (0.7 + 0.4 * p),
                                    opacity: sin(p * .pi)))
            }
        default:
            break
        }
        return out.filter { $0.opacity > 0 && $0.size > 0 && $0.y - $0.size / 2 >= topLimit }
    }
}
