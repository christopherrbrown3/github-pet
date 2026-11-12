import Foundation
import Testing
@testable import GitHubPetCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func item(_ id: String, _ kind: ItemKind = .reviewRequest, minutesAgo: Double = 0) -> InboxItem {
    InboxItem(id: id, kind: kind, repository: "example/repo", title: "Title \(id)",
              url: URL(string: "https://github.com/example/repo/pull/1"),
              updatedAt: t0.addingTimeInterval(-minutesAgo * 60))
}

@Suite struct EventTrackerTests {
    @Test func firstObservationBeforeBaselineIsNotReported() {
        var tracker = EventTracker()
        #expect(tracker.observe("a", comparableSnapshot: true) == false)
        #expect(tracker.contains("a"))
    }

    @Test func newIDAfterBaselineIsReportedOnce() {
        var tracker = EventTracker()
        tracker.seed(["a"])
        #expect(tracker.observe("b", comparableSnapshot: true) == true)
        #expect(tracker.observe("b", comparableSnapshot: true) == false)
        #expect(tracker.observe("a", comparableSnapshot: true) == false)
    }

    @Test func nonComparableSnapshotRecordsSilently() {
        var tracker = EventTracker()
        tracker.seed([])
        #expect(tracker.observe("x", comparableSnapshot: false) == false)
        #expect(tracker.observe("x", comparableSnapshot: true) == false)
    }

    @Test func emptyIDIsIgnored() {
        var tracker = EventTracker()
        tracker.seed([])
        #expect(tracker.observe("", comparableSnapshot: true) == false)
        #expect(tracker.count == 0)
    }

    @Test func capacityIsBoundedAndEvictsOldestFirst() {
        var tracker = EventTracker(capacity: 3)
        tracker.seed(["a", "b", "c"])
        _ = tracker.observe("a", comparableSnapshot: true) // refresh "a"
        #expect(tracker.observe("d", comparableSnapshot: true) == true)
        #expect(tracker.count == 3)
        #expect(tracker.contains("a"))
        #expect(!tracker.contains("b"))
    }
}

@Suite struct InboxEngineTests {
    @Test func firstSnapshotEstablishesBaselineWithoutEvents() {
        let engine = InboxEngine()
        let events = engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0)
        #expect(events.isEmpty)
        #expect(engine.baselineEstablished)
        #expect(engine.state == .ready)
        #expect(engine.items.count == 2)
    }

    @Test func unchangedPollNeverRetriggers() {
        let engine = InboxEngine()
        engine.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        for minute in 1...5 {
            let events = engine.apply(.snapshot(items: [item("a")], complete: true), now: t0 + Double(minute * 60))
            #expect(events.isEmpty)
        }
    }

    @Test func genuinelyNewItemFiresExactlyOnce() {
        let engine = InboxEngine()
        engine.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        let first = engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0 + 60)
        #expect(first.map(\.item.id) == ["b"])
        let second = engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0 + 120)
        #expect(second.isEmpty)
    }

    @Test func itemThatDisappearsAndReturnsDoesNotReplay() {
        let engine = InboxEngine()
        engine.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        engine.apply(.snapshot(items: [], complete: true), now: t0 + 60)
        #expect(engine.state == .empty)
        #expect(engine.apply(.snapshot(items: [item("a")], complete: true), now: t0 + 120).isEmpty)
    }

    @Test func reconnectAfterErrorDoesNotReplayEvenNewItems() {
        let engine = InboxEngine()
        engine.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        engine.apply(.failure(.failed("offline")), now: t0 + 60)
        #expect(engine.state == .error("offline"))
        #expect(engine.items.map(\.id) == ["a"], "last known items are kept for display")
        let recovered = engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0 + 120)
        #expect(recovered.isEmpty)
        // Once comparable again, a later new item fires normally.
        let later = engine.apply(.snapshot(items: [item("a"), item("b"), item("c")], complete: true), now: t0 + 180)
        #expect(later.map(\.item.id) == ["c"])
    }

    @Test func staleRecoveryDoesNotReplay() {
        let engine = InboxEngine(staleAfter: 600)
        engine.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        #expect(engine.refreshFreshness(now: t0 + 599) == false)
        #expect(engine.refreshFreshness(now: t0 + 600))
        #expect(engine.state == .stale)
        #expect(engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0 + 700).isEmpty)
        #expect(engine.state == .ready)
    }

    @Test func partialSnapshotsNeverProduceEventsAndAreNotEmpty() {
        let engine = InboxEngine()
        engine.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        let partial = engine.apply(.snapshot(items: [], complete: false), now: t0 + 60)
        #expect(partial.isEmpty)
        #expect(engine.state == .partial)
        #expect(!engine.state.countIsKnown)
        // The snapshot after a partial is not comparable either.
        #expect(engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0 + 120).isEmpty)
    }

    @Test func partialFirstSnapshotDoesNotEstablishBaseline() {
        let engine = InboxEngine()
        engine.apply(.snapshot(items: [item("a")], complete: false), now: t0)
        #expect(!engine.baselineEstablished)
        #expect(engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0 + 60).isEmpty)
        #expect(engine.baselineEstablished)
    }

    @Test func authAndMissingFailuresMapToDistinctStates() {
        let engine = InboxEngine()
        engine.apply(.failure(.ghMissing), now: t0)
        #expect(engine.state == .ghMissing)
        engine.apply(.failure(.unauthenticated), now: t0)
        #expect(engine.state == .unauthenticated)
        #expect(!engine.state.countIsKnown)
        #expect(engine.state.hint == "Run: gh auth login")
    }

    @Test func dedupeKeepsNewestPerStableID() {
        let old = item("a", minutesAgo: 10)
        var newer = item("a", minutesAgo: 1)
        newer.title = "newer"
        let result = InboxEngine.dedupe([old, item("b", minutesAgo: 5), newer, item("")])
        #expect(result.map(\.id) == ["a", "b"])
        #expect(result.first?.title == "newer")
    }

    @Test func resetBaselineReseedsSilently() {
        let engine = InboxEngine()
        engine.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        engine.resetBaseline()
        #expect(engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0 + 60).isEmpty)
    }
}

@Suite struct FixtureSimulatorTests {
    @Test func injectedEntitlementFiresExactlyOneUniqueEvent() {
        var counter = 0
        let simulator = FixtureSimulator(makeID: { counter += 1; return "id\(counter)" })
        let engine = InboxEngine()
        engine.apply(simulator.poll(), now: t0)
        let injected = simulator.injectEntitlementEvent(now: t0)
        let events = engine.apply(simulator.poll(), now: t0 + 1)
        #expect(events.map(\.item.id) == [injected.id])
        #expect(injected.kind == .entitlement)
        #expect(engine.apply(simulator.poll(), now: t0 + 2).isEmpty, "replaying the snapshot is silent")
        let second = simulator.injectEntitlementEvent(now: t0 + 3)
        #expect(second.id != injected.id)
        #expect(engine.apply(simulator.poll(), now: t0 + 4).map(\.item.id) == [second.id])
    }

    @Test func eventInjectedWhileDisconnectedIsNotReplayedOnReconnect() {
        let simulator = FixtureSimulator()
        let engine = InboxEngine()
        engine.apply(simulator.poll(), now: t0)
        simulator.disconnect()
        #expect(engine.apply(simulator.poll(), now: t0 + 1).isEmpty)
        simulator.injectEntitlementEvent(now: t0 + 2)
        simulator.reconnect()
        #expect(engine.apply(simulator.poll(), now: t0 + 3).isEmpty)
        #expect(engine.items.contains { $0.kind == .entitlement })
    }

    @Test func partialPollIsOneShot() {
        let simulator = FixtureSimulator()
        simulator.nextPoll = .partial
        guard case .snapshot(let items, false) = simulator.poll() else {
            Issue.record("expected partial snapshot")
            return
        }
        #expect(!items.contains { $0.kind == .assignedIssue })
        guard case .snapshot(_, true) = simulator.poll() else {
            Issue.record("expected complete snapshot")
            return
        }
    }

    @Test func fixtureLinksAreSafe() {
        for item in FixtureSimulator.defaultItems() {
            #expect(SafeLink.validated(item.url) != nil)
        }
        #expect(SafeLink.validated(FixtureSimulator().injectEntitlementEvent().url) != nil)
    }
}
