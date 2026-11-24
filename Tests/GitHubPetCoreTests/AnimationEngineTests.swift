import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GitHubPetCore

// #138: the animation engine's scheduler, reactions, animator and pack schema v2.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let allowed = ClipScheduler.Permissions(motion: true, alerts: true)
private let quiet = ClipScheduler.Permissions(motion: true, alerts: false)
private let reduced = ClipScheduler.Permissions(motion: false, alerts: true)

/// Every design-v1 clip, at its placeholder length.
private func everyClip(_ id: MascotClipID) -> TimeInterval? {
    ClipCatalog.v1[id].map { Double($0.placeholder.durationMs.reduce(0, +)) / 1000 }
}

private func scheduler(idleGap: ClosedRange<TimeInterval> = 120...300, seed: UInt64 = 7) -> ClipScheduler {
    ClipScheduler(config: .init(idleGap: idleGap), seed: seed)
}

@Suite struct ClipSchedulerTests {
    @Test func higherPriorityPreemptsAtOnceAndLowerOrEqualIsDroppedNotQueued() {
        var s = scheduler()
        #expect(s.request(.poke, now: t0, permissions: allowed, duration: everyClip) == .started)
        // Inbox reactions beat user reactions; the poke stops and never resumes.
        #expect(s.request(.inboxZero, now: t0 + 0.1, permissions: allowed, duration: everyClip) == .preempted(.poke))
        #expect(s.request(.itemDismissed, now: t0 + 0.2, permissions: allowed, duration: everyClip) == .outranked)
        #expect(s.request(.dropped, now: t0 + 0.3, permissions: allowed, duration: everyClip) == .outranked)
        // A tier-1 event gesture (here an incident start) stops it at once.
        s.occupy(until: t0 + 2.3, priority: ClipPriority.incidentStart, now: t0 + 0.4)
        #expect(s.active(at: t0 + 0.4) == nil)
        // Nothing dropped earlier plays once the stage is free: no backlog.
        s.tick(now: t0 + 2.3, permissions: allowed, idleAllowed: false, duration: everyClip)
        #expect(s.playing == nil)
    }

    @Test func tierOrderMatchesTheDesign() {
        let order = [ClipPriority.urgent, ClipPriority.incidentStart, ClipPriority.incidentEnd, ClipPriority.newItem,
                     ClipPriority.inboxZero, ClipPriority.itemCleared, ClipPriority.drop, ClipPriority.dizzy,
                     ClipPriority.poke, ClipPriority.idleVariant, ClipPriority.doze]
        #expect(order == order.sorted(by: >))
        #expect(ClipPriority.drag > ClipPriority.urgent)
        for policy in ClipCatalog.v1.ordered where policy.tier == .event {
            #expect(policy.trigger == nil, "tier 1 plays through EventClipQueue, never the scheduler")
        }
        let caps = Dictionary(uniqueKeysWithValues: ClipCatalog.v1.ordered.map { ($0.id, $0.maxDurationMs) })
        #expect(caps == [.incidentStart: 2200, .incidentEnd: 3200, .newItem: 1900, .itemCleared: 1500, .inboxZero: 2400,
                         .drop: 600, .poke: 900, .dizzy: 1800, .idleLook: 2600, .idleStretch: 2600, .idleFidget: 2600])
        for policy in ClipCatalog.v1.ordered {
            #expect(policy.placeholder.durationMs.reduce(0, +) <= policy.maxDurationMs, "\(policy.id) placeholder fits its cap")
        }
    }

    @Test func eventGestureOccupiesTheStageAndOnlyAHigherEventGetsIn() {
        var s = scheduler()
        s.request(.poke, now: t0, permissions: allowed, duration: everyClip)
        s.occupy(until: t0 + 1.9, priority: ClipPriority.newItem, now: t0 + 0.1)
        #expect(s.active(at: t0 + 0.1) == nil, "the poke stops for the event and doesn't resume")
        #expect(s.request(.inboxZero, now: t0 + 0.5, permissions: allowed, duration: everyClip) == .outranked)
        #expect(s.request(.rapidClicks, now: t0 + 0.6, permissions: allowed, duration: everyClip) == .outranked)
        s.tick(now: t0 + 1.9, permissions: allowed, idleAllowed: false, duration: everyClip)
        #expect(s.request(.inboxZero, now: t0 + 2, permissions: allowed, duration: everyClip) == .started)
        #expect(s.admitsEvent(priority: ClipPriority.newItem, now: t0 + 2.1), "events always outrank tiers 2–4")
    }

    @Test func cooldownsFollowTheDesign() {
        var s = scheduler()
        #expect(s.request(.poke, now: t0, permissions: allowed, duration: everyClip) == .started)
        #expect(s.request(.poke, now: t0 + 1.4, permissions: allowed, duration: everyClip) == .coolingDown)
        #expect(s.request(.poke, now: t0 + 1.6, permissions: allowed, duration: everyClip) == .started)
        #expect(s.request(.rapidClicks, now: t0 + 10, permissions: allowed, duration: everyClip) == .started)
        #expect(s.request(.rapidClicks, now: t0 + 69, permissions: allowed, duration: everyClip) == .coolingDown)
        #expect(s.request(.rapidClicks, now: t0 + 71, permissions: allowed, duration: everyClip) == .started)
        #expect(s.request(.itemDismissed, now: t0 + 100, permissions: allowed, duration: everyClip) == .started)
        #expect(s.request(.itemDismissed, now: t0 + 107, permissions: allowed, duration: everyClip) == .coolingDown)
        #expect(s.request(.itemDismissed, now: t0 + 109, permissions: allowed, duration: everyClip) == .started)
        #expect(s.request(.inboxZero, now: t0 + 200, permissions: allowed, duration: everyClip) == .started)
        #expect(s.request(.inboxZero, now: t0 + 200 + 29 * 60, permissions: allowed, duration: everyClip) == .coolingDown)
        #expect(s.request(.inboxZero, now: t0 + 200 + 31 * 60, permissions: allowed, duration: everyClip) == .started)
    }

    @Test func aKeyedClipNeverReplaysEvenAfterBeingSuppressed() {
        var s = scheduler()
        #expect(s.request(.inboxZero, key: "zero:1", now: t0, permissions: allowed, duration: everyClip) == .started)
        for poll in 1...5 {
            #expect(s.request(.inboxZero, key: "zero:1", now: t0 + Double(poll) * 3600, permissions: allowed,
                              duration: everyClip) == .alreadyPlayed)
        }
        #expect(s.request(.inboxZero, key: "zero:2", now: t0 + 9000, permissions: reduced, duration: everyClip) == .suppressed)
        #expect(s.request(.inboxZero, key: "zero:2", now: t0 + 9001, permissions: allowed, duration: everyClip) == .alreadyPlayed)
    }

    @Test func gatingFollowsAlertsForInboxZeroAndAlwaysAllowsUserReactions() {
        var s = scheduler()
        #expect(s.request(.inboxZero, now: t0, permissions: quiet, duration: everyClip) == .suppressed)
        #expect(s.request(.itemDismissed, now: t0, permissions: quiet, duration: everyClip) == .started)
        #expect(s.request(.dropped, now: t0 + 5, permissions: quiet, duration: everyClip) == .started)
        // Reduce Motion (or a hidden mascot): nothing at all.
        var r = scheduler()
        for trigger in ClipTrigger.allCases {
            #expect(r.request(trigger, now: t0, permissions: reduced, duration: everyClip) == .suppressed)
        }
        // Quiet hours starting mid-clip stop alert-gated clips only.
        var q = scheduler()
        q.request(.inboxZero, now: t0, permissions: allowed, duration: everyClip)
        q.tick(now: t0 + 0.1, permissions: quiet, idleAllowed: false, duration: everyClip)
        #expect(q.playing == nil)
        q.request(.poke, now: t0 + 1, permissions: quiet, duration: everyClip)
        q.tick(now: t0 + 1.1, permissions: quiet, idleAllowed: false, duration: everyClip)
        #expect(q.playing?.id == .poke)
        q.tick(now: t0 + 1.2, permissions: reduced, idleAllowed: false, duration: everyClip)
        #expect(q.playing == nil, "Reduce Motion stops a playing reaction at once")
    }

    @Test func dragDiscardsTiersTwoToFourAndDropsTheirArrivals() {
        var p = scheduler()
        p.request(.inboxZero, now: t0, permissions: allowed, duration: everyClip)
        p.beginHold(now: t0 + 0.1)
        #expect(p.playing == nil, "a tier-2 clip stops when picked up and does not resume")
        #expect(p.request(.itemDismissed, now: t0 + 0.2, permissions: allowed, duration: everyClip) == .outranked)
        p.endHold()
        #expect(p.active(at: t0 + 0.3) == nil)
        #expect(p.request(.dropped, now: t0 + 0.4, permissions: allowed, duration: everyClip) == .started)
    }

    @Test func tierThreeOrderIsDropThenDizzyThenPoke() {
        var s = scheduler()
        s.request(.poke, now: t0, permissions: allowed, duration: everyClip)
        #expect(s.request(.rapidClicks, now: t0 + 0.1, permissions: allowed, duration: everyClip) == .preempted(.poke))
        #expect(s.request(.dropped, now: t0 + 0.2, permissions: allowed, duration: everyClip) == .preempted(.dizzy))
        #expect(s.request(.poke, now: t0 + 2, permissions: allowed, duration: everyClip) == .started)
    }

    @Test func anEqualPriorityArrivalNeverRestartsTheClip() {
        var s = scheduler()
        #expect(s.request(.dropped, now: t0, permissions: allowed, duration: everyClip) == .started)
        // drop has no cooldown: a second quick drop is dropped by priority, not restarted.
        #expect(s.request(.dropped, now: t0 + 0.1, permissions: allowed, duration: everyClip) == .outranked)
        #expect(s.active(at: t0 + 0.2)?.startedAt == t0)
        // The same for two different clips at one priority (ambient variants).
        var a = scheduler(idleGap: 1...1)
        a.tick(now: t0, permissions: allowed, idleAllowed: true, duration: everyClip)
        let first = a.tick(now: t0 + 1, permissions: allowed, idleAllowed: true, duration: everyClip)
        #expect(first?.tier == .idleVariant)
        a.tick(now: t0 + 1.5, permissions: allowed, idleAllowed: true, duration: everyClip)
        #expect(a.playing?.startedAt == first?.startedAt && a.playing?.id == first?.id)
    }

    @Test func missingClipKeepsTodaysBehaviour() {
        var s = scheduler()
        #expect(s.request(.poke, now: t0, permissions: allowed, duration: { _ in nil }) == .unavailable)
        s.tick(now: t0, permissions: allowed, idleAllowed: true, duration: { _ in nil })
        s.tick(now: t0 + 3600, permissions: allowed, idleAllowed: true, duration: { _ in nil })
        #expect(s.playing == nil)
    }

    @Test func ambientClipsAreRareRandomAndNeverTwiceInARow() {
        var s = scheduler(seed: 42)
        var now = t0
        s.tick(now: now, permissions: allowed, idleAllowed: true, duration: everyClip)
        var plays: [(MascotClipID, Date)] = []
        var last: Date?
        for _ in 0..<(4 * 3600) {
            now += 1
            if let gap = s.nextIdleAt.map({ $0.timeIntervalSince(now) }) { #expect(gap <= 300) }
            if let playing = s.tick(now: now, permissions: allowed, idleAllowed: true, duration: everyClip),
               playing.startedAt == now {
                plays.append((playing.id, now))
                if let last { #expect(now.timeIntervalSince(last) >= 120) }
                last = now
            }
        }
        #expect(plays.count >= 40 && plays.count <= 125, "about one every 2–5 minutes over four hours")
        for (a, b) in zip(plays, plays.dropFirst()) { #expect(a.0 != b.0) }
        #expect(Set(plays.map(\.0)) == [.idleLook, .idleStretch, .idleFidget])
        // Seeded: the same seed gives the same sequence (QA can reproduce it).
        var again = scheduler(seed: 42), replay: [MascotClipID] = []
        now = t0
        again.tick(now: now, permissions: allowed, idleAllowed: true, duration: everyClip)
        for _ in 0..<(4 * 3600) {
            now += 1
            if let playing = again.tick(now: now, permissions: allowed, idleAllowed: true, duration: everyClip),
               playing.startedAt == now { replay.append(playing.id) }
        }
        #expect(replay == plays.map(\.0))
    }

    @Test func ambientWaitsForIdleQuietAFreeStageAndAFullGapAfterActivity() {
        for permissions in [quiet, reduced] {
            var s = scheduler(idleGap: 10...10)
            for step in 0...200 {
                s.tick(now: t0 + Double(step), permissions: permissions, idleAllowed: true, duration: everyClip)
                #expect(s.playing == nil)
            }
        }
        var s = scheduler(idleGap: 10...10)
        for step in 0...100 { s.tick(now: t0 + Double(step), permissions: allowed, idleAllowed: false, duration: everyClip) }
        #expect(s.playing == nil)
        // Allowed again: the next one waits for a fresh gap rather than firing a missed backlog.
        s.tick(now: t0 + 101, permissions: allowed, idleAllowed: true, duration: everyClip)
        #expect(s.playing == nil)
        // Pointer activity and any clip push the next ambient clip a full gap away.
        var p = scheduler(idleGap: 10...10)
        p.tick(now: t0, permissions: allowed, idleAllowed: true, duration: everyClip)
        p.noteActivity(now: t0 + 9)
        p.tick(now: t0 + 10, permissions: allowed, idleAllowed: true, duration: everyClip)
        #expect(p.playing == nil)
        p.tick(now: t0 + 19, permissions: allowed, idleAllowed: true, duration: everyClip)
        #expect(p.playing?.tier == .idleVariant)
        var e = scheduler(idleGap: 10...10)
        e.tick(now: t0, permissions: allowed, idleAllowed: true, duration: everyClip)
        e.occupy(until: t0 + 20, priority: ClipPriority.newItem, now: t0 + 9)
        e.tick(now: t0 + 10, permissions: allowed, idleAllowed: true, duration: everyClip)
        #expect(e.playing == nil, "never over an event gesture")
    }

    @Test func dedupeKeysAreBoundedAndResetWithTheSession() {
        var s = ClipScheduler(config: .init(maxKeys: 3), seed: 1)
        for index in 0..<5 { s.request(.inboxZero, key: "k\(index)", now: t0, permissions: reduced, duration: everyClip) }
        #expect(!s.hasPlayed(key: "k0") && s.hasPlayed(key: "k4"))
        s.reset()
        #expect(!s.hasPlayed(key: "k4"))
    }
}

@Suite struct EventClipKindTests {
    private func event(_ id: String, _ severity: EventSeverity) -> InboxEvent {
        InboxEvent(item: InboxItem.fixture(kind: .reviewRequest, id: id), severity: severity)
    }

    @Test func clipsOrderBySeverityThenKindThenEarlierStart() {
        // A major incident start (critical severity) outranks a new actionable item.
        var q = EventClipQueue()
        q.enqueue([event("a", .actionable)], now: t0, playable: true)
        q.enqueue([event("i", .critical)], now: t0 + 0.1, playable: true, origin: .serviceIncident, kind: .incidentStart)
        #expect(q.active?.kind == .incidentStart)
        // A critical inbox event and an incident start collide: urgent wins by kind rank.
        var c = EventClipQueue()
        c.enqueue([event("i", .critical)], now: t0, playable: true, origin: .serviceIncident, kind: .incidentStart)
        c.enqueue([event("c", .critical)], now: t0 + 0.1, playable: true)
        #expect(c.active?.kind == .urgent && c.active?.state == .urgent)
        // Equal severity and kind: the earlier start, whichever source it came from.
        var e = EventClipQueue()
        e.enqueue([event("i", .actionable)], now: t0, playable: true, origin: .serviceIncident)
        e.enqueue([event("a", .actionable)], now: t0 + 0.1, playable: true)
        #expect(e.active?.origin == .serviceIncident)
        // incident-end outranks new-item at equal severity.
        var n = EventClipQueue()
        n.enqueue([event("a", .actionable)], now: t0, playable: true)
        n.enqueue([event("i", .actionable)], now: t0 + 0.1, playable: true, origin: .serviceIncident, kind: .incidentEnd)
        #expect(n.active?.kind == .incidentEnd)
    }

    @Test func kindsUseThePacksClipLengthAndDefaultToToday() {
        var q = EventClipQueue()
        q.enqueue([event("i", .critical)], now: t0, playable: true, origin: .serviceIncident, kind: .incidentStart,
                  duration: { $0 == .incidentStart ? 2.2 : nil })
        #expect(q.active?.endsAt == t0 + 2.2)
        var d = EventClipQueue()
        d.enqueue([event("c", .critical)], now: t0, playable: true)
        #expect(d.active?.kind == .urgent && d.active?.endsAt == t0 + 2.0)
        d.enqueue([event("i", .critical)], now: t0 + 0.1, playable: true, origin: .serviceIncident)
        #expect(d.active?.event.item.id.hasSuffix("c") == true)
        // An incident is never urgent: without a kind it plays the wave, whatever its severity.
        var i = EventClipQueue()
        i.enqueue([event("i", .critical)], now: t0, playable: true, origin: .serviceIncident)
        #expect(i.active?.kind == .newItem && i.active?.state == .attention && i.active?.endsAt == t0 + 1.9)
    }

    @Test func aSameOrLowerArrivalMergesWithoutRestarting() {
        var q = EventClipQueue()
        q.enqueue([event("i", .actionable)], now: t0, playable: true, origin: .serviceIncident, kind: .incidentEnd)
        q.enqueue([event("j", .actionable)], now: t0 + 0.5, playable: true, origin: .serviceIncident)
        #expect(q.active?.kind == .incidentEnd && q.active?.startedAt == t0)
        q.enqueue([event("k", .actionable)], now: t0 + 0.6, playable: true, origin: .serviceIncident, kind: .incidentStart)
        #expect(q.active?.kind == .incidentStart && q.active?.startedAt == t0 + 0.6, "a higher kind replaces it")
    }
}

@Suite struct ReactionTests {
    @Test func fiveClicksWithinThreeSecondsMakeDizzyOtherwisePoke() {
        var clicks = ClickReactions()
        let quick = (0..<5).map { clicks.click(at: t0 + Double($0) * 0.5) }
        #expect(quick == [.poke, .poke, .poke, .poke, .rapidClicks])
        #expect(clicks.click(at: t0 + 2.6) == .poke, "the count restarts after the easter egg")
        var slow = ClickReactions()
        #expect((0..<10).map { slow.click(at: t0 + Double($0) * 0.8) }.allSatisfy { $0 == .poke })
    }

    @Test func rapidClickingIsRateLimitedByTheScheduler() {
        var s = scheduler(), clicks = ClickReactions()
        var started: [MascotClipID] = []
        for index in 0..<200 {
            let now = t0 + Double(index) * 0.2
            let trigger = clicks.click(at: now)
            if s.request(trigger, now: now, permissions: allowed, duration: everyClip) == .started
                || s.playing?.startedAt == now { started.append(s.playing!.id) }
        }
        // 40 s of clicking five times a second: one dizzy (60 s cooldown); pokes at most every 1.5 s.
        #expect(started.filter { $0 == .dizzy }.count == 1)
        #expect(started.filter { $0 == .poke }.count <= Int(40 / 1.5) + 1)
    }

    @Test func dragLeanFollowsSpeedWithinTheAttentionLean() {
        var lean = DragLean()
        let first = lean.sample(x: 0, time: 0, reducedMotion: false)
        #expect(!first)
        var x = 0.0
        for step in 1...30 { x += 40; _ = lean.sample(x: x, time: Double(step) / 60, reducedMotion: false) }
        #expect(lean.angle == DragLean.maxDegrees, "a fast drag right leans the full 5° right")
        for step in 31...90 { x -= 40; _ = lean.sample(x: x, time: Double(step) / 60, reducedMotion: false) }
        #expect(lean.angle == -DragLean.maxDegrees)
        #expect(abs(lean.angle) <= MascotPack.attentionLeanDegrees)
        let upright = lean.sample(x: x, time: 2, reducedMotion: true)
        #expect(upright && lean.angle == 0, "Reduce Motion: upright")
        var slow = DragLean()
        _ = slow.sample(x: 0, time: 0, reducedMotion: false)
        let tiny = slow.sample(x: 1, time: 0.1, reducedMotion: false)
        #expect(!tiny, "tiny moves don't redraw")
    }

    @Test func dozeNeedsFifteenQuietMinutesIdleMoodAndFreshData() {
        let quietSince = t0
        #expect(!DozePolicy.isDozing(now: t0 + 14 * 60, lastActivity: quietSince, mood: .idle, dataState: .ready))
        #expect(DozePolicy.isDozing(now: t0 + 15 * 60, lastActivity: quietSince, mood: .idle, dataState: .ready))
        #expect(DozePolicy.isDozing(now: t0 + 15 * 60, lastActivity: quietSince, mood: .idle, dataState: .empty))
        for state in [DataState.stale, .loading, .partial, .error("x"), .ghMissing] {
            #expect(!DozePolicy.isDozing(now: t0 + 3600, lastActivity: quietSince, mood: .idle, dataState: state))
        }
        #expect(!DozePolicy.isDozing(now: t0 + 3600, lastActivity: quietSince, mood: .attention, dataState: .ready))
        #expect(DozePolicy.isDozing(now: t0 + 3600, lastActivity: quietSince, mood: .idle, dataState: .hiddenOnly(2)))
        #expect(!DozePolicy.isDozing(now: t0 + 3600, lastActivity: quietSince, mood: .idle, dataState: .ready,
                                     incidentShown: true), "never while the incident marker shows")
        #expect(DozePolicy.isDozing(now: t0 + 1, lastActivity: quietSince, mood: .idle, dataState: .ready,
                                    alertsAllowed: false), "quiet hours: enters at once")
        #expect(!DozePolicy.isDozing(now: t0 + 1, lastActivity: quietSince, mood: .idle, dataState: .stale,
                                     alertsAllowed: false))
    }

    @Test func effectsNeverReachTheLabelLane() {
        for clip in ClipCatalog.v1.ordered.map(\.id) + MascotClipID.heldStates {
            for step in 0..<60 {
                for head in [CGPoint(x: 128, y: 20), CGPoint(x: 128, y: 70)] {
                    for particle in ClipEffects.particles(clip: clip, elapsed: Double(step) / 10, head: head,
                                                          nozzle: CGPoint(x: 58, y: 70), hand: CGPoint(x: 186, y: 40)) {
                        #expect(particle.y - particle.size / 2 >= ClipEffects.topLimit)
                        #expect(particle.size <= 64)
                    }
                }
            }
        }
    }

    @Test func effectsFollowTheStoryboards() {
        let head = CGPoint(x: 128, y: 40), nozzle = CGPoint(x: 58, y: 196), hand = CGPoint(x: 186, y: 90)
        func at(_ clip: MascotClipID, _ t: Double, nozzle: CGPoint? = nozzle) -> [ClipEffects.Particle] {
            ClipEffects.particles(clip: clip, elapsed: t, head: head, nozzle: nozzle, hand: hand)
        }
        #expect(at(.incidentEnd, 0.4).isEmpty && !at(.incidentEnd, 0.8).isEmpty && at(.incidentEnd, 2.0).isEmpty)
        #expect(at(.incidentEnd, 0.8, nozzle: nil).isEmpty, "mist only where a nozzle point exists")
        #expect(at(.incidentEnd, 0.8).allSatisfy { $0.kind == .mist && $0.x <= nozzle.x && $0.y >= nozzle.y })
        #expect(at(.itemCleared, 0.1).isEmpty && at(.itemCleared, 0.4).first?.x == hand.x && at(.itemCleared, 0.7).isEmpty)
        #expect(at(.inboxZero, 1.3).count == 3 && at(.inboxZero, 1.0).isEmpty)
        #expect(at(.doze, 1.0).allSatisfy { $0.kind == .z && $0.x <= 50 })
        #expect(at(.poke, 0.3).isEmpty && at(.drop, 0.2).isEmpty)
    }

    @Test func accessoriesOnlyForARealIncidentMarker() {
        #expect(AccessoryPolicy.accessories(marker: nil).isEmpty)
        let incident = ServiceIncident(id: "i", name: "Outage", status: .investigating, impact: .minor,
                                       updatedAt: t0, isDemo: true)
        for state in [ServiceStatusState.stale, .loading, .error("x"), .operational] {
            #expect(AccessoryPolicy.accessories(marker: IncidentMarker.current(state: state, incidents: [incident])).isEmpty)
        }
        #expect(AccessoryPolicy.accessories(marker: IncidentMarker.current(state: .incidents, incidents: [incident]))
                == [AccessoryPolicy.firefighterHat])
    }
}

@Suite struct ClipAnimatorTests {
    private var library: ClipLibrary {
        var library = ClipLibrary()
        for policy in ClipCatalog.v1.ordered { library.durationsMs[policy.id] = policy.placeholder.durationMs }
        library.durationsMs[.drag] = [400, 400]
        library.durationsMs[.doze] = [1200, 1200]
        library.hidesAccessories = [.incidentStart, .incidentEnd]
        library.accessories = [AccessoryPolicy.firefighterHat]
        return library
    }
    private let hat = [AccessoryPolicy.firefighterHat]

    private func pose(mood: MascotState = .idle, clip: EventClipQueue.Clip? = nil, at now: Date, reduced: Bool = false,
                      stage: ClipStage, library: ClipLibrary? = nil, accessories: [MascotAccessoryID] = []) -> MascotPose {
        MascotAnimator.pose(mood: mood, clip: clip, now: now, reducedMotion: reduced, idleEpoch: .distantPast,
                            stage: stage, library: library ?? self.library, accessories: accessories) { _ in [400, 400] }
    }

    private func playing(_ id: MascotClipID, from start: Date) -> ClipScheduler.Playing {
        var s = ClipScheduler(seed: 1)
        s.request(ClipCatalog.v1[id]!.trigger!, now: start, permissions: allowed, duration: everyClip)
        return s.playing!
    }

    private func event(_ kind: EventClipQueue.Kind, origin: EventClipQueue.Origin = .repository,
                       severity: EventSeverity = .actionable) -> EventClipQueue.Clip {
        EventClipQueue.Clip(event: InboxEvent(item: InboxItem.fixture(kind: .reviewRequest), severity: severity),
                            startedAt: t0, origin: origin, kind: kind)
    }

    @Test func reducedMotionShowsOnlyStaticSubstitutions() {
        let stage = ClipStage(scheduled: playing(.poke, from: t0), dragStart: t0, dragAngle: 5)
        let held = pose(at: t0 + 0.3, reduced: true, stage: stage, accessories: hat)
        #expect(held.clip == ClipFrame(id: .drag, frame: nil, elapsed: 0) && held.angle == 0 && held.accessories == hat)
        let dozing = pose(at: t0 + 0.3, reduced: true, stage: ClipStage(dozeStart: t0))
        #expect(dozing.clip?.id == .doze && dozing.clip?.frame == nil)
        for kind in EventClipQueue.Kind.allCases {
            let still = pose(mood: .attention, clip: event(kind), at: t0 + 0.3, reduced: true,
                             stage: ClipStage(scheduled: playing(.poke, from: t0)), accessories: hat)
            #expect(still == MascotPose(state: .attention, frame: nil, clipElapsed: nil, accessories: hat))
        }
        // Without the held poses in the pack, the mood's static pose as today.
        let none = pose(at: t0, reduced: true, stage: stage, library: .empty, accessories: hat)
        #expect(none == MascotPose(state: .idle, frame: nil, clipElapsed: nil))
    }

    @Test func withoutClipsThePoseIsExactlyTodays() {
        let wave = EventClipQueue.Clip(event: InboxEvent(item: InboxItem.fixture(kind: .reviewRequest)), startedAt: t0)
        for now in stride(from: 0.0, to: 2.5, by: 0.1).map({ t0 + $0 }) {
            for mood in MascotState.allCases {
                let legacy = MascotAnimator.pose(mood: mood, clip: wave, now: now, reducedMotion: false, idleEpoch: t0,
                                                 gesture: .friendlyDoubleWave) { _ in [400, 400] }
                let staged = MascotAnimator.pose(mood: mood, clip: wave, now: now, reducedMotion: false, idleEpoch: t0,
                                                 gesture: .friendlyDoubleWave,
                                                 stage: ClipStage(scheduled: playing(.inboxZero, from: t0), dragStart: t0,
                                                                  dozeStart: t0),
                                                 library: .empty, accessories: hat) { _ in [400, 400] }
                #expect(legacy == staged)
            }
        }
    }

    @Test func dragMasksEventsAndTheirClockKeepsRunning() {
        let held = pose(mood: .attention, clip: event(.newItem), at: t0 + 0.5, stage: ClipStage(dragStart: t0 + 0.2, dragAngle: -2.5))
        #expect(held.clip?.id == .drag && held.angle == -2.5)
        let released = pose(mood: .attention, clip: event(.newItem), at: t0 + 1.0, stage: ClipStage())
        #expect(released.clip?.id == .newItem && released.clip?.frame == 3, "the event clock kept running")
    }

    @Test func dropSpringsTheLeanBackOverTwoHundredMilliseconds() {
        let stage = ClipStage(released: (t0, 4))
        #expect(stage.springAngle(at: t0) == 4)
        #expect(stage.springAngle(at: t0 + 0.1) > 0 && stage.springAngle(at: t0 + 0.1) < 4)
        #expect(stage.springAngle(at: t0 + 0.2) == 0)
    }

    @Test func eventKindsPlayTheirClipsAndNewItemOnlyReplacesRepositoryWaves() {
        #expect(pose(mood: .attention, clip: event(.newItem), at: t0 + 0.1, stage: .empty).clip?.id == .newItem)
        #expect(pose(mood: .attention, clip: event(.newItem, origin: .serviceIncident), at: t0 + 0.1, stage: .empty).clip == nil,
                "an incident escalation keeps the wave")
        #expect(pose(mood: .urgent, clip: event(.incidentStart, origin: .serviceIncident, severity: .critical), at: t0 + 0.1,
                     stage: .empty).clip?.id == .incidentStart)
        #expect(pose(clip: event(.incidentEnd, origin: .serviceIncident), at: t0 + 0.1, stage: .empty).clip?.id == .incidentEnd)
        let urgent = pose(mood: .urgent, clip: event(.urgent, severity: .critical), at: t0 + 0.1, stage: .empty)
        #expect(urgent.clip == nil && urgent.state == .urgent, "critical keeps the urgent clip")
    }

    @Test func higherOfSchedulerAndEventClipPlaysAndDozeOnlyWhenNothingElse() {
        let cleared = playing(.itemCleared, from: t0)
        #expect(pose(mood: .attention, clip: event(.newItem), at: t0 + 0.1, stage: ClipStage(scheduled: cleared)).clip?.id == .newItem)
        #expect(pose(at: t0 + 0.1, stage: ClipStage(scheduled: cleared, dozeStart: t0)).clip?.id == .itemCleared)
        let dozing = pose(at: t0 + 1.3, stage: ClipStage(dozeStart: t0))
        #expect(dozing.clip?.id == .doze && dozing.clip?.frame == 1)
        #expect(pose(mood: .attention, at: t0 + 1.3, stage: ClipStage(dozeStart: t0)).clip == nil)
    }

    @Test func dizzyWobblesWithinTheLeanLimit() {
        let dizzy = playing(.dizzy, from: t0)
        let angles = stride(from: 0.0, to: 1.6, by: 0.05).map { pose(at: t0 + $0, stage: ClipStage(scheduled: dizzy)).angle }
        #expect(angles.min()! <= -4.9 && angles.max()! >= 4.9 && angles.first == 0)
        var tight = library
        tight.leanLimit = 2
        let limited = stride(from: 0.0, to: 1.6, by: 0.05).map {
            pose(at: t0 + $0, stage: ClipStage(scheduled: dizzy), library: tight).angle
        }
        #expect(limited.allSatisfy { abs($0) <= 2 })
    }

    @Test func hatShowsExceptInClipsThatBakeItIn() {
        #expect(pose(clip: event(.incidentStart, origin: .serviceIncident), at: t0 + 0.1, stage: .empty, accessories: hat)
            .accessories.isEmpty)
        #expect(pose(at: t0 + 0.1, stage: ClipStage(scheduled: playing(.poke, from: t0)), accessories: hat).accessories == hat)
        #expect(pose(at: t0 + 0.1, stage: .empty, accessories: hat).accessories == hat)
        #expect(pose(at: t0 + 0.1, stage: .empty, library: .empty, accessories: hat).accessories.isEmpty,
                "no hat image in the pack: nothing drawn")
    }
}

// MARK: Pack schema v2

/// A PNG with an opaque rectangle (canvas pixels, top row first).
private func art(_ rect: CGRect, size: Int = 256, noise: Bool = false) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if noise, let data = context.data {
        // Incompressible pixels for a maximal-size pack.
        let bytes = data.bindMemory(to: UInt32.self, capacity: size * size)
        var generator = SplitMix64(seed: UInt64(rect.minX * 1000 + rect.minY))
        for index in 0..<(size * size) { bytes[index] = UInt32(truncatingIfNeeded: generator.next()) | 0xFF00_0000 }
    } else {
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: rect.minX, y: CGFloat(size) - rect.maxY, width: rect.width, height: rect.height))
    }
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

private let body = CGRect(x: 60, y: 40, width: 140, height: 190)

private struct V2Fixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitHubPetV2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try write("frames/body.png", art(body))
        try write("frames/small.png", art(CGRect(x: 80, y: 60, width: 100, height: 160)))
        try write("frames/hat.png", art(CGRect(x: 100, y: 40, width: 60, height: 20)))
        try write("frames/wide.png", art(CGRect(x: 20, y: 40, width: 200, height: 190)))
    }

    func write(_ path: String, _ data: Data) throws { try data.write(to: directory.appendingPathComponent(path)) }

    func manifest(schema: Int = 2, mutate: (inout [String: Any]) -> Void = { _ in }) throws {
        func state(_ loop: Bool, _ frames: [String] = ["frames/body.png", "frames/small.png"]) -> [String: Any] {
            ["frames": frames, "durationMs": frames.map { _ in 400 }, "loop": loop, "staticFallback": "frames/body.png"]
        }
        var json: [String: Any] = [
            "schemaVersion": schema, "id": "v2-pack", "name": "V2",
            "canvas": ["width": 256, "height": 256], "anchor": [128, 232],
            "states": ["idle": state(true), "attention": state(false), "urgent": state(false),
                       "drag": state(true), "doze": state(true)],
            "clips": ["poke": ["frames": ["frames/small.png", "frames/body.png"], "durationMs": [300, 400]],
                      "incident-start": ["frames": ["frames/body.png"], "durationMs": [1900], "accessories": "hide"]],
            "accessories": ["firefighter-hat": ["image": "frames/hat.png", "attach": "head"]],
            "points": ["head": [130, 60]],
            "framePoints": ["frames/small.png": ["head": [130, 80], "nozzle": [190, 120]]],
        ]
        mutate(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("manifest.json"))
    }

    func load(budget: PackBudget = .custom) -> Result<MascotPack, MascotPackErrors> {
        MascotPack.load(from: directory, budget: budget)
    }

    func errors(budget: PackBudget = .custom) -> [MascotPackError] {
        if case .failure(let failure) = load(budget: budget) { return failure.errors }
        return []
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

@Suite struct PackSchemaV2Tests {
    @Test func v2PackDecodesClipsHeldPosesAccessoriesAndPoints() throws {
        let fixture = try V2Fixture()
        try fixture.manifest()
        let pack = try fixture.load().get()
        let library = ClipLibrary(pack: pack)
        #expect(library.has(.drag) && library.has(.doze) && library.has(.poke) && library.has(.incidentStart))
        #expect(!library.has(.dizzy), "a missing clip stays missing")
        #expect(library.duration(.poke) == 0.7)
        #expect(library.hidesAccessories == [.incidentStart] && library.accessories == [AccessoryPolicy.firefighterHat])
        #expect(pack.headPoint == CGPoint(x: 130, y: 60))
        #expect(pack.headOffset(for: "frames/small.png") == CGPoint(x: 0, y: 20))
        #expect(pack.nozzle(for: "frames/small.png") == CGPoint(x: 190, y: 120))
        let poke = MascotPose(state: .idle, frame: nil, clipElapsed: 0, clip: ClipFrame(id: .poke, frame: 0, elapsed: 0),
                              accessories: [AccessoryPolicy.firefighterHat])
        #expect(pack.imagePath(for: poke) == "frames/small.png")
        // The hat (rows 40–59 at the default head) moves down 20 rows with this frame's head point.
        let contour = try #require(pack.contour(for: poke))
        #expect(contour[130] == 60 && contour[90] == 60)
        let fallback = MascotPose(state: .urgent, frame: nil, clipElapsed: nil, clip: ClipFrame(id: .poke, frame: nil, elapsed: 0))
        #expect(pack.imagePath(for: fallback) == "frames/body.png", "no clip fallback: the mood's static pose")
    }

    @Test func v1ManifestsLoadExactlyAsBeforeAndIgnoreV2Keys() throws {
        let fixture = try V2Fixture()
        try fixture.manifest(schema: 1) { json in json["clips"] = ["not-a-clip": ["frames": [], "durationMs": []]] }
        let pack = try fixture.load().get()
        #expect(ClipLibrary(pack: pack) == .empty)
        #expect(pack.extraUprightContours.isEmpty && pack.manifest.v2ImagePaths.isEmpty)
        // The bundled packs load under the bundled budget (bounds rule included) and offer exactly
        // the clips and held poses their manifests declare (#138: only those inside the union ship).
        for skin in MascotSkin.allCases {
            let bundled = try MascotPack.load(from: repositoryRoot().appendingPathComponent("assets/mascots/\(skin.rawValue)"),
                                              expectedID: skin.rawValue, budget: .bundled).get()
            let declared = Set((bundled.manifest.clips ?? [:]).keys.map { MascotClipID($0) })
                .union(MascotClipID.heldStates.filter { bundled.manifest.heldSpec($0) != nil })
            #expect(Set(ClipLibrary(pack: bundled).durationsMs.keys) == declared)
            let total = bundled.imageData.values.reduce(0) { $0 + $1.count }
            #expect(bundled.imageData.count <= PackBudget.bundled.maxImages && total <= PackBudget.bundled.maxBytes)
        }
    }

    @Test func v2StructureErrorsAreSpecific() throws {
        func errors(_ mutate: @escaping (inout [String: Any]) -> Void) throws -> [MascotPackError] {
            let fixture = try V2Fixture()
            try fixture.manifest(mutate: mutate)
            return fixture.errors()
        }
        #expect(try errors { var s = $0["states"] as! [String: Any]; s["juggle"] = s["drag"]; $0["states"] = s }
                == [.unknownState("juggle")])
        #expect(try errors { var s = $0["states"] as! [String: [String: Any]]; s["doze"]!["loop"] = false; $0["states"] = s }
                == [.wrongLoopFlag("doze", expected: true)])
        #expect(try errors { $0["clips"] = ["moonwalk": ["frames": ["frames/body.png"], "durationMs": [400]]] }
                == [.unknownClip("moonwalk")])
        #expect(try errors { $0["clips"] = ["poke": ["frames": ["frames/body.png"], "durationMs": [400], "loop": true]] }
                == [.wrongLoopFlag("poke", expected: false)])
        #expect(try errors { $0["clips"] = ["new-item": ["frames": ["frames/body.png", "frames/small.png"], "durationMs": [1000, 1000]]] }
                == [.clipTooLong("new-item", 2000, 1900)], "new-item plays inside the 1.9 s wave")
        #expect(try errors { $0["clips"] = ["poke": ["frames": Array(repeating: "frames/body.png", count: 13),
                                                     "durationMs": Array(repeating: 125, count: 13)]] }
                == [.frameCount("poke")])
        #expect(try errors { $0["accessories"] = ["tiara": ["image": "frames/hat.png", "attach": "head"]] }
                == [.unknownAccessory("tiara")])
        #expect(try errors { $0["accessories"] = ["firefighter-hat": ["image": "frames/hat.png", "attach": "tail"]] }
                == [.badAccessory("firefighter-hat")])
        #expect(try errors { $0["points"] = ["head": [300, 10]] } == [.badPoint("points")])
        #expect(try errors { $0["framePoints"] = ["frames/unused.png": ["head": [1, 1]]] } == [.badPoint("frames/unused.png")])
        #expect(try errors { $0["points"] = nil; $0["framePoints"] = nil } == [.badPoint("points")],
                "the hat needs the default head point")
        #expect(try errors { $0["points"] = ["head": [130, 60], "hand": [256, 0]] } == [.badPoint("points")])
        // incident-end's spray frames (02 and 03) must name a nozzle.
        let end: [String: Any] = ["frames": ["frames/body.png", "frames/body.png", "frames/small.png", "frames/body.png"],
                                  "durationMs": [400, 400, 400, 400], "accessories": "hide"]
        #expect(try errors { var clips = $0["clips"] as! [String: Any]; clips["incident-end"] = end; $0["clips"] = clips }
                == [.badPoint("frames/body.png")])
        #expect(try errors { var clips = $0["clips"] as! [String: Any]; clips["incident-end"] = end; $0["clips"] = clips
                             $0["points"] = ["head": [130, 60], "nozzle": [70, 200]] } == [])
    }

    @Test func bundledClipAndHatPixelsMustStayInsideTheStatesArt() throws {
        let wide = try V2Fixture()
        try wide.manifest { json in json["clips"] = ["poke": ["frames": ["frames/wide.png"], "durationMs": [400]]] }
        #expect(wide.errors(budget: .bundled) == [.outsideArt("frames/wide.png")])
        // A head point that would push the hat out of the art (right of it) is caught too.
        let hat = try V2Fixture()
        try hat.manifest { json in json["framePoints"] = ["frames/small.png": ["head": [200, 60]]] }
        #expect(hat.errors(budget: .bundled) == [.outsideArt("frames/hat.png")])
        // A custom pack may draw outside: it loads with the hover outline widened instead.
        let custom = try wide.load().get()
        #expect(custom.artProfiles[.idle]?.bounds?.minX == 20)
        let inside = try V2Fixture()
        try inside.manifest()
        #expect(try inside.load().get().artProfiles[.idle]?.bounds?.minX == 60)
    }

    @Test func imageBudgetsDifferForCustomAndBundledPacks() throws {
        // More distinct images than the budget allows, none on disk: rejected before any file is opened.
        func overBudget(frames: Int) throws -> V2Fixture {
            let fixture = try V2Fixture()
            try fixture.manifest { json in
                let ids: [MascotClipID] = [.incidentStart, .inboxZero, .dizzy, .idleLook, .idleStretch, .idleFidget]
                json["clips"] = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
                    (id.rawValue, ["frames": (0..<frames).map { "frames/missing-\(index)-\($0).png" },
                                   "durationMs": Array(repeating: 125, count: frames)] as [String: Any])
                })
                var states = json["states"] as! [String: [String: Any]]
                for (index, key) in ["drag", "doze"].enumerated() {
                    states[key]!["frames"] = (0..<frames).map { "frames/held-\(index)-\($0).png" }
                    states[key]!["durationMs"] = Array(repeating: 400, count: frames)
                    states[key]!["staticFallback"] = "frames/held-\(index)-0.png"
                }
                json["states"] = states
            }
            return fixture
        }
        // body, small and hat, plus six clips and two held poses.
        #expect(try overBudget(frames: 12).errors() == [.tooManyImages(3 + 8 * 12, limit: 96)])
        #expect(try overBudget(frames: 8).errors(budget: .bundled) == [.tooManyImages(3 + 8 * 8, limit: 64)])
        #expect(try overBudget(frames: 8).errors().allSatisfy { if case .missingFile = $0 { true } else { false } },
                "67 images are within the custom budget")
        // The bundled byte budget is 4 MiB; the custom one stays at #123's 16 MiB.
        let heavy = try V2Fixture()
        var padded = art(body)
        padded.append(Data(count: 3 * 1024 * 1024))
        try heavy.write("frames/body.png", padded)
        try heavy.write("frames/small.png", padded)
        try heavy.manifest()
        #expect(heavy.errors(budget: .bundled) == [.tooLarge("frames/body.png"), .tooLarge("frames/small.png")],
                "bundled images are at most 96 KiB each")
        #expect(heavy.errors() == [])
        // Bundled: at most 8 frames per state or clip; custom keeps 12.
        let long = try V2Fixture()
        try long.manifest { $0["clips"] = ["idle-look": ["frames": Array(repeating: "frames/body.png", count: 9),
                                                         "durationMs": Array(repeating: 125, count: 9)]] }
        #expect(long.errors(budget: .bundled) == [.frameCount("idle-look")])
        #expect(long.errors() == [])
        #expect(PackBudget.custom.maxBytes == 16 * 1024 * 1024 && MascotPack.maxImageBytes == 4 * 1024 * 1024)
    }

    @Test func ninetySixImagePackLoadsWithinTheLimits() throws {
        let fixture = try V2Fixture()
        // 96 distinct 256×256 images: the most a custom pack may use. Byte limits have their own tests;
        // the load time of a maximal 14 MiB pack is measured on a release build (PR #163 evidence),
        // since debug test builds are far slower and would only load the shared test machine.
        var paths: [String] = []
        var total = 0
        for index in 0..<96 {
            let noisy = false
            let data = art(CGRect(x: index, y: index % 7, width: 40, height: 40), noise: noisy)
            let path = "frames/max-\(index).png"
            try fixture.write(path, data)
            paths.append(path)
            total += data.count
        }
        #expect(total <= PackBudget.custom.maxBytes)
        try fixture.manifest { json in
            func spec(_ frames: ArraySlice<String>, loop: Bool) -> [String: Any] {
                ["frames": Array(frames), "durationMs": frames.map { _ in 150 }, "loop": loop, "staticFallback": frames.first!]
            }
            // State frames keep #123's 24; held poses and clips use the v2 image budget.
            json["states"] = ["idle": spec(paths[0..<8], loop: true), "attention": spec(paths[8..<16], loop: false),
                              "urgent": spec(paths[16..<24], loop: false), "drag": spec(paths[24..<36], loop: true),
                              "doze": spec(paths[36..<48], loop: true)]
            let ids = [MascotClipID.idleStretch, .dizzy, .idleLook, .inboxZero]
            json["clips"] = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
                (id.rawValue, ["frames": Array(paths[(48 + index * 12)..<(60 + index * 12)]),
                               "durationMs": Array(repeating: 125, count: 12)] as [String: Any])
            })
            json["accessories"] = [:]
            json["points"] = [:]
            json["framePoints"] = [:]
        }
        let started = Date()
        let pack = try fixture.load().get()
        let seconds = Date().timeIntervalSince(started)
        print("96-image custom pack (debug build): \(pack.imageData.count) images, \(total) bytes, loaded in \(String(format: "%.2f", seconds)) s")
        #expect(pack.manifest.imagePaths.count == 96)
        // Debug test builds are far slower than the app; the release-build time is measured separately
        // (PR evidence). This bound only catches a pathological regression.
        #expect(seconds < 60)
    }

    @Test func placeholderClipsCoverTheDesignListWithoutChangingTheLayout() throws {
        for skin in MascotSkin.allCases {
            let original = try MascotPack.load(from: repositoryRoot().appendingPathComponent("assets/mascots/\(skin.rawValue)"),
                                               expectedID: skin.rawValue, budget: .bundled).get()
            var placeholder = original.withPlaceholderClips()
            let library = ClipLibrary(pack: placeholder)
            for id in ClipCatalog.v1.ordered.map(\.id) + MascotClipID.heldStates {
                #expect(library.has(id), "\(skin.rawValue) placeholder \(id)")
                // Placeholders fill only what the bundled art does not have.
                #expect(placeholder.placeholderClips.contains(id) == !ClipLibrary(pack: original).has(id))
            }
            #expect(library.accessories == [AccessoryPolicy.firefighterHat])
            #expect(placeholder.measureClips() == [], "the placeholder hat and frames stay inside the art")
            for side in [64.0, 128, 256] {
                let before = MascotLayout(artSide: side, pack: original), after = MascotLayout(artSide: side, pack: placeholder)
                #expect(before.laneHeight == after.laneHeight && before.panelSize == after.panelSize
                        && before.countSlotX == after.countSlotX, "\(skin.rawValue) @\(side)")
            }
            #expect(original.placeholderClips.isEmpty, "the loaded pack itself is untouched")
        }
    }
}

private extension InboxItem {
    static func fixture(kind: ItemKind, id: String = "fixture") -> InboxItem {
        InboxItem(id: "\(kind.rawValue):\(id)", kind: kind, repository: "example/pet", title: "Fixture", url: nil,
                  updatedAt: t0)
    }
}
