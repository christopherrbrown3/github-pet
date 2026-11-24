import AppKit
import Combine
import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

/// #166: a visible idle mascot redraws only when its art changes, and the 0.25 s tick no longer
/// tells every view about the clock. Gestures keep their 30 fps and in-between motion its 8 fps.
@Suite(.serialized) @MainActor struct IdleRedrawTests {
    private static let start = Date(timeIntervalSince1970: 1_763_208_000) // a whole minute
    private static let mona = [2000, 200, 200, 2000]
    private static let idle = IdleFrameSchedule(mood: .idle, clockOffset: 0, durationsMs: mona)

    private func redraw(pack: Bool = true, clip: EventClipQueue.Clip? = nil, stage: ClipStage = .empty,
                        bursting: Bool = false, dozeHasClip: Bool = false) -> MascotView.Redraw {
        MascotView.redraw(pack: pack, clip: clip, stage: stage, markerBursting: bursting, dozeHasClip: dozeHasClip,
                          now: Self.start, idle: Self.idle)
    }

    @Test func idlePackRedrawsOnFrameChangesOnly() {
        #expect(redraw() == .idleFrames(Self.idle))
        // A doze without a doze clip shows the idle loop.
        #expect(redraw(stage: ClipStage(dozeStart: Self.start)) == .idleFrames(Self.idle))
    }

    @Test func gesturesAndInBetweenMotionKeepTheirRates() {
        let event = InboxEvent(item: FixtureSimulator().injectEntitlementEvent())
        let gesture = MascotView.Redraw.continuous(fps: 30), motion = MascotView.Redraw.continuous(fps: 8)
        #expect(redraw(clip: EventClipQueue.Clip(event: event, startedAt: Self.start)) == gesture)
        #expect(redraw(stage: ClipStage(dragStart: Self.start)) == gesture)
        #expect(redraw(bursting: true) == gesture)
        #expect(redraw(pack: false) == motion, "the placeholder breathes")
        #expect(redraw(stage: ClipStage(dozeStart: Self.start), dozeHasClip: true) == motion, "doze's Z effects move")
        #expect(redraw(stage: ClipStage(released: (Self.start.addingTimeInterval(-0.05), 4))) == motion, "release spring")
        #expect(redraw(stage: ClipStage(released: (Self.start.addingTimeInterval(-1), 4))) == .idleFrames(Self.idle),
                "a settled spring holds")
    }

    /// #138: a cutout rig idles exactly like a frame pack (its states are baked frames, the blink is
    /// a frame change) and draws its clips at 60 fps; frame packs keep 30.
    @Test func rigIdlesOnFrameChangesAndPlaysClipsAt60() {
        func rig(clip: EventClipQueue.Clip? = nil, stage: ClipStage = .empty) -> MascotView.Redraw {
            MascotView.redraw(pack: true, clip: clip, stage: stage, markerBursting: false, dozeHasClip: false,
                              now: Self.start, idle: Self.idle, rig: true)
        }
        #expect(rig() == .idleFrames(Self.idle))
        let event = InboxEvent(item: FixtureSimulator().injectEntitlementEvent())
        #expect(rig(clip: EventClipQueue.Clip(event: event, startedAt: Self.start)) == .continuous(fps: 60))
        #expect(rig(stage: ClipStage(dragStart: Self.start)) == .continuous(fps: 30), "drag shows frames")
    }

    /// The memo must key on everything the width depends on: the same text at another size or role
    /// is a different width (QA #168).
    @Test func countWidthMemoKeysOnSizeAndRole() {
        let small = Tag.textWidth("42", role: .count, size: 11), large = Tag.textWidth("42", role: .count, size: 22)
        #expect(large > small * 1.8 && large < small * 2.2, "\(small) at 11 pt, \(large) at 22 pt")
        #expect(Tag.textWidth("42", role: .count, size: 11) == small, "memoized")
        #expect(Tag.textWidth("DEMO", role: .demo, size: 11) != Tag.textWidth("DEMO", role: .count, size: 11))
    }

    /// The schedule SwiftUI reads: never faster than the pose changes, on the app clock.
    @Test(arguments: [0.0, 86_400.37])
    func scheduleEntriesAreFrameChanges(offset: TimeInterval) {
        let schedule = IdleFrameSchedule(mood: .idle, clockOffset: offset, durationsMs: Self.mona)
        func pose(_ date: Date) -> MascotPose {
            MascotAnimator.pose(mood: .idle, clip: nil, now: date.addingTimeInterval(offset), reducedMotion: false,
                                idleEpoch: .distantPast) { _ in Self.mona }
        }
        let entries = Array(schedule.entries(from: Self.start.addingTimeInterval(0.3), mode: .normal).prefix(20))
        #expect(entries.count == 20)
        for (previous, next) in zip(entries, entries.dropFirst()) {
            #expect(next.timeIntervalSince(previous) >= Double(FrameClock.minimumDurationMs) / 1000 - 0.001)
            #expect(pose(next) != pose(previous))
        }
        // 20 entries span about 4.4 s loops of 4 frames: about 22 s, not 20 frames at 8 fps.
        #expect(entries.last!.timeIntervalSince(entries.first!) > 15)
        let held = IdleFrameSchedule(mood: .attention, clockOffset: offset, durationsMs: Self.mona)
        #expect(Array(held.entries(from: Self.start, mode: .normal).prefix(3)).count == 1, "a held mood draws once")
    }

    @Test(arguments: [false, true])
    func idleTicksDoNotNotifyViews(reducedMotion: Bool) async {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_763_208_001) }
        let clock = Clock()
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--fixtures"], environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "dev.github-pet.tests.idle-redraw.\(UUID().uuidString)")
        _ = NSApplication.shared
        let app = AppModel(options: options, runtime: AppModel.Runtime(now: { clock.now }, systemReducedMotion: { reducedMotion },
                                                                      schedulesTimers: false))
        app.tick()
        await Task.yield()
        var notified = 0
        let observer = app.objectWillChange.sink { _ in notified += 1 }
        defer { observer.cancel() }
        // Within one minute and with nothing else changing, ticks only advance the clock.
        for _ in 0..<160 {
            clock.now += 0.25
            app.tick()
        }
        #expect(notified == 0)
        #expect(app.now == clock.now, "readers still get the latest tick")
        clock.now = Self.start.addingTimeInterval(60)
        app.tick()
        #expect(notified == 1, "a new minute reaches views (quiet hours)")
    }

    /// A snooze that ends mid-minute reaches views on the tick it ends, not at the next minute.
    @Test func snoozeEndingMidMinuteNotifiesViews() async {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_763_208_001) }
        let clock = Clock()
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--fixtures"], environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "dev.github-pet.tests.idle-redraw.\(UUID().uuidString)")
        _ = NSApplication.shared
        let app = AppModel(options: options, runtime: AppModel.Runtime(now: { clock.now }, systemReducedMotion: { false },
                                                                      schedulesTimers: false, features: .allOn))
        app.settings.snoozeUntil = Self.start.addingTimeInterval(30.1)
        app.tick()
        await Task.yield()
        var notified: [Date] = []
        let observer = app.objectWillChange.sink { _ in notified.append(clock.now) }
        defer { observer.cancel() }
        for _ in 0..<160 {
            clock.now += 0.25
            app.tick()
        }
        #expect(notified == [Self.start.addingTimeInterval(30.25)], "once, on the first tick after the snooze ends")
    }
}
