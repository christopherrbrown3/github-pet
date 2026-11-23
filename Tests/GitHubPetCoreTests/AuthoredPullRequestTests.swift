import Foundation
import Testing
@testable import GitHubPetCore

private let accountA = try! ScopeAccount(viewerID: "U_fixture_A")
private let oidA = String(repeating: "a", count: 40)
private let oidB = String(repeating: "b", count: 40)

private func authored(_ id: String = "PR_authored_1", repo: String = "example/pet", number: Int = 7,
                      title: String = "Secret authored title", updatedAt: String = "2026-11-14T10:00:00Z",
                      draft: Any = false, decision: Any = NSNull(), mergeable: Any = "MERGEABLE",
                      rollup: Any? = ["state": "SUCCESS"], oid: Any = oidA, commits: Any? = nil,
                      reviews: Any = ["nodes": []]) -> [String: Any] {
    var commit: [String: Any] = ["oid": oid]
    if let rollup { commit["statusCheckRollup"] = rollup }
    return ["__typename": "PullRequest", "id": id, "number": number, "title": title,
            "url": "https://github.com/\(repo)/pull/\(number)", "updatedAt": updatedAt, "repository": ["nameWithOwner": repo],
            "isDraft": draft, "reviewDecision": decision, "mergeable": mergeable, "reviews": reviews,
            "commits": commits ?? ["nodes": [["commit": commit]]]]
}
private func page(_ rows: [Any] = [], total: Int? = nil) -> [String: Any] {
    ["issueCount": total ?? rows.count, "nodes": rows, "pageInfo": ["hasNextPage": false]]
}
private func parse(_ plan: ScopeQueryPlan, authored rows: [Any]) throws -> ScopedPollResult {
    var data: [String: Any] = ["viewer": ["id": accountA.viewerID, "login": "fixture-user"]]
    for (i, target) in plan.scope.targets.enumerated() {
        data["target\(i)"] = target.kind == .organization
            ? ["__typename": "Organization", "id": "O_fixture", "login": target.owner]
            : ["__typename": "Repository", "id": "R_fixture", "nameWithOwner": "\(target.owner)/\(target.name!)"]
    }
    for search in plan.searches {
        data[search.alias] = search.kind == .authoredPullRequest ? page(rows) : page()
    }
    return ScopedResponseParser.parse(try JSONSerialization.data(withJSONObject: ["data": data]), plan: plan)
}

@Suite struct AuthoredQueryPlanTests {
    @Test func everyBatchAddsOneAuthoredSearchWithAttentionFields() throws {
        let scope = try MonitoringScope(selected: [MonitoringTarget(organization: "Example"), MonitoringTarget(repository: "example/pet"),
                                                   MonitoringTarget(repository: "other/pet")])
        let plan = try ScopeQueryPlan(scope: scope, expectedAccount: accountA)
        #expect(plan.searches.filter { $0.kind == .authoredPullRequest }.map(\.alias) == ["authored0"])
        #expect(plan.arguments.contains("authored0=is:pr is:open author:@me archived:false org:example repo:other/pet"))
        let query = try #require(plan.arguments.first { $0.hasPrefix("query=") })
        for field in ["isDraft", "reviewDecision", "mergeable", "commits(last: 1)", "oid", "statusCheckRollup { state }"] {
            #expect(query.contains(field))
        }
        #expect(!query.contains("example") && !query.contains("other"), "target values stay GraphQL variables")
        #expect(try ScopeQueryPlan().searches.map(\.alias) == ["reviews0", "assigned0", "authored0"])
    }
}

@Suite struct AuthoredAttentionTests {
    @Test func needsActionReasons() {
        #expect(AuthoredAttention(authored(decision: "CHANGES_REQUESTED")) == .needsAction([.changesRequested(review: nil)]))
        #expect(AuthoredAttention(authored(mergeable: "CONFLICTING")) == .needsAction([.conflict]))
        #expect(AuthoredAttention(authored(rollup: ["state": "FAILURE"])) == .needsAction([.checksFailing(oidA)]))
        #expect(AuthoredAttention(authored(rollup: ["state": "ERROR"])) == .needsAction([.checksFailing(oidA)]))
        #expect(AuthoredAttention(authored(decision: "CHANGES_REQUESTED", mergeable: "CONFLICTING", rollup: ["state": "FAILURE"]))
                == .needsAction([.changesRequested(review: nil), .conflict, .checksFailing(oidA)]))
        #expect(AuthoredAttention.Reason.checksFailing(oidA).text == "Checks failing", "never claims 'required' checks")
    }

    /// #153: approved, not a draft, checks passing (or none) and no conflict is your move.
    @Test func approvedAndReadyToMergeNeedsYou() {
        #expect(AuthoredAttention(authored(decision: "APPROVED")) == .needsAction([.readyToMerge(oidA)]))
        #expect(AuthoredAttention(authored(decision: "APPROVED", rollup: NSNull())) == .needsAction([.readyToMerge(oidA)]), "no checks")
        #expect(AuthoredAttention(authored(decision: "APPROVED", commits: ["nodes": []])) == .needsAction([.readyToMerge(nil)]),
                "no commits visible")
        #expect(AuthoredAttention.Reason.readyToMerge(oidA).text == "Approved, ready to merge")
        #expect(AuthoredAttention.Reason.readyToMerge(oidA).idComponent == "ready@" + oidA, "a new ready head commit is a new event")
        #expect(AuthoredAttention.Reason.readyToMerge(nil).idComponent == "ready")
        // Still waiting on GitHub: its reason says what for.
        #expect(AuthoredAttention(authored(decision: "APPROVED", rollup: ["state": "PENDING"])) == .waiting([.checksRunning]))
        #expect(AuthoredAttention(authored(decision: "APPROVED", rollup: ["state": "EXPECTED"])) == .waiting([.checksRunning]))
        #expect(AuthoredAttention(authored(decision: "APPROVED", mergeable: "UNKNOWN")) == .waiting([.mergeabilityPending]))
        #expect(AuthoredAttention(authored(decision: "APPROVED", mergeable: "UNKNOWN", rollup: ["state": "PENDING"]))
                == .waiting([.checksRunning, .mergeabilityPending]))
        #expect(AuthoredAttention(authored(draft: true, decision: "APPROVED")) == .waiting([.draft]), "an approved draft is a draft")
        // Approved but blocked: needs you for what blocks it, never "ready to merge".
        #expect(AuthoredAttention(authored(decision: "APPROVED", mergeable: "CONFLICTING")) == .needsAction([.conflict]))
        #expect(AuthoredAttention(authored(decision: "APPROVED", rollup: ["state": "FAILURE"])) == .needsAction([.checksFailing(oidA)]))
        #expect(AuthoredAttention(authored(decision: "APPROVED", mergeable: "CONFLICTING", rollup: ["state": "ERROR"]))
                == .needsAction([.conflict, .checksFailing(oidA)]), "the reasons list both")
    }

    @Test func waitingOnOthersDraftsAndStillChecking() {
        // #148: each waiting PR says why, where GitHub says so.
        let decisions: [(Any, AuthoredAttention.WaitReason?)] = [("APPROVED", nil), ("REVIEW_REQUIRED", .reviewPending), (NSNull(), nil)]
        for (decision, decided) in decisions {
            for state in ["SUCCESS", "PENDING", "EXPECTED"] {
                var reasons: [AuthoredAttention.WaitReason] = []
                if decided == .reviewPending { reasons.append(.reviewPending) }
                if state != "SUCCESS" { reasons.append(.checksRunning) }
                // #153: approved with nothing pending needs you (see approvedAndReadyToMergeNeedsYou).
                if decision as? String == "APPROVED" && reasons.isEmpty { continue }
                #expect(AuthoredAttention(authored(decision: decision, rollup: ["state": state])) == .waiting(reasons))
            }
        }
        #expect(AuthoredAttention(authored(rollup: NSNull())) == .waiting([]), "no checks")
        #expect(AuthoredAttention(authored(commits: ["nodes": []])) == .waiting([]), "no commits visible")
        #expect(AuthoredAttention(authored(draft: true, decision: "CHANGES_REQUESTED", mergeable: "CONFLICTING",
                                           rollup: ["state": "FAILURE"])) == .waiting([.draft]), "drafts never alert")
        #expect(AuthoredAttention(authored(mergeable: "UNKNOWN")) == .waiting([.mergeabilityPending]), "conflict status not known yet")
        #expect(AuthoredAttention.WaitReason.draft.text == "Draft" && AuthoredAttention.WaitReason.reviewPending.text == "Review pending"
                && AuthoredAttention.WaitReason.checksRunning.text == "Checks running"
                && AuthoredAttention.WaitReason.mergeabilityPending.text == "Checking for conflicts")
        #expect(AuthoredAttention.WaitReason.summary([.reviewPending, .checksRunning, .mergeabilityPending])
                == "Review pending, checks running, checking for conflicts", "sentence case")
        #expect(AuthoredAttention.WaitReason.summary([]) == nil)
        #expect(AuthoredAttention(authored(decision: "CHANGES_REQUESTED", mergeable: "UNKNOWN")) == .needsAction([.changesRequested(review: nil)]),
                "UNKNOWN adds no conflict reason; other reasons still apply")
    }

    /// #60: the stable reason has separate evidence for a later changes-requested round.
    @Test func latestChangesRequestingReviewIsParsedStrictly() throws {
        let stamp = "2026-11-14T10:00:00Z"
        let date = try #require(ISO8601DateFormatter().date(from: stamp))
        let review = AuthoredAttention.Review(digest: EventBaseline.digest("PRR_round_2"), submittedAt: date)
        let visible = ["nodes": [["id": "PRR_round_2", "submittedAt": stamp]]]
        #expect(AuthoredAttention(authored(decision: "CHANGES_REQUESTED", reviews: visible))
                == .needsAction([.changesRequested(review: review)]))
        #expect(AuthoredAttention.Reason.changesRequested(review: review).idComponent == "changes")
        #expect(AuthoredAttention.Reason.changesRequested(review: nil).idComponent == "changes")
        #expect(AuthoredAttention(authored(decision: "APPROVED", reviews: visible)) == .needsAction([.readyToMerge(oidA)]),
                "an old changes-requesting review alone never means changes requested")
        let undated = AuthoredAttention.Review(digest: review.digest, submittedAt: nil)
        #expect(AuthoredAttention(authored(decision: "CHANGES_REQUESTED",
                                           reviews: ["nodes": [["id": "PRR_round_2", "submittedAt": NSNull()]]]))
                == .needsAction([.changesRequested(review: undated)]))
        for bad in [NSNull(), "none", ["nodes": [["id": "PRR_1"], ["id": "PRR_2"]]], ["nodes": [["id": "bad id"]]],
                    ["nodes": [["id": "PRR_round_2"]]], ["nodes": [["state": "CHANGES_REQUESTED"]]], [:]] as [Any] {
            #expect(AuthoredAttention(authored(decision: "CHANGES_REQUESTED", reviews: bad)) == nil, "\(bad)")
        }
        for badDate in [stamp + " trailing", stamp + "\n", "2026-02-31T10:00:00Z", "2026-11-14T10:00:00", 17] as [Any] {
            #expect(AuthoredAttention(authored(decision: "CHANGES_REQUESTED",
                reviews: ["nodes": [["id": "PRR_round_2", "submittedAt": badDate]]])) == nil, "\(badDate)")
        }
        var missing = authored(decision: "CHANGES_REQUESTED"); missing.removeValue(forKey: "reviews")
        #expect(AuthoredAttention(missing) == nil)
        let query = try #require(try ScopeQueryPlan().arguments.first { $0.hasPrefix("query=") })
        #expect(query.contains("reviews(last: 1, states: [CHANGES_REQUESTED]) { nodes { id submittedAt } }"), "same request, one nested node")
    }

    @Test func malformedRowsAreRejected() {
        let bad: [[String: Any]] = [
            authored(draft: "false"), authored(draft: 0), authored(decision: "DISMISSED"), authored(decision: 3),
            authored(mergeable: "MAYBE"), authored(mergeable: NSNull()), authored(rollup: ["state": "WEIRD"]),
            authored(rollup: ["status": "SUCCESS"]), authored(rollup: nil), authored(oid: "abc"),
            authored(oid: String(repeating: "A", count: 40)), authored(commits: ["nodes": [["commit": ["oid": oidA, "statusCheckRollup": NSNull()]],
                                                                                  ["commit": ["oid": oidB, "statusCheckRollup": NSNull()]]]]),
            authored(commits: "none"), authored(commits: ["nodes": [["oid": oidA]]]),
        ]
        for row in bad { #expect(AuthoredAttention(row) == nil, "\(row)") }
        var missing = authored(); missing.removeValue(forKey: "reviewDecision")
        #expect(AuthoredAttention(missing) == nil)
        missing = authored(); missing.removeValue(forKey: "isDraft")
        #expect(AuthoredAttention(missing) == nil)
        missing = authored(); missing.removeValue(forKey: "commits")
        #expect(AuthoredAttention(missing) == nil)
    }
}

@Suite struct AuthoredParserTests {
    @Test func onlyNeedsActionRowsBecomeItemsAndTheRestAreCounted() throws {
        let plan = try ScopeQueryPlan()
        let result = try parse(plan, authored: [
            authored("PR_changes", number: 1, decision: "CHANGES_REQUESTED"),
            authored("PR_checks", number: 2, rollup: ["state": "FAILURE"], oid: oidB),
            authored("PR_approved", number: 3, decision: "APPROVED"),
            authored("PR_draft", number: 4, draft: true, mergeable: "CONFLICTING"),
            authored("PR_unknown", number: 5, mergeable: "UNKNOWN"),
        ])
        #expect(result.complete && result.issues.isEmpty, "UNKNOWN mergeability never makes the poll Partial")
        #expect(result.waitingOnOthers == 2)
        #expect(Set(result.items.map(\.id)) == ["authoredPullRequest:PR_changes", "authoredPullRequest:PR_checks",
                                                "authoredPullRequest:PR_approved"], "one stable row ID per PR")
        #expect(Set(result.items.flatMap(\.attentionKeys)) == ["authoredPullRequest:PR_changes#changes",
                                                              "authoredPullRequest:PR_checks#checks@\(oidB)",
                                                              "authoredPullRequest:PR_approved#ready@\(oidA)"])
        #expect(result.items.allSatisfy { $0.kind == .authoredPullRequest && $0.kind.severity == .actionable })
        #expect(result.items.first { $0.id.contains("PR_changes") }?.attention == "Changes requested")
        #expect(result.items.first { $0.id.contains("PR_checks") }?.attention == "Checks failing")
        #expect(result.items.first { $0.id.contains("PR_approved") }?.attention == "Approved, ready to merge")
    }

    /// #148: the waiting PRs are rows for the Waiting on others group, one per PR, saying why,
    /// with no event keys; the count is exactly those rows.
    @Test func waitingPRsAreListedWithWhyAndNoEventKeys() throws {
        let result = try parse(ScopeQueryPlan(), authored: [
            authored("PR_changes", number: 1, decision: "CHANGES_REQUESTED"),
            authored("PR_review", number: 2, title: "Review me", updatedAt: "2026-11-14T12:00:00Z", decision: "REVIEW_REQUIRED",
                     rollup: ["state": "PENDING"]),
            authored("PR_draft", number: 3, updatedAt: "2026-11-14T11:00:00Z", draft: true, mergeable: "CONFLICTING"),
            authored("PR_unknown", number: 4, updatedAt: "2026-11-14T09:00:00Z", mergeable: "UNKNOWN"),
            authored("PR_plain", number: 5, updatedAt: "2026-11-14T08:00:00Z"),
        ])
        #expect(result.complete && result.waitingOnOthers == result.waiting.count && result.waiting.count == 4)
        #expect(result.waiting.map(\.id) == ["authoredPullRequest:PR_review", "authoredPullRequest:PR_draft",
                                             "authoredPullRequest:PR_unknown", "authoredPullRequest:PR_plain"], "newest first")
        // The row shows the first reason; help and VoiceOver get every reason.
        #expect(result.waiting.map(\.attention) == ["Review pending", "Draft", "Checking for conflicts", nil])
        #expect(result.waiting.map(\.detail) == ["Review pending, checks running", nil, nil, nil])
        #expect(result.waiting.allSatisfy { $0.kind == .authoredPullRequest && $0.attentionKeys.isEmpty && $0.url != nil })
        #expect(result.waiting[0].title == "Review me" && result.waiting[0].repository == "example/pet")
        #expect(Set(result.items.map(\.id)).isDisjoint(with: result.waiting.map(\.id)))
        if case .snapshot(let items, _, _) = result.outcome { #expect(items.count == 1, "waiting rows never reach the engine") }
    }

    /// QA W2c (#148): a PR in both lists (needs action in one request or inclusion, waiting in
    /// another) is shown only in Needs you: the result, and a merge of two requests, drop it from
    /// the waiting rows so the tile never counts it twice.
    @Test func aPRInBothListsIsOnlyANeedsYouRow() throws {
        let both = InboxItem(id: "authoredPullRequest:PR_both", kind: .authoredPullRequest, repository: "example/pet",
                             title: "Both", url: nil, updatedAt: Date(timeIntervalSince1970: 2), attention: "Merge conflict")
        var quiet = both; quiet.attention = "Review pending"
        let other = InboxItem(id: "authoredPullRequest:PR_wait", kind: .authoredPullRequest, repository: "example/pet",
                              title: "Wait", url: nil, updatedAt: Date(timeIntervalSince1970: 1), attention: "Draft")
        let viewer = ScopeViewer(account: accountA, login: "fixture-user")
        let one = ScopedPollResult(viewer: viewer, items: [both], issues: [], successfulSources: 1, waiting: [quiet, other])
        #expect(one.items == [both] && one.waiting == [other] && one.waitingOnOthers == 1)
        let actionable = ScopedPollResult(viewer: viewer, items: [both], issues: [], successfulSources: 1)
        let waiting = ScopedPollResult(viewer: viewer, items: [], issues: [], successfulSources: 1, waiting: [quiet, other])
        for merged in [ScopedGhClient.merge(actionable, waiting), ScopedGhClient.merge(waiting, actionable)] {
            #expect(merged.items == [both] && merged.waiting == [other] && merged.waitingOnOthers == 1)
        }
    }

    @Test func malformedAuthoredRowIsPartialNotWaiting() throws {
        let result = try parse(ScopeQueryPlan(), authored: [authored(mergeable: "MAYBE"), authored("PR_ok", number: 2, decision: "CHANGES_REQUESTED")])
        #expect(!result.complete && result.issues == [.malformedRow("authored0")])
        #expect(result.waitingOnOthers == 0 && result.items.count == 1)
        if case .snapshot(_, let complete, _) = result.outcome { #expect(!complete) } else { Issue.record("expected Partial snapshot") }
    }

    @Test func overlappingInclusionsCountAWaitingPROnceAndNeverBothWays() throws {
        let scope = try MonitoringScope(selected: [MonitoringTarget(organization: "example"), MonitoringTarget(repository: "example/pet")])
        let plan = try ScopeQueryPlan(scope: scope, expectedAccount: accountA)
        let result = try parse(plan, authored: [authored("PR_wait", number: 1), authored("PR_act", number: 2, mergeable: "CONFLICTING")])
        #expect(result.complete && result.waitingOnOthers == 1)
        #expect(result.waiting.map(\.id) == ["authoredPullRequest:PR_wait"])
        #expect(result.items.map(\.id) == ["authoredPullRequest:PR_act"])
    }

    @Test func authoredRowOutsideItsTargetIsMalformed() throws {
        let scope = try MonitoringScope(selected: [MonitoringTarget(repository: "example/pet")])
        let plan = try ScopeQueryPlan(scope: scope, expectedAccount: accountA)
        let result = try parse(plan, authored: [authored(repo: "other/pet", decision: "CHANGES_REQUESTED")])
        #expect(!result.complete && result.items.isEmpty && result.issues.contains(.malformedRow("authored0")))
    }

    @Test func tooManyAuthoredPRsIsCappedPartial() throws {
        let rows = (0..<ScopeQueryPlan.rowsPerCategory).map { authored("PR_\($0)", number: $0 + 1) }
        var data: [String: Any] = ["viewer": ["id": accountA.viewerID, "login": "fixture-user"]]
        let plan = try ScopeQueryPlan()
        for search in plan.searches { data[search.alias] = search.kind == .authoredPullRequest ? page(rows, total: 45) : page() }
        let result = ScopedResponseParser.parse(try JSONSerialization.data(withJSONObject: ["data": data]), plan: plan)
        #expect(!result.complete && result.issues.contains(.capped("authored0")))
    }
}

@Suite struct AuthoredEventTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func poll(_ engine: InboxEngine, _ rows: [Any], at minutes: Double) throws -> [InboxEvent] {
        let result = try parse(ScopeQueryPlan(), authored: rows)
        return engine.apply(result.outcome, now: t0 + minutes * 60)
    }

    @Test func commentChurnNeverReannouncesButANewAttentionStateDoesOnce() throws {
        let engine = InboxEngine()
        #expect(try poll(engine, [authored(decision: "APPROVED")], at: 0).isEmpty, "baseline")
        let changes = try poll(engine, [authored(decision: "CHANGES_REQUESTED")], at: 1)
        #expect(changes.map(\.item.attention) == ["Changes requested"])
        #expect(try poll(engine, [authored(title: "Renamed", updatedAt: "2026-11-14T11:00:00Z", decision: "CHANGES_REQUESTED")],
                         at: 2).isEmpty, "comment/title churn is not a new attention state")
        #expect(try poll(engine, [authored(decision: "CHANGES_REQUESTED", oid: oidB)], at: 3).isEmpty,
                "a push that keeps changes requested is not new")
        let failing = try poll(engine, [authored(decision: "CHANGES_REQUESTED", rollup: ["state": "FAILURE"], oid: oidB)], at: 4)
        #expect(failing.map(\.item.attention) == ["Changes requested, Checks failing"])
        #expect(try poll(engine, [authored(decision: "CHANGES_REQUESTED", rollup: ["state": "FAILURE"], oid: oidB)], at: 5).isEmpty)
        let newCommit = try poll(engine, [authored(decision: "CHANGES_REQUESTED", rollup: ["state": "FAILURE"], oid: oidA)], at: 6)
        #expect(newCommit.count == 1, "checks failing again on a new head commit is a new event")
        #expect(try poll(engine, [authored(decision: "CHANGES_REQUESTED", mergeable: "UNKNOWN", rollup: ["state": "FAILURE"], oid: oidA)],
                         at: 7).isEmpty, "UNKNOWN removes no reason and adds none")
        let conflict = try poll(engine, [authored(decision: "CHANGES_REQUESTED", mergeable: "CONFLICTING", rollup: ["state": "FAILURE"], oid: oidA)], at: 8)
        #expect(conflict.count == 1, "UNKNOWN resolving to CONFLICTING announces once")
    }

    @Test func waitingPRsNeverAnnounce() throws {
        let engine = InboxEngine()
        #expect(try poll(engine, [], at: 0).isEmpty)
        #expect(try poll(engine, [authored(decision: "APPROVED", rollup: ["state": "PENDING"]),
                                  authored("PR_draft", number: 2, draft: true, mergeable: "CONFLICTING"),
                                  authored("PR_unknown", number: 3, mergeable: "UNKNOWN")], at: 1).isEmpty)
        #expect(engine.items.isEmpty && engine.state == .empty)
    }

    /// #153: approved with checks running waits quietly; once ready it needs you and announces
    /// once. The conflict check flapping back to ready is not new; ready on a new head commit is.
    @Test func approvedBecomingReadyAnnouncesOnce() throws {
        let engine = InboxEngine()
        #expect(try poll(engine, [], at: 0).isEmpty, "baseline")
        #expect(try poll(engine, [authored(decision: "APPROVED", rollup: ["state": "PENDING"])], at: 1).isEmpty)
        #expect(engine.items.isEmpty, "checks running: still waiting")
        let ready = try poll(engine, [authored(decision: "APPROVED")], at: 2)
        #expect(ready.map(\.item.attention) == ["Approved, ready to merge"])
        #expect(engine.items.map(\.id) == ["authoredPullRequest:PR_authored_1"])
        #expect(try poll(engine, [authored(decision: "APPROVED")], at: 3).isEmpty, "unchanged poll: no replay")
        #expect(try poll(engine, [authored(decision: "APPROVED", mergeable: "UNKNOWN")], at: 4).isEmpty)
        #expect(engine.items.isEmpty, "GitHub rechecking conflicts: waiting again")
        #expect(try poll(engine, [authored(decision: "APPROVED")], at: 5).isEmpty, "the same ready commit is not new")
        #expect(try poll(engine, [authored(decision: "APPROVED", rollup: ["state": "PENDING"], oid: oidB)], at: 6).isEmpty)
        #expect(try poll(engine, [authored(decision: "APPROVED", oid: oidB)], at: 7).count == 1, "ready on a new head commit")
        let conflict = try poll(engine, [authored(decision: "APPROVED", mergeable: "CONFLICTING", oid: oidB)], at: 8)
        #expect(conflict.map(\.item.attention) == ["Merge conflict"], "a conflict replaces ready and announces")
    }
}

@Suite struct AuthoredPrivacyTests {
    private var item: InboxItem {
        InboxItem(id: "authoredPullRequest:PR_x:changes", kind: .authoredPullRequest, repository: "secret-org/secret-repo",
                  title: "Secret authored title", url: URL(string: "https://github.com/secret-org/secret-repo/pull/1"),
                  updatedAt: Date(timeIntervalSince1970: 1_800_000_000), attention: "Changes requested")
    }

    @Test func privacyModeHidesTitleAndRepositoryButKeepsTheReason() {
        #expect(PrivacyText.title(item, privacy: true) == "Your pull request")
        #expect(PrivacyText.subtitle(item, privacy: true) == "Your pull request · Changes requested")
        #expect(PrivacyText.subtitle(item, privacy: false) == "Your pull request · Changes requested · secret-org/secret-repo")
        let lines = PrivacyText.summary(dataState: .ready, items: [item], unseenCount: 1, privacy: true)
        #expect(!lines.joined().contains("secret") && !lines.joined().contains("Secret"))
        let compact = PrivacyText.compactSummary(dataState: .ready, items: [item], unseenCount: 1)
        #expect(!compact.joined().contains("ecret"))
    }

    @Test func waitingNoteIsInformationalAndHonestAboutQuality() {
        #expect(AuthoredWaiting.note(0, dataState: .ready) == nil)
        #expect(AuthoredWaiting.note(1, dataState: .ready) == "1 of your pull requests is waiting on others or being checked by GitHub")
        #expect(AuthoredWaiting.note(3, dataState: .empty) == "3 of your pull requests are waiting on others or being checked by GitHub")
        #expect(AuthoredWaiting.note(2, dataState: .partial) == "At least 2 of your pull requests are waiting on others or being checked by GitHub")
        for state in [DataState.loading, .error("x"), .ghMissing, .unauthenticated] {
            #expect(AuthoredWaiting.note(2, dataState: state) == nil)
        }
    }
}

@Suite struct AuthoredBaselineTests {
    @Test func categoriesVersionChangesTheBaselineKeySoUpgradesRebaselineSilently() throws {
        let scopeText = String(decoding: try { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return try e.encode(MonitoringScope.everything) }(), as: UTF8.self)
        let legacy = EventBaseline.digest("v\(EventBaseline.version)\n\(DataSourceMode.githubCLI.rawValue)\n\(ScopeIdentity.github(accountA).storageSuffix)\n\(scopeText)")
        let current = BaselineKey(source: .githubCLI, identity: .github(accountA), scope: .everything)
        #expect(ScopeQueryPlan.categoriesVersion == 5)
        #expect(current.value != legacy, "a v1 (reviews+assigned) record no longer matches")
        let v4 = EventBaseline.digest("v\(EventBaseline.version)\nc4\n\(DataSourceMode.githubCLI.rawValue)\n\(ScopeIdentity.github(accountA).storageSuffix)\n\(scopeText)")
        #expect(current.value != v4, "#153: a v4 record (approved PRs waiting) re-baselines silently, no upgrade announcements")
        let defaults = EphemeralDefaults(name: "authored.baseline.\(UUID().uuidString)")
        let store = EventBaselineStore(defaults: defaults)
        store.save(EventBaseline(key: legacy, digests: [EventBaseline.digest("reviewRequest:PR_1")], baselineEstablished: true,
                                 quality: .ready, lastSuccess: Date()))
        #expect(store.load(for: current) == nil, "old-category record discarded: fresh silent baseline")
    }
}
