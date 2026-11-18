import Foundation
import Testing
@testable import GitHubPetCore

/// #9 MED-1 (QA, PR71 0ba1d3c): announce only when a reason is gained, or when checks fail on a
/// new head commit. Losing a reason, or regaining one on the same head, never announces. One row
/// per PR across overlapping inclusions. Uses only the parser and engine, so it also runs
/// against the earlier head as the FAIL-before.
private let headA = String(repeating: "a", count: 40)
private let headB = String(repeating: "b", count: 40)
private let viewerA = try! ScopeAccount(viewerID: "U_fixture_A")
private let firstSubmission = "2026-11-14T09:00:00Z"
private let secondSubmission = "2026-11-14T09:05:00Z"
private let thirdSubmission = "2026-11-14T09:10:00Z"

private func pr(changes: Bool = false, conflict: Bool = false, checks: String = "SUCCESS", head: String = headA,
                id: String = "PR_med1", review: String? = "PRR_round1", submittedAt: String = firstSubmission) -> [String: Any] {
    ["__typename": "PullRequest", "id": id, "number": 9, "title": "Fixture authored",
     "reviews": ["nodes": changes ? (review.map { [["id": $0, "submittedAt": submittedAt]] } ?? []) : []],
     "url": "https://github.com/example/pet/pull/9", "updatedAt": "2026-11-14T10:00:00Z",
     "repository": ["nameWithOwner": "example/pet"], "isDraft": false,
     "reviewDecision": changes ? "CHANGES_REQUESTED" : "REVIEW_REQUIRED",
     "mergeable": conflict ? "CONFLICTING" : "MERGEABLE",
     "commits": ["nodes": [["commit": ["oid": head, "statusCheckRollup": ["state": checks]]]]]]
}

private func result(_ plan: ScopeQueryPlan, _ authoredByAlias: (ScopeQueryPlan.Search) -> [Any]) throws -> ScopedPollResult {
    var data: [String: Any] = ["viewer": ["id": viewerA.viewerID, "login": "fixture-user"]]
    for (i, target) in plan.scope.targets.enumerated() {
        data["target\(i)"] = target.kind == .organization
            ? ["__typename": "Organization", "id": "O_fixture", "login": target.owner]
            : ["__typename": "Repository", "id": "R_fixture", "nameWithOwner": "\(target.owner)/\(target.name!)"]
    }
    for search in plan.searches {
        let rows = search.kind == .authoredPullRequest ? authoredByAlias(search) : []
        data[search.alias] = ["issueCount": rows.count, "nodes": rows, "pageInfo": ["hasNextPage": false]]
    }
    return ScopedResponseParser.parse(try JSONSerialization.data(withJSONObject: ["data": data]), plan: plan)
}

@Suite struct AuthoredAnnouncementTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Polls one PR state per minute after an empty baseline; returns the event count of each poll.
    private func events(_ states: [[String: Any]]) throws -> [Int] {
        let engine = InboxEngine(), plan = try ScopeQueryPlan()
        engine.apply(try result(plan) { _ in [] }.outcome, now: t0)
        return try states.enumerated().map { minute, state in
            engine.apply(try result(plan) { _ in [state] }.outcome, now: t0 + Double(minute + 1) * 60).count
        }
    }

    @Test func gainingAReasonAnnouncesOnce() throws {
        #expect(try events([pr(changes: true), pr(changes: true), pr(changes: true, checks: "FAILURE"),
                            pr(changes: true, checks: "FAILURE"), pr(changes: true, conflict: true, checks: "FAILURE")])
                == [1, 0, 1, 0, 1])
    }

    @Test func losingAReasonNeverAnnounces() throws {
        // Checks fixed while changes are still requested.
        #expect(try events([pr(changes: true, checks: "FAILURE"), pr(changes: true)]) == [1, 0])
        // A push turns failing checks into pending.
        #expect(try events([pr(changes: true, checks: "FAILURE"), pr(changes: true, checks: "PENDING", head: headB)]) == [1, 0])
        // Conflict resolved, checks still failing.
        #expect(try events([pr(conflict: true, checks: "FAILURE"), pr(checks: "FAILURE")]) == [1, 0])
    }

    @Test func lossThenRegainOnTheSameHeadStaysSilent() throws {
        #expect(try events([pr(changes: true, checks: "FAILURE"), pr(changes: true), pr(changes: true, checks: "FAILURE")])
                == [1, 0, 0])
        #expect(try events([pr(changes: true), pr(), pr(changes: true)]) == [1, 0, 0],
                "changes requested again for an already-announced PR")
    }

    @Test func checksFailingOnANewHeadAnnouncesOnce() throws {
        #expect(try events([pr(checks: "FAILURE"), pr(checks: "PENDING", head: headB),
                            pr(checks: "FAILURE", head: headB), pr(checks: "FAILURE", head: headB)]) == [1, 0, 1, 0])
    }

    /// #60 follow-up to #9: a later changes-requested round (a new latest changes-requesting review)
    /// announces once. The same review lost and regained, or a push, stays silent.
    /// FAIL before: changes requested announced at most once per PR.
    @Test func aLaterChangesRequestedRoundAnnouncesOnce() throws {
        #expect(try events([pr(changes: true), pr(), pr(changes: true, review: "PRR_round2", submittedAt: secondSubmission),
                            pr(changes: true, head: headB, review: "PRR_round2", submittedAt: secondSubmission)]) == [1, 0, 1, 0])
        #expect(try events([pr(changes: true), pr(), pr(changes: true)]) == [1, 0, 0], "the same review regained")
        #expect(try events([pr(changes: true, review: nil), pr(changes: true, review: nil)]) == [1, 0],
                "no visible review: one changes-requested event, as before")
    }

    @Test func reviewVisibilityChangesSeedSilentlyInBothDirections() throws {
        let unavailable = pr(changes: true, review: nil)
        let first = pr(changes: true)
        let second = pr(changes: true, review: "PRR_round2", submittedAt: secondSubmission)
        let third = pr(changes: true, review: "PRR_round3", submittedAt: thirdSubmission)
        #expect(try events([first, unavailable, first, first, second, second]) == [1, 0, 0, 0, 1, 0])
        #expect(try events([unavailable, first, second, unavailable, third, third]) == [1, 0, 1, 0, 0, 0])
        #expect(try events([first, pr(changes: true, checks: "FAILURE", review: nil), first]) == [1, 1, 0])
    }

    @Test func equalAndOlderObservationsDoNotLowerTheWatermark() throws {
        let first = pr(changes: true)
        let equal = pr(changes: true, review: "PRR_equal", submittedAt: firstSubmission)
        let older = pr(changes: true, review: "PRR_older", submittedAt: "2026-11-14T08:00:00Z")
        let stillOlder = pr(changes: true, review: "PRR_intermediate", submittedAt: "2026-11-14T08:30:00Z")
        let later = pr(changes: true, review: "PRR_round2", submittedAt: secondSubmission)
        #expect(try events([first, equal, older, stillOlder, first, later, later]) == [1, 0, 0, 0, 0, 1, 0])
    }

    @Test func restartPreservesUnavailabilityAndThenProvenRoundExactlyOnce() throws {
        let plan = try ScopeQueryPlan()
        let defaults = EphemeralDefaults(name: "authored-round.tests.\(UUID().uuidString)")
        let store = EventBaselineStore(defaults: defaults)
        let key = BaselineKey(source: .githubCLI, identity: .github(viewerA), scope: .everything)
        let engine = InboxEngine()
        engine.apply(try result(plan) { _ in [pr(changes: true)] }.outcome, now: t0)
        let unavailable = try result(plan) { _ in [pr(changes: true, review: nil)] }
        #expect(unavailable.complete && engine.apply(unavailable.outcome, now: t0 + 1).isEmpty)
        store.save(engine.baseline(key: key))
        let raw = try #require(defaults.data(forKey: EventBaselineStore.key))
        let encoded = String(decoding: raw, as: UTF8.self)
        #expect(!encoded.contains("PRR_round1") && !encoded.contains("PR_med1") && !encoded.contains("example/pet"))
        let restored = InboxEngine()
        #expect(try restored.restore(#require(store.load(for: key))))
        let second = try result(plan) { _ in [pr(changes: true, review: "PRR_round2", submittedAt: secondSubmission)] }
        #expect(restored.apply(second.outcome, now: t0 + 2).isEmpty, "first visible evidence after a gap seeds silently")
        store.save(restored.baseline(key: key))
        let again = InboxEngine()
        #expect(try again.restore(#require(store.load(for: key))))
        let third = try result(plan) { _ in [pr(changes: true, review: "PRR_round3", submittedAt: thirdSubmission)] }
        #expect(again.apply(third.outcome, now: t0 + 3).map(\.item.id) == ["authoredPullRequest:PR_med1"])
        #expect(again.apply(third.outcome, now: t0 + 4).isEmpty)
    }

    @Test func degradedPollDoesNotCreateAComparableRound() throws {
        let plan = try ScopeQueryPlan()
        let first = try result(plan) { _ in [pr(changes: true)] }
        let second = try result(plan) { _ in [pr(changes: true, review: "PRR_round2", submittedAt: secondSubmission)] }
        let third = try result(plan) { _ in [pr(changes: true, review: "PRR_round3", submittedAt: thirdSubmission)] }
        for outcome in [FetchOutcome.snapshot(items: second.items, complete: false), .failure(.failed("fixture"))] {
            let engine = InboxEngine()
            engine.apply(first.outcome, now: t0)
            #expect(engine.apply(outcome, now: t0 + 1).isEmpty)
            #expect(engine.apply(second.outcome, now: t0 + 2).isEmpty)
            #expect(engine.apply(third.outcome, now: t0 + 3).count == 1)
        }
    }

    @Test func authoredWatermarksFitTheExistingBaselineBound() throws {
        let engine = InboxEngine()
        let limit = EventBaseline.maximumAuthoredReviewWatermarks
        let items: [InboxItem] = (0...limit).map { index in
            let id = "authoredPullRequest:PR_fixture_\(index)"
            var item = InboxItem(id: id, kind: .authoredPullRequest, repository: "example/pet", title: "Fixture",
                                 url: nil, updatedAt: t0, attentionKeys: [id + "#changes"])
            item.authoredReview = AuthoredAttention.Review(digest: EventBaseline.digest("PRR_fixture_\(index)"),
                                                           submittedAt: t0 - Double(limit - index))
            return item
        }
        engine.apply(.snapshot(items: items, complete: true), now: t0)
        let defaults = EphemeralDefaults(name: "authored-bound.tests.\(UUID().uuidString)")
        let store = EventBaselineStore(defaults: defaults)
        let key = BaselineKey(source: .githubCLI, identity: .github(viewerA), scope: .everything)
        var record = engine.baseline(key: key)
        record.digests = (0..<EventBaseline.maximumDigests).map { EventBaseline.digest("fixture-\($0)") }
        store.save(record)
        let loaded = try #require(store.load(for: key))
        let marks = try #require(loaded.authoredReviewWatermarks)
        #expect(marks.count == limit && marks[EventBaseline.digest(items[0].id)] == nil)
        #expect(marks[EventBaseline.digest(items[limit].id)]?.submittedAt == t0)
    }

    @Test func overlappingInclusionsGiveOneRowAndDisagreementIsPartial() throws {
        let scope = try MonitoringScope(selected: [MonitoringTarget(organization: "example"), MonitoringTarget(repository: "example/pet")])
        let plan = try ScopeQueryPlan(scope: scope, expectedAccount: viewerA)
        let same = try result(plan) { _ in [pr(changes: true)] }
        #expect(same.complete && same.items.filter { $0.kind == .authoredPullRequest }.count == 1)
        let raced = try result(plan) { $0.targetIndex == 0 ? [pr(changes: true)] : [pr(changes: true, checks: "FAILURE")] }
        #expect(raced.items.filter { $0.kind == .authoredPullRequest }.count == 1, "one row per PR")
        #expect(!raced.complete && raced.issues.contains(.inconsistentDuplicate), "disagreeing inclusions are Partial")
        let waitingVsAction = try result(plan) { $0.targetIndex == 0 ? [pr()] : [pr(changes: true)] }
        #expect(!waitingVsAction.complete && waitingVsAction.issues.contains(.inconsistentDuplicate))
    }
}
