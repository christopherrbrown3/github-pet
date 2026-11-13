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

    @Test func pollsFurtherApartThanStaleAfterAreNotComparable() {
        // Regression: no refreshFreshness() call in between (e.g. poll timer fires first after sleep).
        let engine = InboxEngine(staleAfter: 600)
        engine.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        #expect(engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0 + 601).isEmpty)
        #expect(engine.apply(.snapshot(items: [item("a"), item("b"), item("c")], complete: true), now: t0 + 660)
            .map(\.item.id) == ["c"])
    }

    @Test func clockGoingBackwardsIsNotComparable() {
        let engine = InboxEngine(staleAfter: 600)
        engine.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        #expect(engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0 - 60).isEmpty)
    }

    @Test func evictionDuringASnapshotNeverReportsExistingIDs() {
        // Regression: capacity 3, baseline [a, b, c], then [d, a, b] used to report all three.
        let engine = InboxEngine(trackerCapacity: 3)
        engine.apply(.snapshot(items: [item("a"), item("b"), item("c")], complete: true), now: t0)
        let events = engine.apply(.snapshot(items: [item("d"), item("a"), item("b")], complete: true), now: t0 + 60)
        #expect(events.map(\.item.id) == ["d"])
    }

    @Test func snapshotLargerThanTrackerDoesNotReplayWhenUnchanged() {
        let engine = InboxEngine(trackerCapacity: 2)
        let many = (1...5).map { item("i\($0)", minutesAgo: Double($0)) }
        engine.apply(.snapshot(items: many, complete: true), now: t0)
        for minute in 1...3 {
            #expect(engine.apply(.snapshot(items: many, complete: true), now: t0 + Double(minute * 60)).isEmpty)
        }
    }

    @Test func resetClearsItemsStateAndTimestamp() {
        let engine = InboxEngine()
        engine.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        engine.reset()
        #expect(engine.items.isEmpty)
        #expect(engine.state == .loading)
        #expect(engine.lastSuccess == nil)
        #expect(!engine.baselineEstablished)
        // A failing first fetch from the new source shows no rows from the old one.
        engine.apply(.failure(.unauthenticated), now: t0 + 1)
        #expect(engine.items.isEmpty)
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

    @Test func partialPollsStayPartialUntilTurnedOff() {
        // Regression #21: the periodic fixture poll must not flip partial back to complete.
        let simulator = FixtureSimulator()
        let engine = InboxEngine()
        engine.apply(simulator.poll(), now: t0)
        simulator.partialPolls = true
        for poll in 1...3 {
            guard case .snapshot(let items, false) = simulator.poll() else {
                Issue.record("expected partial snapshot")
                return
            }
            #expect(!items.contains { $0.kind == .assignedIssue })
            engine.apply(simulator.poll(), now: t0 + Double(poll * 30))
            #expect(engine.state == .partial)
            #expect(MascotPolicy.badge(dataState: engine.state, count: engine.items.count) == "2+")
        }
        simulator.partialPolls = false
        engine.apply(simulator.poll(), now: t0 + 120)
        #expect(engine.state == .ready)
    }

    @Test func fixtureLinksAreSafe() {
        for item in FixtureSimulator.defaultItems() {
            #expect(SafeLink.validated(item.url) != nil)
        }
        #expect(SafeLink.validated(FixtureSimulator().injectEntitlementEvent().url) != nil)
    }
}

@Suite struct SourceGenerationTests {
    @Test func staleFetchFromEarlierSessionIsDroppedAndDoesNotBlockTheNewOne() {
        // GitHub CLI (fetch running) → Fixtures → GitHub CLI.
        var generations = SourceGenerations()
        generations.switchSource()
        let first = generations.beginFetch()
        #expect(first != nil)
        let duplicate = generations.beginFetch()
        #expect(duplicate == nil, "one fetch per session at a time")
        generations.switchSource()
        generations.switchSource()
        let second = generations.beginFetch()
        #expect(second != nil, "an obsolete in-flight fetch must not block the new session")
        let applyOld = generations.finishFetch(first!)
        #expect(applyOld == false, "old session's result is discarded")
        let blocked = generations.beginFetch()
        #expect(blocked == nil, "finishing the old fetch does not clear the new one")
        let applyNew = generations.finishFetch(second!)
        #expect(applyNew)
        let next = generations.beginFetch()
        #expect(next != nil)
    }

    @Test func switchingSourcesNeverLeaksRowsBetweenSessions() {
        // Simulates the app: Demo fixtures, then a live session whose first fetch is slow,
        // then another switch; the late result must not appear in the newest session.
        var generations = SourceGenerations()
        let engine = InboxEngine()
        generations.switchSource()
        engine.reset()
        engine.apply(FixtureSimulator().poll(), now: t0)
        #expect(engine.items.allSatisfy { $0.isDemo })

        generations.switchSource()
        engine.reset()
        #expect(engine.items.isEmpty, "no Demo rows shown as live data")
        let liveFetch = generations.beginFetch()!

        generations.switchSource()
        engine.reset()
        let lateResult = FetchOutcome.snapshot(items: [item("other-account")], complete: true)
        if generations.finishFetch(liveFetch) { engine.apply(lateResult, now: t0 + 5) }
        #expect(engine.items.isEmpty)
        #expect(engine.state == .loading)
    }
}

@Suite struct WorkflowFailureFixtureTests {
    @Test func injectedWorkflowFailureIsUniqueDemoAndUrgent() {
        var counter = 0
        let simulator = FixtureSimulator(makeID: { counter += 1; return "w\(counter)" })
        let engine = InboxEngine()
        engine.apply(simulator.poll(), now: t0)
        let failure = simulator.injectWorkflowFailure(now: t0)
        let events = engine.apply(simulator.poll(), now: t0 + 1)
        #expect(events.map(\.item.id) == [failure.id])
        #expect(events.first?.severity == .critical)
        #expect(failure.isDemo)
        #expect(SafeLink.validated(failure.url) != nil)
        #expect(MascotPolicy.state(dataState: engine.state, items: engine.items, unseenCount: 0,
                                   alertsAllowed: false) == .urgent)
        #expect(simulator.injectWorkflowFailure(now: t0).id != failure.id)
    }
}

@Suite struct AccountSessionTests {
    @Test func firstAccountAndFailedPollsAreNotChanges() {
        var watch = AccountWatch()
        let first = watch.observe("first-user")
        let failed = watch.observe(nil)   // a poll that failed before identifying the account
        let same = watch.observe("first-user")
        #expect(!first && !failed && !same)
        #expect(watch.account == "first-user")
        let switched = watch.observe("second-user")
        #expect(switched)
        watch.reset()
        let afterReset = watch.observe("third-user")
        #expect(!afterReset, "a source switch already started a fresh session")
    }

    @Test func switchingAccountsStartsAFreshBaselineWithoutEvents() {
        var watch = AccountWatch()
        let engine = InboxEngine()
        var unseen = UnseenItems()
        func poll(_ account: String, _ items: [InboxItem], at now: Date) -> [InboxEvent] {
            if watch.observe(account) {
                engine.reset()
                unseen.removeAll()
            }
            let outcome = FetchOutcome.snapshot(items: items, complete: true)
            let events = engine.apply(outcome, now: now)
            unseen.record(events)
            unseen.reconcile(after: outcome, items: engine.items)
            return events
        }
        #expect(poll("first-user", [item("a")], at: t0).isEmpty)
        #expect(poll("first-user", [item("a"), item("b")], at: t0 + 60).map(\.item.id) == ["b"])
        // `gh auth switch`: the second account's existing items are its baseline, not news.
        #expect(poll("second-user", [item("c"), item("d")], at: t0 + 120).isEmpty)
        #expect(unseen.ids.isEmpty, "unread markers from the first account are dropped")
        #expect(engine.items.map(\.id) == ["c", "d"])
        #expect(poll("second-user", [item("c"), item("d"), item("e")], at: t0 + 180).map(\.item.id) == ["e"])
    }
}

@Suite struct UnseenItemsTests {
    private func marked(_ ids: String...) -> UnseenItems {
        var unseen = UnseenItems()
        unseen.record(ids.map { InboxEvent(item: item($0)) })
        return unseen
    }

    @Test func partialSnapshotKeepsMarkersForMissingItems() {
        var unseen = marked("a", "b")
        // The source holding "b" failed this poll.
        unseen.reconcile(after: .snapshot(items: [item("a")], complete: false), items: [item("a")])
        #expect(unseen.ids == ["a", "b"])
        unseen.reconcile(after: .failure(.failed("offline")), items: [item("a")])
        #expect(unseen.ids == ["a", "b"])
        // Recovery: "b" is back, still unread, with no new event needed.
        unseen.reconcile(after: .snapshot(items: [item("a"), item("b")], complete: true),
                         items: [item("a"), item("b")])
        #expect(unseen.ids == ["a", "b"])
    }

    @Test func completeSnapshotPrunesItemsThatAreGone() {
        var unseen = marked("a", "b")
        unseen.reconcile(after: .snapshot(items: [item("a")], complete: true), items: [item("a")])
        #expect(unseen.ids == ["a"])
    }
}
