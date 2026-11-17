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

private func pr(changes: Bool = false, conflict: Bool = false, checks: String = "SUCCESS", head: String = headA,
                id: String = "PR_med1") -> [String: Any] {
    ["__typename": "PullRequest", "id": id, "number": 9, "title": "Fixture authored",
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
