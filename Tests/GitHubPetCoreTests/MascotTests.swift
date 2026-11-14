import Foundation
import Testing
@testable import GitHubPetCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func item(_ id: String, _ kind: ItemKind = .reviewRequest) -> InboxItem {
    InboxItem(id: id, kind: kind, repository: "secret-org/secret-repo", title: "Secret title \(id)",
              url: URL(string: "https://github.com/secret-org/secret-repo/pull/1"), updatedAt: t0)
}

@Suite struct SafeLinkTests {
    @Test(arguments: [
        "https://github.com/example/repo/pull/1",
        "https://GitHub.com/example/repo/issues/2?x=1#frag",
        "https://github.com:443/settings/copilot",
    ])
    func allowsHTTPSGitHub(_ string: String) {
        #expect(SafeLink.validated(string) != nil)
    }

    @Test(arguments: [
        "http://github.com/example/repo",
        "https://github.com.evil.example/x",
        "https://evil.example/github.com",
        "https://user:pass@github.com/x",
        "https://github.com@evil.example/x",
        "https://github.com:8443/x",
        "javascript:alert(1)",
        "file:///etc/passwd",
        "x-github-client://openRepo",
        " https://github.com/x",
        "https://github.com/x\nhttps://evil.example",
        "",
    ])
    func rejectsEverythingElse(_ string: String) {
        #expect(SafeLink.validated(string) == nil)
    }

    @Test func nilIsRejected() {
        #expect(SafeLink.validated(nil as URL?) == nil)
    }
}

@Suite struct MascotPolicyTests {
    @Test func unknownDataIsNeverAllClearOrZero() {
        for state in [DataState.loading, .stale, .error("x"), .ghMissing, .unauthenticated] {
            #expect(MascotPolicy.badge(dataState: state, count: 0) == "?")
            #expect(MascotPolicy.badge(dataState: state, count: 5) == "?", "no exact-looking count for \(state)")
            #expect(MascotPolicy.countDescription(dataState: state, count: 5).hasPrefix("count unknown"))
        }
        #expect(MascotPolicy.badge(dataState: .partial, count: 0) == "0+")
        #expect(MascotPolicy.badge(dataState: .partial, count: 2) == "2+")
        #expect(MascotPolicy.badge(dataState: .ready, count: 3) == "3")
        #expect(MascotPolicy.badge(dataState: .empty, count: 0) == nil, "only a verified empty inbox has no badge")
    }

    @Test func countDescriptionsMatchQuality() {
        #expect(MascotPolicy.countDescription(dataState: .ready, count: 1) == "1 item")
        #expect(MascotPolicy.countDescription(dataState: .empty, count: 0) == "all clear")
        #expect(MascotPolicy.countDescription(dataState: .partial, count: 2) == "at least 2 items, some sources unavailable")
    }

    @Test func authProblemsAreUrgent() {
        #expect(MascotPolicy.state(dataState: .unauthenticated, items: [], unseenCount: 0, alertsAllowed: true) == .urgent)
        #expect(MascotPolicy.state(dataState: .ghMissing, items: [], unseenCount: 0, alertsAllowed: false) == .urgent)
    }

    @Test func unseenEventsNeedAlertsAllowed() {
        let items = [item("a")]
        #expect(MascotPolicy.state(dataState: .ready, items: items, unseenCount: 1, alertsAllowed: true) == .attention)
        #expect(MascotPolicy.state(dataState: .ready, items: items, unseenCount: 1, alertsAllowed: false) == .idle)
        #expect(MascotPolicy.state(dataState: .ready, items: items, unseenCount: 0, alertsAllowed: true) == .idle)
    }

    @Test func criticalItemsAreUrgent() {
        let items = [item("a", .ciFailure)]
        #expect(MascotPolicy.state(dataState: .ready, items: items, unseenCount: 0, alertsAllowed: false) == .urgent)
    }
}

@Suite struct PrivacyTextTests {
    @Test func privacyHidesRepositoryAndTitleEverywhere() {
        let items = [item("a"), item("b", .entitlement)]
        let lines = PrivacyText.summary(dataState: .ready, items: items, unseenCount: 1, privacy: true)
        let joined = lines.joined(separator: "\n")
        #expect(!joined.contains("secret"))
        #expect(lines.contains("Review request"))
        #expect(lines.contains("Entitlement update"))
        #expect(lines.first == "2 items · 1 new")
        #expect(PrivacyText.title(items[0], privacy: true) == "Review request")
        #expect(PrivacyText.repository(items[0], privacy: true) == nil)
    }

    @Test func withoutPrivacyShowsDetails() {
        let lines = PrivacyText.summary(dataState: .ready, items: [item("a")], unseenCount: 0, privacy: false)
        #expect(lines.contains { $0.contains("secret-org/secret-repo") && $0.contains("Secret title a") })
    }

    @Test func degradedStatesAreStatedInSummary() {
        let error = PrivacyText.summary(dataState: .error("offline"), items: [item("a")], unseenCount: 0, privacy: false)
        #expect(error == ["Error: offline"], "no count and no last-known rows in the hover for errors")
        let partial = PrivacyText.summary(dataState: .partial, items: [item("a")], unseenCount: 0, privacy: false)
        #expect(partial.prefix(2) == ["1+ items", "Partial data"])
        let empty = PrivacyText.summary(dataState: .empty, items: [], unseenCount: 0, privacy: false)
        #expect(empty == ["All clear"])
    }
}

@Suite struct EventClipQueueTests {
    private func event(_ id: String, _ kind: ItemKind = .reviewRequest) -> InboxEvent { InboxEvent(item: item(id, kind)) }

    @Test func playsOnceThenSettles() {
        var queue = EventClipQueue()
        queue.enqueue([event("a")], now: t0, playable: true)
        #expect(queue.active?.event.item.id == "a")
        #expect(queue.tick(now: t0 + EventClipQueue.duration(of: .attention)) == nil)
        #expect(queue.tick(now: t0 + 60) == nil)
    }

    @Test func notPlayableQueuesNothingAndNeverReplays() {
        var queue = EventClipQueue()
        queue.enqueue([event("a")], now: t0, playable: false)
        #expect(queue.active == nil)
        #expect(queue.tick(now: t0 + 60) == nil, "a suppressed batch is not played later")
    }

    @Test func oneBatchIsOneGesture() {
        var queue = EventClipQueue()
        queue.enqueue((1...10).map { event("e\($0)") }, now: t0, playable: true)
        #expect(queue.active?.startedAt == t0)
        #expect(queue.tick(now: t0 + 1.9) == nil, "no backlog of clips after the gesture")
    }

    @Test func arrivalsDuringAGestureMergeWithoutRestarting() {
        var queue = EventClipQueue()
        queue.enqueue([event("a")], now: t0, playable: true)
        queue.enqueue([event("b"), event("c")], now: t0 + 1, playable: true)
        #expect(queue.active?.event.item.id == "a" && queue.active?.startedAt == t0)
        #expect(queue.tick(now: t0 + 1.9) == nil)
        // A later, separate batch after the gesture ends plays normally.
        queue.enqueue([event("d")], now: t0 + 5, playable: true)
        #expect(queue.active?.startedAt == t0 + 5)
    }

    @Test func urgentPreemptsAndTheInterruptedWaveIsNotReplayed() {
        var queue = EventClipQueue()
        queue.enqueue([event("a")], now: t0, playable: true)
        queue.enqueue([event("boom", .ciFailure)], now: t0 + 0.5, playable: true)
        #expect(queue.active?.event.item.id == "boom" && queue.active?.state == .urgent)
        #expect(queue.tick(now: t0 + 0.5 + EventClipQueue.duration(of: .urgent)) == nil, "attention is not replayed")
        // An attention batch never preempts urgent.
        queue.enqueue([event("x", .ciFailure)], now: t0 + 10, playable: true)
        queue.enqueue([event("y")], now: t0 + 10.5, playable: true)
        #expect(queue.active?.event.item.id == "x")
    }
}

@Suite struct AttentionGestureTests {
    private let gesture = AttentionGesture.friendlyDoubleWave

    @Test func storyboardFramesAndAngles() {
        // (time ms, frame, angle) at each step start: angle reached exactly there.
        let expected: [(Double, Int, Double)] = [(0, 0, 0), (150, 1, -5), (400, 2, 5), (600, 1, -5),
                                                 (850, 2, 5), (1050, 3, 0), (1300, 3, 0), (1899, 3, 0)]
        for (ms, frame, angle) in expected {
            #expect(gesture.frame(atMs: ms) == frame, "frame at \(ms)")
            #expect(abs(gesture.angle(atMs: ms) - angle) < 0.001, "angle at \(ms)")
        }
        #expect(gesture.durationMs == 1900 && gesture.maxAngle == 5)
    }

    @Test func leanIsContinuousBoundedAndEased() {
        var previous = gesture.angle(atMs: 0)
        for ms in stride(from: 1.0, through: 1900, by: 1) {
            let angle = gesture.angle(atMs: ms)
            #expect(abs(angle) <= 5.0001)
            #expect(abs(angle - previous) < 0.6, "no snap at \(ms) ms")
            previous = angle
        }
        // Ease-out: most of the motion early in each interval.
        #expect(AttentionGesture.ease(0) == 0 && abs(AttentionGesture.ease(1) - 1) < 0.0001)
        #expect(AttentionGesture.ease(0.5) > 0.8)
    }

    @Test func animatorPlaysTheGestureAndReducedMotionIsStatic() {
        var queue = EventClipQueue()
        queue.enqueue([InboxEvent(item: item("a", .entitlement))], now: t0, playable: true)
        let clip = queue.active!
        let durations: (MascotState) -> [Int] = { _ in [300, 400, 400, 800] }
        let leaning = MascotAnimator.pose(mood: .attention, clip: clip, now: t0 + 0.401, reducedMotion: false,
                                          idleEpoch: t0, gesture: gesture, durationsMs: durations)
        // Just past the +5° target, already easing back toward −5°.
        #expect(leaning.frame == 2 && leaning.angle > 4.5 && leaning.angle <= 5)
        let still = MascotAnimator.pose(mood: .attention, clip: clip, now: t0 + 0.4, reducedMotion: true,
                                        idleEpoch: t0, gesture: gesture, durationsMs: durations)
        #expect(still == MascotPose(state: .attention, frame: nil, clipElapsed: nil, angle: 0))
        let after = MascotAnimator.pose(mood: .attention, clip: clip, now: t0 + 1.95, reducedMotion: false,
                                        idleEpoch: t0, gesture: gesture, durationsMs: durations)
        #expect(after.frame == nil && after.angle == 0, "finite: settles on the static pose")
    }
}

@Suite struct FrameClockTests {
    @Test func loopsThroughDurations() {
        let d = [200, 200, 400]
        #expect(FrameClock.frameIndex(durationsMs: d, loop: true, elapsedMs: 0, reducedMotion: false) == 0)
        #expect(FrameClock.frameIndex(durationsMs: d, loop: true, elapsedMs: 250, reducedMotion: false) == 1)
        #expect(FrameClock.frameIndex(durationsMs: d, loop: true, elapsedMs: 700, reducedMotion: false) == 2)
        #expect(FrameClock.frameIndex(durationsMs: d, loop: true, elapsedMs: 800, reducedMotion: false) == 0)
    }

    @Test func oneShotHoldsLastFrame() {
        #expect(FrameClock.frameIndex(durationsMs: [200, 200], loop: false, elapsedMs: 10_000, reducedMotion: false) == 1)
    }

    @Test func reducedMotionPinsFirstFrame() {
        #expect(FrameClock.frameIndex(durationsMs: [200, 200], loop: true, elapsedMs: 250, reducedMotion: true) == 0)
    }

    @Test func durationsBelowMinimumAreRaised() {
        // 10ms frames are treated as 125ms (8 fps cap).
        #expect(FrameClock.frameIndex(durationsMs: [10, 10], loop: true, elapsedMs: 100, reducedMotion: false) == 0)
    }
}

@Suite struct DemoLabelTests {
    private func demoItem() -> InboxItem {
        var demo = item("d")
        demo.isDemo = true
        return demo
    }

    @Test func fixtureItemsAreDemo() {
        #expect(FixtureSimulator.defaultItems().allSatisfy { $0.isDemo })
        #expect(FixtureSimulator().injectEntitlementEvent().isDemo)
    }

    @Test func demoSurvivesPrivacyModeInRowsAndHover() {
        let demo = demoItem()
        #expect(PrivacyText.subtitle(demo, privacy: true) == "Demo · Review request")
        #expect(PrivacyText.subtitle(demo, privacy: false) == "Demo · Review request · secret-org/secret-repo")
        #expect(PrivacyText.subtitle(item("live"), privacy: true) == "Review request")
        let lines = PrivacyText.summary(dataState: .ready, items: [demo], unseenCount: 0, privacy: true, demo: true)
        #expect(lines.first == "Demo data (fixtures)")
        #expect(lines.contains("Demo · Review request"))
        #expect(!lines.joined().contains("secret"))
    }

    @Test func accessibilityLabelNamesDemoAndQuality() {
        let label = AccessibilityText.statusLabel(dataState: .partial, count: 2, demo: true, needsAttention: false)
        #expect(label == "GitHub Pet, Demo data, at least 2 items, some sources unavailable")
        let live = AccessibilityText.statusLabel(dataState: .stale, count: 4, demo: false, needsAttention: true)
        #expect(live == "GitHub Pet, count unknown, data is stale, needs attention")
    }
}

@Suite struct MascotAnimatorTests {
    private let durations: (MascotState) -> [Int] = { $0 == .idle ? [2000, 200, 200, 2000] : [300, 400, 400, 800] }

    private func clip(_ id: String, at start: Date, _ kind: ItemKind = .entitlement) -> EventClipQueue.Clip {
        var queue = EventClipQueue()
        queue.enqueue([InboxEvent(item: item(id, kind))], now: start, playable: true)
        return queue.active!
    }

    @Test func clipLastsTwoSecondsFromItsStart() {
        let c = clip("a", at: t0)
        #expect(c.startedAt == t0)
        #expect(c.endsAt == t0 + 1.9, "attention: the 1.9 s double wave")
        #expect(c.state == .attention)
        #expect(clip("b", at: t0, .ciFailure).state == .urgent)
    }

    @Test func everyNewClipReplaysFromFirstFrameEvenInAttentionMood() {
        let first = clip("a", at: t0)
        let p1 = MascotAnimator.pose(mood: .attention, clip: first, now: t0 + 0.1, reducedMotion: false,
                                     idleEpoch: t0, durationsMs: durations)
        #expect(p1.state == .attention && p1.frame == 0)
        #expect(abs((p1.clipElapsed ?? -1) - 0.1) < 0.001)
        // Clip over: attention mood holds its static pose (no re-animation from mood alone).
        let settled = MascotAnimator.pose(mood: .attention, clip: nil, now: t0 + 5, reducedMotion: false,
                                          idleEpoch: t0, durationsMs: durations)
        #expect(settled.frame == nil)
        // A second event while still in attention plays again from frame 0.
        let second = clip("b", at: t0 + 10)
        let p2 = MascotAnimator.pose(mood: .attention, clip: second, now: t0 + 10.05, reducedMotion: false,
                                     idleEpoch: t0, durationsMs: durations)
        #expect(p2.frame == 0)
        let late = MascotAnimator.pose(mood: .attention, clip: second, now: t0 + 11.5, reducedMotion: false,
                                       idleEpoch: t0, durationsMs: durations)
        #expect(late.frame == 3)
    }

    @Test func suppressedClipsMeanStaticMoodPoses() {
        for mood in [MascotState.attention, .urgent] {
            let pose = MascotAnimator.pose(mood: mood, clip: nil, now: t0, reducedMotion: false,
                                           idleEpoch: t0, durationsMs: durations)
            #expect(pose == MascotPose(state: mood, frame: nil, clipElapsed: nil))
        }
    }

    @Test func reducedMotionIgnoresClipAndIdleLoop() {
        let pose = MascotAnimator.pose(mood: .idle, clip: clip("a", at: t0), now: t0 + 0.5, reducedMotion: true,
                                       idleEpoch: t0, durationsMs: durations)
        #expect(pose == MascotPose(state: .idle, frame: nil, clipElapsed: nil))
    }

    @Test func idleLoopsOnTheSuppliedClock() {
        func frame(_ seconds: Double) -> Int? {
            MascotAnimator.pose(mood: .idle, clip: nil, now: t0 + seconds, reducedMotion: false,
                                idleEpoch: t0, durationsMs: durations).frame
        }
        #expect(frame(0) == 0)
        #expect(frame(2.1) == 1)
        #expect(frame(2.3) == 2)
        #expect(frame(4.5) == 0, "loop wraps after 4.4 s")
    }

    @Test func clipTimingUsesTheSameClockAsTheQueue() {
        // A QA clock offset shifts both the clip and "now"; a clip is never seen as before
        // its start or long finished just because of the offset.
        let offset: TimeInterval = 3600
        let c = clip("a", at: t0 + offset)
        let pose = MascotAnimator.pose(mood: .attention, clip: c, now: t0 + offset + 0.2, reducedMotion: false,
                                       idleEpoch: t0, durationsMs: durations)
        #expect(abs((pose.clipElapsed ?? -1) - 0.2) < 0.001)
        let unshifted = MascotAnimator.pose(mood: .attention, clip: c, now: t0 + 0.2, reducedMotion: false,
                                            idleEpoch: t0, durationsMs: durations)
        #expect(unshifted.clipElapsed == nil, "a mismatched clock does not produce negative clip time")
    }
}

@Suite struct CompactSummaryTests {
    private let items = (0..<3).map {
        InboxItem(id: "i\($0)", kind: .reviewRequest, repository: "secret-org/repo", title: "Secret title",
                  url: nil, updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func atMostTwoLinesAndNoDetails() {
        for state in [DataState.ready, .partial, .stale, .loading, .empty, .ghMissing, .unauthenticated, .error("offline")] {
            for demo in [false, true] {
                let lines = PrivacyText.compactSummary(dataState: state, items: items, unseenCount: 1, demo: demo)
                #expect(lines.count == 2, "\(state)")
                #expect(!lines.joined().lowercased().contains("secret"), "no names or titles")
                if demo { #expect(lines[0] == "Demo data (fixtures)") }
            }
        }
    }

    @Test func countQualityStaysExplicit() {
        func quality(_ state: DataState) -> String {
            PrivacyText.compactSummary(dataState: state, items: items, unseenCount: 1)[0]
        }
        #expect(quality(.ready) == "3 items · 1 new")
        #expect(quality(.partial) == "3+ items · \(DataState.partial.statusText)")
        #expect(quality(.stale) == DataState.stale.statusText)
        #expect(quality(.error("offline")) == DataState.error("offline").statusText)
        #expect(quality(.loading) == DataState.loading.statusText)
        #expect(quality(.unauthenticated) == DataState.unauthenticated.statusText)
    }
}

@Suite struct MascotBadgeCapTests {
    @Test func mascotCapsAt99PlusAndKeepsSmallerCountsExact() {
        #expect(MascotPolicy.mascotBadge(dataState: .ready, count: 99) == "99")
        #expect(MascotPolicy.mascotBadge(dataState: .ready, count: 100) == "99+")
        #expect(MascotPolicy.mascotBadge(dataState: .ready, count: 1234) == "99+")
        #expect(MascotPolicy.mascotBadge(dataState: .partial, count: 99) == "99+", "partial 99 is already 99+")
        #expect(MascotPolicy.mascotBadge(dataState: .partial, count: 150) == "99+")
        #expect(MascotPolicy.mascotBadge(dataState: .stale, count: 500) == "?")
        #expect(MascotPolicy.mascotBadge(dataState: .empty, count: 0) == nil)
    }

    @Test func inboxAndAccessibilityKeepTheFullCount() {
        #expect(MascotPolicy.badge(dataState: .ready, count: 150) == "150")
        #expect(MascotPolicy.badge(dataState: .partial, count: 150) == "150+")
        let label = AccessibilityText.statusLabel(dataState: .ready, count: 150, demo: false, needsAttention: false)
        #expect(label.contains("150"))
    }
}
