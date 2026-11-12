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
        for state in [DataState.loading, .error("x"), .ghMissing, .unauthenticated] {
            #expect(MascotPolicy.badge(dataState: state, count: 0) == nil)
        }
        #expect(MascotPolicy.badge(dataState: .partial, count: 0) == "0+")
        #expect(MascotPolicy.badge(dataState: .partial, count: 2) == "2+")
        #expect(MascotPolicy.badge(dataState: .ready, count: 3) == "3")
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
        #expect(queue.tick(now: t0 + EventClipQueue.clipDuration) == nil)
        #expect(queue.tick(now: t0 + 60) == nil)
    }

    @Test func notPlayableQueuesNothing() {
        var queue = EventClipQueue()
        queue.enqueue([event("a")], now: t0, playable: false)
        #expect(queue.active == nil)
        #expect(queue.pending.isEmpty)
    }

    @Test func duplicatesIgnoredAndPendingBounded() {
        var queue = EventClipQueue()
        queue.enqueue([event("a"), event("a")], now: t0, playable: true)
        queue.enqueue([event("a")], now: t0, playable: true)
        #expect(queue.pending.isEmpty)
        queue.enqueue((1...10).map { event("e\($0)") }, now: t0, playable: true)
        #expect(queue.pending.count == EventClipQueue.maxPending)
    }

    @Test func criticalPreemptsActionable() {
        var queue = EventClipQueue()
        queue.enqueue([event("a")], now: t0, playable: true)
        queue.enqueue([event("boom", .ciFailure)], now: t0 + 0.5, playable: true)
        #expect(queue.active?.event.item.id == "boom")
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
