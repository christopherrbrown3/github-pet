import Foundation
import Testing
@testable import GitHubPetCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let accountA = try! ScopeAccount(viewerID: "U_baseline_A")
private let accountB = try! ScopeAccount(viewerID: "U_baseline_B")
private let keyA = BaselineKey(source: .githubCLI, identity: .github(accountA), scope: .everything)

@Test func assignmentModeIsPartOfTheBaselineKeyWithoutChangingLegacyAll() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let scopeText = String(decoding: try encoder.encode(MonitoringScope.everything), as: UTF8.self)
    let legacy = EventBaseline.digest("v\(EventBaseline.version)\nc\(ScopeQueryPlan.categoriesVersion)\ngithubCLI\n\(ScopeIdentity.github(accountA).storageSuffix)\n\(scopeText)")
    #expect(keyA.value == legacy)
    let direct = BaselineKey(source: .githubCLI, identity: .github(accountA), scope: .everything, assignmentMode: .direct)
    let selected = try MonitoringScope(selected: [MonitoringTarget(repository: "example/pet")])
    let otherKeys = [keyA,
                     BaselineKey(source: .fixtures, identity: .demo, scope: .everything, assignmentMode: .direct),
                     BaselineKey(source: .githubCLI, identity: .github(accountB), scope: .everything, assignmentMode: .direct),
                     BaselineKey(source: .githubCLI, identity: .github(accountA), scope: selected, assignmentMode: .direct)]
    #expect(!otherKeys.contains(direct))
}

private func item(_ id: String) -> InboxItem {
    InboxItem(id: id, kind: .reviewRequest, repository: "secret-org/secret-repo", title: "Secret title \(id)",
              url: URL(string: "https://github.com/secret-org/secret-repo/pull/1"), updatedAt: t0)
}

/// A session that saw `ids` in a complete snapshot at `t0`, then "quit".
private func savedSession(_ ids: [String], key: BaselineKey = keyA, complete: Bool = true) -> EventBaseline {
    let engine = InboxEngine()
    engine.apply(.snapshot(items: ids.map(item), complete: complete), now: t0)
    return engine.baseline(key: key)
}

/// A relaunched engine resuming `saved`.
private func relaunched(_ saved: EventBaseline) -> InboxEngine {
    let engine = InboxEngine()
    #expect(engine.restore(saved))
    return engine
}

@Suite struct EventBaselineRestartTests {
    @Test func restartWithNothingNewAnnouncesNothing() {
        let engine = relaunched(savedSession(["a", "b"]))
        #expect(engine.state == .loading, "a restored baseline is Loading, never an empty inbox")
        #expect(engine.items.isEmpty && engine.lastSuccess == nil)
        let events = engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0 + 60)
        #expect(events.isEmpty)
        #expect(engine.state == .ready)
    }

    // FAIL before #12: a relaunch re-baselined silently, so an item that arrived while the app
    // was quit was never announced.
    @Test func restartWithOneGenuinelyNewItemAnnouncesItExactlyOnce() {
        let engine = relaunched(savedSession(["a", "b"]))
        let overnight = t0 + 8 * 3600
        let events = engine.apply(.snapshot(items: [item("a"), item("b"), item("c")], complete: true), now: overnight)
        #expect(events.map(\.item.id) == ["c"])
        let again = engine.apply(.snapshot(items: [item("a"), item("b"), item("c")], complete: true), now: overnight + 60)
        #expect(again.isEmpty, "announced once; the next unchanged poll is silent")
    }

    @Test func restoredWindowIsTwentyFourHoursInclusiveAndNeverFuture() {
        let saved = savedSession(["a"])
        let atLimit = relaunched(saved).apply(.snapshot(items: [item("a"), item("n")], complete: true),
                                              now: t0 + InboxEngine.restoredComparableWindow)
        #expect(atLimit.map(\.item.id) == ["n"])
        let tooOld = relaunched(saved)
        #expect(tooOld.apply(.snapshot(items: [item("a"), item("n")], complete: true),
                             now: t0 + InboxEngine.restoredComparableWindow + 1).isEmpty, ">24h record re-baselines silently")
        #expect(tooOld.apply(.snapshot(items: [item("a"), item("n"), item("m")], complete: true),
                             now: t0 + InboxEngine.restoredComparableWindow + 61).map(\.item.id) == ["m"],
                "after the silent re-baseline, later new items announce as usual")
        #expect(relaunched(saved).apply(.snapshot(items: [item("a"), item("n")], complete: true), now: t0 - 60).isEmpty,
                "a record from the future (clock change) is never comparable")
    }

    @Test func incompleteQualitiesRestoreAsLoadingAndRebaselineSilently() {
        let partial = savedSession(["a"], complete: false)
        #expect(partial.quality == .partial && !partial.baselineEstablished)

        let stale = InboxEngine()
        stale.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        stale.markStale()
        let failed = InboxEngine()
        failed.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        failed.apply(.failure(.failed("boom secret-org")), now: t0 + 30)
        let missing = InboxEngine()
        missing.apply(.snapshot(items: [item("a")], complete: true), now: t0)
        missing.apply(.failure(.unauthenticated), now: t0 + 30)

        let records = [partial, stale.baseline(key: keyA), failed.baseline(key: keyA), missing.baseline(key: keyA)]
        #expect(records.map(\.quality) == [.partial, .stale, .error, .unauthenticated])
        for record in records {
            let engine = relaunched(record)
            #expect(engine.state == .loading && engine.state != .empty)
            #expect(engine.baseline(key: keyA).quality == record.quality, "quality survives until the next poll")
            let events = engine.apply(.snapshot(items: [item("a"), item("new")], complete: true), now: t0 + 60)
            #expect(events.isEmpty, "\(record.quality) record re-baselines silently")
            // Already-seen IDs from the partial poll stay known, as in-session.
            #expect(engine.apply(.snapshot(items: [item("a"), item("new"), item("next")], complete: true),
                                 now: t0 + 120).map(\.item.id) == ["next"])
        }
    }

    @Test func restoreIsRefusedOnceTheSessionHasData() {
        let engine = InboxEngine()
        engine.apply(.snapshot(items: [item("x")], complete: true), now: t0)
        #expect(!engine.restore(savedSession(["a"])))
        #expect(engine.apply(.snapshot(items: [item("x"), item("a")], complete: true), now: t0 + 60).map(\.item.id) == ["a"])
    }

    @Test func resetForgetsTheRestoredBaseline() {
        let engine = relaunched(savedSession(["a"]))
        engine.reset()
        #expect(engine.apply(.snapshot(items: [item("a"), item("n")], complete: true), now: t0 + 60).isEmpty)
    }

    @Test func persistedRecordIsBoundedAndKeepsTheNewestIDs() {
        let engine = InboxEngine()
        engine.apply(.snapshot(items: (0..<1500).map { item("id\($0)") }, complete: true), now: t0)
        let record = engine.baseline(key: keyA)
        #expect(record.digests.count == EventBaseline.maximumDigests)
        let defaults = EphemeralDefaults(name: "baseline.bounded.\(UUID().uuidString)")
        EventBaselineStore(defaults: defaults).save(record)
        let data = defaults.data(forKey: EventBaselineStore.key)
        #expect(data.map { $0.count <= EventBaselineStore.maximumRecordBytes } == true)
        #expect(EventBaselineStore(defaults: defaults).load(for: keyA) == record)
        let relaunch = relaunched(record)
        #expect(relaunch.apply(.snapshot(items: [item("id1499"), item("id0")], complete: true), now: t0 + 60).map(\.item.id) == ["id0"],
                "only the oldest IDs beyond capacity are forgotten")
    }
}

@Suite struct EventBaselineStoreTests {
    private func store() -> (EventBaselineStore, UserDefaults) {
        let defaults = EphemeralDefaults(name: "baseline.tests.\(UUID().uuidString)")
        return (EventBaselineStore(defaults: defaults), defaults)
    }

    // FAIL before (#60): every poll moved lastSuccess, so every poll rewrote the preference.
    @Test func unchangedContentIsNotRewrittenEveryPoll() throws {
        let (store, defaults) = store()
        let sentinel = Data("not rewritten".utf8)
        var record = savedSession(["a", "b"])
        store.save(record)
        defaults.set(sentinel, forKey: EventBaselineStore.key)
        func saved(_ change: (inout EventBaseline) -> Void) -> Bool {
            change(&record)
            store.save(record)
            defer { defaults.set(sentinel, forKey: EventBaselineStore.key) }
            return defaults.data(forKey: EventBaselineStore.key) != sentinel
        }
        #expect(!saved { _ in }, "identical record")
        #expect(!saved { $0.lastSuccess = $0.lastSuccess!.addingTimeInterval(120) }, "a routine poll only moves lastSuccess")
        #expect(!saved { $0.lastSuccess = $0.lastSuccess!.addingTimeInterval(120) })
        #expect(saved { $0.lastSuccess = $0.lastSuccess!.addingTimeInterval(10 * 60) },
                "the success time is refreshed at least every 10 minutes")
        #expect(saved { $0.digests.append(EventBaseline.digest("c")) }, "a newly seen ID is saved at once")
        #expect(saved { $0.quality = .partial }, "a quality change is saved at once")
        #expect(saved { $0.baselineEstablished = false })
        #expect(saved { $0.lastSuccess = $0.lastSuccess!.addingTimeInterval(-60) }, "a clock moved back is saved")
        #expect(saved { $0.lastSuccess = nil })
        store.reset()
        #expect(saved { _ in }, "after a reset the next save always writes")
    }

    @Test func roundTripsForTheSameSession() {
        let (store, _) = store()
        let saved = savedSession(["a", "b"])
        store.save(saved)
        #expect(store.load(for: keyA) == saved)
    }

    @Test func recordContainsOnlyDigestsNoItemData() throws {
        let (store, defaults) = store()
        store.save(savedSession(["reviewRequest:PR_secretNode"]))
        let data = try #require(defaults.data(forKey: EventBaselineStore.key))
        let text = String(decoding: data, as: UTF8.self)
        for leak in ["secret", "Secret", "PR_", "reviewRequest", "U_baseline", "github.com", "https"] {
            #expect(!text.contains(leak), "record leaks \(leak)")
        }
    }

    @Test func keyChangesWithSourceAccountAndScope() throws {
        let selected = try MonitoringScope(selected: [MonitoringTarget(organization: "acme")])
        let keys = [
            keyA,
            BaselineKey(source: .githubCLI, identity: .github(accountB), scope: .everything),
            BaselineKey(source: .githubCLI, identity: .github(accountA), scope: selected),
            BaselineKey(source: .fixtures, identity: .github(accountA), scope: .everything),
            BaselineKey(source: .fixtures, identity: .demo, scope: .everything),
        ]
        #expect(Set(keys.map(\.value)).count == keys.count)
        #expect(BaselineKey(source: .githubCLI, identity: .github(accountA), scope: .everything) == keyA)
    }

    @Test func otherAccountOrScopeRecordIsDiscardedNotLeaked() throws {
        let (store, defaults) = store()
        store.save(savedSession(["a"]))
        let keyB = BaselineKey(source: .githubCLI, identity: .github(accountB), scope: .everything)
        #expect(store.load(for: keyB) == nil)
        #expect(defaults.object(forKey: EventBaselineStore.key) == nil, "A's record is removed, not kept for B")
        // A -> B -> A: A starts fresh too (single slot).
        #expect(store.load(for: keyA) == nil)
        store.save(savedSession(["a"]))
        let narrowed = BaselineKey(source: .githubCLI, identity: .github(accountA),
                                   scope: try MonitoringScope(selected: [MonitoringTarget(organization: "acme")]))
        #expect(store.load(for: narrowed) == nil)
    }

    @Test func corruptOversizedAndOtherVersionRecordsAreDiscarded() throws {
        var wrongVersion = savedSession(["a"]); wrongVersion.version = 2
        var badDigest = savedSession(["a"]); badDigest.digests = ["not-a-digest"]
        var duplicate = savedSession(["a"]); duplicate.digests += duplicate.digests
        var tooMany = savedSession(["a"]); tooMany.digests = (0..<1025).map { EventBaseline.digest("\($0)") }
        let encoded = try [wrongVersion, badDigest, duplicate, tooMany].map { try JSONEncoder().encode($0) }
        let oversized = Data(repeating: 0x20, count: EventBaselineStore.maximumRecordBytes + 1)
        let payloads: [Any] = encoded + [Data("{not json".utf8), oversized, "a string", 42,
                                          Data(#"{"version":1}"#.utf8)]
        for payload in payloads {
            let (store, defaults) = store()
            defaults.set(payload, forKey: EventBaselineStore.key)
            #expect(store.load(for: keyA) == nil)
            #expect(defaults.object(forKey: EventBaselineStore.key) == nil, "discarded record is removed")
        }
        // Invalid records are never written either.
        let (store, defaults) = store()
        store.save(badDigest)
        #expect(defaults.object(forKey: EventBaselineStore.key) == nil)
    }

    @Test func corruptRecordMeansFreshSilentBaseline() {
        let (store, defaults) = store()
        defaults.set(Data("garbage".utf8), forKey: EventBaselineStore.key)
        let engine = InboxEngine()
        if let saved = store.load(for: keyA) { engine.restore(saved) }
        #expect(engine.state == .loading)
        #expect(engine.apply(.snapshot(items: [item("a"), item("b")], complete: true), now: t0).isEmpty)
    }
}
