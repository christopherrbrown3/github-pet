import Foundation
import Testing
@testable import GitHubPetCore

private let accountA = try! ScopeAccount(viewerID: "U_fixture_A")
private let accountB = try! ScopeAccount(viewerID: "U_fixture_B")
private let lineTerminators = ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"]
private func mixedScope() throws -> MonitoringScope {
    try MonitoringScope(selected: [MonitoringTarget(organization: "Example"), MonitoringTarget(repository: "example/pet")])
}
/// An organization and a repository outside it: two qualifiers in one batched search.
private func crossScope() throws -> MonitoringScope {
    try MonitoringScope(selected: [MonitoringTarget(organization: "example"), MonitoringTarget(repository: "other/pet")])
}
private func row(_ id: String = "PR_fixture_1", repo: String = "example/pet") -> [String: Any] {
    ["__typename": "PullRequest", "id": id, "number": 1, "title": "Fixture review",
     "url": "https://github.com/\(repo)/pull/1", "updatedAt": "2026-11-14T10:00:00Z", "repository": ["nameWithOwner": repo]]
}
private func page(_ rows: [Any] = [], total: Int? = nil, more: Bool = false) -> [String: Any] {
    ["issueCount": total ?? rows.count, "nodes": rows, "pageInfo": ["hasNextPage": more]]
}
private func envelope(_ plan: ScopeQueryPlan) -> [String: Any] {
    var data: [String: Any] = ["viewer": ["id": accountA.viewerID, "login": "fixture-user"]]
    for (i, target) in plan.scope.targets.enumerated() {
        if target.kind == .organization {
            data["target\(i)"] = ["__typename": "Organization", "id": "O_fixture", "login": target.owner]
        } else {
            data["target\(i)"] = ["__typename": "Repository", "id": "R_fixture", "nameWithOwner": "\(target.owner)/\(target.name!)"]
        }
    }
    for search in plan.searches { data[search.alias] = page() }
    return data
}
private func response(_ body: [String: Any], errors: [[String: Any]]? = nil) throws -> Data {
    var envelope: [String: Any] = ["data": body]
    if let errors { envelope["errors"] = errors }
    return try JSONSerialization.data(withJSONObject: envelope)
}
private let scopedErrorShapes = [#"[{"message":"fixture failure"}]"#, #""malformed""#, "{}", "null", "[]", "[null]", "[{}]", "true", "0"]
private func scopedErrorPayload(_ plan: ScopeQueryPlan, includeRow: Bool, errorsJSON: String? = nil) throws -> Data {
    var body = envelope(plan)
    if includeRow {
        for search in plan.searches where search.kind == .reviewRequest { body[search.alias] = page([row()]) }
    }
    let base = try response(body)
    guard let errorsJSON else { return base }
    return Data((String(decoding: base, as: UTF8.self).dropLast() + ",\"errors\":" + errorsJSON + "}").utf8)
}

private func checkViewerDisplayLogins(_ fetch: (Data, ScopeQueryPlan) -> ScopedPollResult) throws {
    let selected = try mixedScope()
    let plans = try [ScopeQueryPlan(), ScopeQueryPlan(expectedAccount: accountA),
                     ScopeQueryPlan(scope: selected, expectedAccount: accountA)]
    let validLogins = ["fixture-user", "mona-cat_demo", "demo_admin", "Renamed-User_demo",
                       String(repeating: "a", count: 39), String(repeating: "a", count: 34) + "_demo"]
    let invalidLogins = ["", " user", "user ", "us er", "user\t", "user\0", "user\u{1f}", "user\u{7f}",
                         "móna_demo", "K_demo", "😀_demo", "user\u{fffd}", String(repeating: "a", count: 40),
                         "-user", "user-", "_user", "user_", "user/name", "user:other", "user.name"]
        + lineTerminators.flatMap { ["user_demo" + $0, "us" + $0 + "er_demo"] }
    let suite = "scope.viewer.tests.\(UUID().uuidString)"
    let defaults = EphemeralDefaults(name: suite)
    let store = ScopeSelectionStore(defaults: defaults)
    try store.save(selected, for: .github(accountA))
    for plan in plans {
        for includeRow in [false, true] {
            func payload(_ login: String, id: String = accountA.viewerID) throws -> Data {
                var body = envelope(plan)
                body["viewer"] = ["id": id, "login": login]
                if includeRow {
                    for search in plan.searches where search.kind == .reviewRequest { body[search.alias] = page([row()]) }
                }
                return try response(body)
            }
            for login in validLogins {
                let result = fetch(try payload(login), plan)
                #expect(result.complete && result.issues.isEmpty, "valid display login \(login)")
                #expect(result.viewer?.account == accountA && result.viewer?.login == login)
                #expect(result.items.count == (includeRow ? 1 : 0))
                if let viewer = result.viewer {
                    #expect(store.load(for: .github(viewer.account)) == .scope(selected), "renamed login keeps node-ID persistence")
                }
            }
            for login in invalidLogins {
                let result = fetch(try payload(login), plan)
                #expect(!result.complete && result.viewer == nil && result.items.isEmpty)
                #expect(result.issues == [.viewerUnavailable], "invalid login bytes \(Array(login.utf8))")
            }
            if plan.expectedAccount != nil {
                for login in ["fixture-user", "mona-cat_demo", "demo_admin"] {
                    let mismatch = fetch(try payload(login, id: accountB.viewerID), plan)
                    #expect(!mismatch.complete && mismatch.items.isEmpty && mismatch.issues == [.identityMismatch])
                    #expect(mismatch.viewer?.account == accountB)
                }
            }
        }
    }
    // Viewer display syntax never broadens organization or repository-owner qualifiers.
    for login in ["mona-cat_demo", "demo_admin"] {
        #expect(throws: ScopeValidationError.self) { try MonitoringTarget(organization: login) }
        #expect(throws: ScopeValidationError.self) { try MonitoringTarget(repository: login + "/pet") }
    }
}

@Suite struct MonitoringScopeTests {
    @Test func normalizedValidatedUnionAndBounds() throws {
        let org = try MonitoringTarget(organization: "  Example\n")
        let repo = try MonitoringTarget(repository: " Example/Pet ")
        let scope = try MonitoringScope(selected: [org, repo, MonitoringTarget(repository: "example/PET")])
        #expect(scope.targets.count == 2)
        #expect(scope.includes(repository: "EXAMPLE/another"))
        #expect(scope.includes(repository: "example/pet"))
        #expect(!scope.includes(repository: "outsider/pet"))
        #expect(throws: ScopeValidationError.emptySelection) { try MonitoringScope(selected: []) }
        // No product cap; GitHub's per-request limits set a ceiling of 500 (#137).
        let many = try (0..<MonitoringScope.maximumTargets).map { try MonitoringTarget(repository: "fixture\($0)/pet") }
        #expect(try MonitoringScope(selected: many).targets.count == 500)
        #expect(throws: ScopeValidationError.tooManyTargets) {
            try MonitoringScope(selected: many + [MonitoringTarget(organization: "extra")])
        }
    }

    /// Saved selections decode unchanged, and a large selection fits the record guard (#137).
    @Test func savedSelectionsOfAnySizeRoundTrip() throws {
        let defaults = EphemeralDefaults(name: "scope.size.tests.\(UUID().uuidString)")
        let store = ScopeSelectionStore(defaults: defaults)
        let legacy = #"{"mode":"selected","targets":[{"kind":"organization","owner":"example"},{"kind":"repository","owner":"example","name":"pet"}]}"#
        defaults.set(Data(legacy.utf8), forKey: ScopeSelectionStore.key(.demo))
        #expect(store.load(for: .demo) == .scope(try mixedScope()))
        let longest = try (0..<MonitoringScope.maximumTargets).map { index -> MonitoringTarget in
            let owner = String(repeating: "o", count: 35) + String(format: "%04d", index)
            return try MonitoringTarget(repository: owner + "/" + String(repeating: "n", count: 100))
        }
        let scope = try MonitoringScope(selected: longest)
        try store.save(scope, for: .github(accountA))
        #expect(store.load(for: .github(accountA)) == .scope(scope))
        #expect(try JSONEncoder().encode(scope).count * 2 < ScopeSelectionStore.maximumRecordBytes, "the ceiling fits with room")
    }

    @Test func rejectsQualifierGraphQLAndHostInjectionIncludingDecodedValues() throws {
        for value in ["example OR repo:other/pet", "example\"}) { viewer", "example\norg:other", "x/y", "-bad", "éxample"] {
            #expect(throws: ScopeValidationError.self) { try MonitoringTarget(organization: value) }
        }
        for value in ["example/pet repo:other/repo", "example/pet\nOR", "example/..", "https://github.com/example/pet", "example/pet/extra"] {
            #expect(throws: ScopeValidationError.self) { try MonitoringTarget(repository: value) }
        }
        #expect(throws: ScopeValidationError.unsupportedHost) { try ScopeAccount(host: "enterprise.example", viewerID: "U_A") }
        #expect(throws: ScopeValidationError.self) { try ScopeAccount(viewerID: "demo\nother") }
        for json in [#"{"mode":"selected","targets":[]}"#,
                     #"{"mode":"everything","targets":[{"kind":"organization","owner":"example"}]}"#,
                     #"{"mode":"selected","targets":[{"kind":"repository","owner":"example","name":"pet OR repo:other/repo"}]}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(MonitoringScope.self, from: Data(json.utf8)) }
        }
    }

    @Test func accountAndDemoRecordsAreIsolatedAndCorruptionNeverBroadens() throws {
        let defaults = EphemeralDefaults(name: "scope.tests.\(UUID().uuidString)")
        let store = ScopeSelectionStore(defaults: defaults), selected = try mixedScope()
        #expect(store.load(for: .github(accountA)) == .scope(.everything), "legacy/missing record")
        try store.save(selected, for: .github(accountA))
        try store.save(MonitoringScope(selected: [MonitoringTarget(organization: "demo-only")]), for: .demo)
        #expect(store.load(for: .github(accountA)) == .scope(selected))
        #expect(store.load(for: .github(accountB)) == .scope(.everything))
        #expect(store.load(for: .demo) != store.load(for: .github(accountA)))
        defaults.set(Data(#"{"mode":"selected","targets":[]}"#.utf8), forKey: ScopeSelectionStore.key(.github(accountA)))
        #expect(store.load(for: .github(accountA)) == .corruptConfiguration)
        #expect(store.load(for: .github(accountB)) == .scope(.everything))
        defaults.set("not data", forKey: ScopeSelectionStore.key(.demo))
        #expect(store.load(for: .demo) == .corruptConfiguration)
        defaults.set(Data(count: ScopeSelectionStore.maximumRecordBytes + 1), forKey: ScopeSelectionStore.key(.demo))
        #expect(store.load(for: .demo) == .corruptConfiguration)
    }

    @Test func offlineFixturesUnionWithoutDuplicateRowsAndMarkDemo() throws {
        let item = InboxItem(id: "review:fixture", kind: .reviewRequest, repository: "example/pet", title: "Fixture",
                             url: nil, updatedAt: Date(timeIntervalSince1970: 100))
        let source = ScopedFixtureSource(items: [item, item])
        #expect(source.poll(scope: try mixedScope()) == .snapshot(items: [InboxItem(id: item.id, kind: item.kind,
            repository: item.repository, title: item.title, url: nil, updatedAt: item.updatedAt, isDemo: true)], complete: true))
    }

    @Test func byteValidationRejectsLineSeparatorsAndPreservesIntentionalInputTrimming() throws {
        for suffix in lineTerminators {
            #expect(throws: ScopeValidationError.invalidRepository) {
                try MonitoringTarget(repository: "example" + suffix + "/pet")
            }
            #expect(throws: ScopeValidationError.invalidIdentity) { try ScopeAccount(viewerID: "U_fixture_A" + suffix) }
            #expect(try MonitoringTarget(organization: " EXAMPLE" + suffix).owner == "example")
            #expect(try MonitoringTarget(repository: " EXAMPLE/PET" + suffix).qualifier == "repo:example/pet")
            let org = try JSONSerialization.data(withJSONObject: ["kind": "organization", "owner": " EXAMPLE" + suffix])
            #expect(try JSONDecoder().decode(MonitoringTarget.self, from: org).owner == "example")
            let repo = try JSONSerialization.data(withJSONObject: ["kind": "repository", "owner": "example" + suffix, "name": "pet"])
            #expect(throws: (any Error).self) { try JSONDecoder().decode(MonitoringTarget.self, from: repo) }
            let identity = try JSONSerialization.data(withJSONObject: ["host": "github.com", "viewerID": "U_fixture_A" + suffix])
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ScopeAccount.self, from: identity) }
        }
        #expect(throws: ScopeValidationError.self) { try MonitoringTarget(organization: "K") }
    }
}

@Suite struct ScopedQueryTests {
    @Test func directAssignmentChangesOnlyReviewSearchVariables() throws {
        let ten = try MonitoringScope(selected: (0..<10).map { try MonitoringTarget(organization: "fixture\($0)") })
        for scope in try [.everything, mixedScope(), ten] {
            let all = try ScopeQueryPlan(scope: scope, expectedAccount: accountA)
            let direct = try ScopeQueryPlan(scope: scope, expectedAccount: accountA, assignmentMode: .direct)
            let inclusions = max(1, ScopeQueryPlan.batches(scope.targets).count)
            #expect(direct.searches.map(\.alias) == all.searches.map(\.alias))
            #expect(direct.searches.count == inclusions * 3)
            #expect(direct.arguments == all.arguments.map { argument in
                argument.hasPrefix("reviews")
                    ? argument.replacingOccurrences(of: "review-requested:@me", with: "user-review-requested:@me")
                    : argument
            })
            #expect(direct.arguments.filter { $0.contains("user-review-requested:@me") }.count == inclusions)
        }
    }

    @Test func viewerDisplayLoginsAcceptManagedAccountsWithoutChangingIdentityOrTargets() throws {
        try checkViewerDisplayLogins { ScopedResponseParser.parse($0, plan: $1) }
    }
    @Test func anyPresentErrorsMemberKeepsScopedParserIncompleteAndRetainsRows() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        for includeRow in [false, true] {
            for errors in scopedErrorShapes {
                let result = ScopedResponseParser.parse(try scopedErrorPayload(plan, includeRow: includeRow, errorsJSON: errors), plan: plan)
                #expect(!result.complete && result.issues == [.graphQLError], "present errors shape \(errors)")
                #expect(result.viewer?.account == accountA && result.items.count == (includeRow ? 1 : 0))
                if case .snapshot(_, false, _) = result.outcome {} else { Issue.record("errors member cannot produce complete empty/data") }
            }
            let valid = ScopedResponseParser.parse(try scopedErrorPayload(plan, includeRow: includeRow), plan: plan)
            #expect(valid.complete && valid.items.count == (includeRow ? 1 : 0), "absent errors control")
            for rate in [#"[{"type":"RATE_LIMITED"}]"#, #"[{"extensions":{"type":"RATE_LIMITED"}}]"#] {
                let limited = ScopedResponseParser.parse(try scopedErrorPayload(plan, includeRow: includeRow, errorsJSON: rate), plan: plan)
                #expect(!limited.complete && limited.issues == [.rateLimited])
                #expect(limited.items.count == (includeRow ? 1 : 0))
            }
        }
    }
    @Test func oneOperationBindsViewerMetadataAndBatchedSearches() throws {
        let plan = try ScopeQueryPlan(scope: crossScope(), expectedAccount: accountA)
        #expect(plan.searches.count == 3 && plan.searches.allSatisfy { $0.targetIndices == [0, 1] })
        let query = try #require(plan.arguments.first { $0.hasPrefix("query=") })
        #expect(query.contains("viewer { id login }"))
        #expect(query.contains("organization(login: $owner0)"))
        #expect(query.contains("repository(owner: $owner1, name: $name1)"))
        #expect(!query.contains("example") && !query.contains("other"), "all target values are GraphQL variables")
        #expect(plan.arguments.contains("reviews0=is:pr is:open review-requested:@me org:example repo:other/pet"))
        #expect(plan.arguments.prefix(4) == ["api", "graphql", "--hostname", "github.com"])
        #expect(try ScopeQueryPlan().searches.count == 3)
        let ten = try MonitoringScope(selected: (0..<10).map { try MonitoringTarget(organization: "fixture\($0)") })
        #expect(try ScopeQueryPlan(scope: ten, expectedAccount: accountA).searches.count == 3)
        #expect(throws: ScopeValidationError.invalidIdentity) { try ScopeQueryPlan(scope: mixedScope()) }
    }

    /// #137: qualifiers share searches within GitHub's documented limits, every target is searched
    /// exactly once (or through its organization), and a target's metadata is always looked up.
    @Test func batchesRespectSearchLimitsAndCoverEveryTargetOnce() throws {
        func repositories(_ count: Int, owner: (Int) -> String = { "owner\($0)" }) throws -> [MonitoringTarget] {
            try (0..<count).map { try MonitoringTarget(repository: owner($0) + "/project-\($0)") }
        }
        let longestName = try MonitoringTarget(repository: String(repeating: "o", count: 39) + "/" + String(repeating: "n", count: 100))
        // Two-character logins: short qualifiers, so the 50-qualifier bound applies before the length.
        let characters = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let maximal = try (0..<250).map { try MonitoringTarget(organization: String([characters[$0 / 36], characters[$0 % 36]])) }
        let scopes: [(String, [MonitoringTarget])] = try [
            ("1", repositories(1)), ("10", repositories(10)), ("11", repositories(11)), ("100", repositories(100)),
            ("500", repositories(500)), ("longest", [longestName] + repositories(5)), ("short orgs", maximal),
        ]
        for (label, targets) in scopes {
            let scope = try MonitoringScope(selected: targets)
            for mode in [AssignmentMode.all, .direct] {
                let plan = try ScopeQueryPlan(scope: scope, expectedAccount: accountA, assignmentMode: mode)
                for search in plan.searches {
                    #expect(search.query.utf8.count <= ScopeQueryPlan.maximumSearchLength, "\(label): \(search.query.utf8.count)")
                    #expect(!search.targetIndices.isEmpty && search.targetIndices.count <= ScopeQueryPlan.maximumQualifiersPerSearch)
                    #expect(plan.arguments.contains("\(search.alias)=\(search.query)"), "one variable per search")
                    let words = search.query.split(separator: " ")
                    #expect(!words.contains { ["AND", "OR", "NOT"].contains($0) } && !search.query.contains("("))
                    #expect(words.filter { $0.hasPrefix("org:") || $0.hasPrefix("repo:") }
                        == search.targetIndices.map { Substring(scope.targets[$0].qualifier) })
                }
                for kind in [ItemKind.reviewRequest, .assignedIssue, .authoredPullRequest] {
                    let covered = plan.searches.filter { $0.kind == kind }.flatMap(\.targetIndices)
                    #expect(covered == Array(scope.targets.indices), "\(label) \(kind): each target once, in order")
                }
                let query = try #require(plan.arguments.first { $0.hasPrefix("query=") })
                #expect(query.components(separatedBy: ": repository(").count + query.components(separatedBy: ": organization(").count - 2
                    == scope.targets.count, "every target's metadata is looked up")
            }
        }
        // Boundaries: the longest qualifiers (146 characters with the space) split at 27 per search
        // (39 + 27 × 146 = 3,981; one more is 4,127 > 4,096), and short ones at 50 qualifiers.
        let lengthBound = try MonitoringScope(selected: (0..<30).map { index in
            try MonitoringTarget(repository: String(repeating: "o", count: 37) + String(format: "%02d", index) + "/" + String(repeating: "n", count: 100))
        })
        #expect(ScopeQueryPlan.batches(lengthBound.targets).map(\.count) == [27, 3])
        #expect(ScopeQueryPlan.batches(maximal).map(\.count) == [50, 50, 50, 50, 50])
        // Search counts the cost note relies on (#137): 3 searches per 50 typical repositories.
        let counts = try [1, 10, 11, 100, 101, 500].map { count in
            try ScopeQueryPlan.requests(scope: MonitoringScope(selected: repositories(count)), expectedAccount: accountA)
                .reduce(0) { $0 + $1.searches.count }
        }
        #expect(counts == [3, 3, 3, 6, 9, 30], "\(counts)")
    }

    /// #137: a poll is one request per 50 targets. Each request looks up its own targets and
    /// carries exactly their batches; together they look up and search every target once.
    @Test func largeScopesSplitIntoRequestsOfAtMost50Targets() throws {
        let repositories = try (0..<500).map { try MonitoringTarget(repository: "owner-\($0)/project-\($0)") }
        let organizations = try (0..<20).map { try MonitoringTarget(organization: "org-\($0)") }
        let covered = try (0..<30).map { try MonitoringTarget(repository: "org-\($0 % 20)/covered-\($0)") }
        let cases: [([MonitoringTarget], Int)] = [
            (Array(repositories.prefix(1)), 1), (Array(repositories.prefix(50)), 1), (Array(repositories.prefix(51)), 2),
            (Array(repositories.prefix(500)), 10), (organizations + covered + Array(repositories.prefix(450)), 10),
        ]
        for (targets, expected) in cases {
            let scope = try MonitoringScope(selected: targets)
            let plans = try ScopeQueryPlan.requests(scope: scope, expectedAccount: accountA)
            #expect(plans.count == expected, "\(targets.count) targets")
            #expect(plans.allSatisfy { $0.lookups.count <= ScopeQueryPlan.maximumTargetsPerRequest })
            #expect(plans.flatMap(\.lookups).sorted() == Array(scope.targets.indices), "every target looked up once")
            let all = try ScopeQueryPlan(scope: scope, expectedAccount: accountA)
            #expect(plans.flatMap(\.searches).map(\.query) == all.searches.map(\.query), "the same searches, split")
            #expect(Set(plans.flatMap(\.searches).map(\.alias)).count == all.searches.count, "aliases unique across requests")
            for plan in plans {
                #expect(plan.searches.allSatisfy { Set($0.targetIndices).isSubset(of: plan.lookups) }, "a batch travels with its lookups")
                HostileArgvTests.assertWellFormed(plan.arguments)
                let query = try #require(plan.arguments.first { $0.hasPrefix("query=") })
                #expect(plan.lookups.allSatisfy { query.contains("target\($0):") })
                #expect(!scope.targets.indices.contains { !plan.lookups.contains($0) && query.contains("target\($0):") })
            }
        }
        #expect(try ScopeQueryPlan.requests(scope: .everything, expectedAccount: nil).map(\.searches.count) == [3])
        let big = try MonitoringScope(selected: Array(repositories.prefix(51)))
        #expect(throws: ScopeValidationError.invalidIdentity) { try ScopeQueryPlan.requests(scope: big, expectedAccount: nil) }
        #expect(ScopeQueryPlan.longestCategoryQuery <= ScopeQueryPlan.maximumUnqualifiedLength)
    }

    /// A repository under a selected organization adds no qualifier: the organization's search
    /// already covers it, so hidden counts never double count. Its metadata is still checked.
    @Test func coveredRepositoriesAreSearchedThroughTheirOrganization() throws {
        let org = try MonitoringTarget(organization: "ExAmPlE")
        let covered = try [MonitoringTarget(repository: "EXAMPLE/Pet"), MonitoringTarget(repository: "example/tools")]
        let outside = try MonitoringTarget(repository: "other/pet")
        for targets in [[org] + covered + [outside], [outside] + covered.reversed() + [org]] {
            let plan = try ScopeQueryPlan(scope: MonitoringScope(selected: targets), expectedAccount: accountA)
            #expect(plan.searches.count == 3)
            #expect(plan.searches.allSatisfy { $0.query.hasSuffix(" org:example repo:other/pet") }, "\(plan.searches.map(\.query))")
            for kind in [ItemKind.reviewRequest, .assignedIssue] {
                var body = envelope(plan)
                for search in plan.searches where search.kind == kind { body[search.alias] = page([], total: 1) }
                let result = ScopedResponseParser.parse(try response(body), plan: plan)
                #expect(result.complete && result.items.isEmpty && result.hidden == 1)
                let engine = InboxEngine()
                #expect(engine.apply(result.outcome, now: Date()).isEmpty)
                #expect(engine.state == .hiddenOnly(1), "Hidden-only must never become All clear or double-count")
            }
            // A covered repository that no longer resolves still keeps the poll Partial.
            var body = envelope(plan)
            body["target\(plan.scope.targets.firstIndex(of: covered[1])!)"] = NSNull()
            let unresolved = ScopedResponseParser.parse(try response(body), plan: plan)
            #expect(!unresolved.complete && unresolved.issues.contains(.targetUnavailable(plan.scope.targets.firstIndex(of: covered[1])!)))
        }
    }

    /// Batches are disjoint, so hidden counts add across them; a batch that fills its page is
    /// capped (Partial) on its own, whatever the other batches report.
    @Test func hiddenCountsAddAcrossBatchesAndAFullBatchIsPartial() throws {
        // Longest valid names: about 27 fill one 4096-character search, so 30 make two batches.
        let targets = try (0..<30).map { index in
            try MonitoringTarget(repository: String(repeating: "o", count: 37) + String(format: "%02d", index) + "/" + String(repeating: "n", count: 100))
        }
        let plan = try ScopeQueryPlan(scope: MonitoringScope(selected: targets), expectedAccount: accountA)
        let reviews = plan.searches.filter { $0.kind == .reviewRequest }
        #expect(reviews.count == 2)
        var body = envelope(plan)
        body[reviews[0].alias] = page([], total: 2); body[reviews[1].alias] = page([], total: 3)
        let summed = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(summed.complete && summed.hidden == 5)
        let repository = { (index: Int) in plan.scope.targets[index].owner + "/" + plan.scope.targets[index].name! }
        let full = (1...ScopeQueryPlan.rowsPerCategory).map { row("PR_fixture_\($0)", repo: repository(reviews[1].targetIndices[0])) as Any }
        for capped in [page(full, total: 31), page(full, total: 30, more: true)] {
            body[reviews[1].alias] = capped
            let result = ScopedResponseParser.parse(try response(body), plan: plan)
            #expect(!result.complete && result.hidden == 0 && result.items.count == 30)
            #expect(result.issues.contains(.capped(reviews[1].alias)) && result.issues.contains(.capped(reviews[0].alias)),
                    "the capped batch, and the hidden one reverts to capped")
        }
        body[reviews[1].alias] = page(full, total: 30)
        let exact = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(exact.complete && exact.items.count == 30 && exact.hidden == 2, "a full page with nothing more is complete")
    }

    /// One unverified target in a batch drops only its own rows; the batch's other targets keep theirs.
    @Test func unverifiedTargetInABatchDropsOnlyItsOwnRows() throws {
        let plan = try ScopeQueryPlan(scope: crossScope(), expectedAccount: accountA)
        var body = envelope(plan)
        body["reviews0"] = page([row("PR_fixture_1", repo: "example/pet"), row("PR_fixture_2", repo: "other/pet")])
        body["target0"] = NSNull()
        let result = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(!result.complete && result.issues == [.targetUnavailable(0)])
        #expect(result.items.map(\.repository) == ["other/pet"])
        body["target1"] = NSNull()
        let none = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(none.successfulSources == 0 && none.items.isEmpty)
        // A row from outside every target in the batch is malformed, as before.
        body = envelope(plan); body["reviews0"] = page([row(repo: "outside/pet")])
        #expect(ScopedResponseParser.parse(try response(body), plan: plan).issues == [.malformedRow("reviews0")])
    }

    @Test func verifiedEmptyDiffersFromUnavailableTarget() throws {
        let plan = try ScopeQueryPlan(scope: crossScope(), expectedAccount: accountA)
        var body = envelope(plan)
        let empty = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(empty.complete && empty.items.isEmpty)
        body["target0"] = NSNull()
        let partial = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(!partial.complete && partial.issues.contains(.targetUnavailable(0)))
        body["target1"] = NSNull()
        #expect(ScopedResponseParser.parse(try response(body), plan: plan).successfulSources == 0)
    }

    @Test func duplicateRowsProduceOneStableItemAndOneEvent() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        var body = envelope(plan)
        body["reviews0"] = page([row()])
        let result = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(result.complete && result.items.count == 1)
        #expect(result.items.first?.id == "reviewRequest:PR_fixture_1")
        let engine = InboxEngine(), now = Date(timeIntervalSince1970: 1000)
        #expect(engine.apply(result.outcome, now: now).isEmpty)
        body["reviews0"] = page([row(), row("PR_fixture_2")])
        let changed = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(changed.complete && changed.items.count == 2)
        #expect(engine.apply(changed.outcome, now: now + 1).map(\.item.id) == ["reviewRequest:PR_fixture_2"])
        #expect(engine.apply(changed.outcome, now: now + 2).isEmpty)
        // The same row twice in one source is malformed, never two rows.
        body["reviews0"] = page([row(), row()])
        let repeated = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(!repeated.complete && repeated.items.count == 1 && repeated.issues.contains(.malformedRow("reviews0")))
    }

    /// #35 decision table, per alias: capped -> Partial; fewer than a page with a larger count and no
    /// next page in a clean response -> complete for visible results plus a hidden count; anything
    /// unclear -> Partial exactly as before (hidden aliases revert to capped).
    @Test func hiddenMatchesAreInformationalOnlyInACleanResponse() throws {
        let plan = try ScopeQueryPlan()
        let fullPage = (1...ScopeQueryPlan.rowsPerCategory).map { row("PR_fixture_\($0)") as Any }
        func parse(_ reviews: [String: Any], assigned: [String: Any] = page(), errors: [[String: Any]]? = nil) throws -> ScopedPollResult {
            var body = envelope(plan); body["reviews0"] = reviews; body["assigned0"] = assigned
            return ScopedResponseParser.parse(try response(body, errors: errors), plan: plan)
        }
        // Rows plus hidden: complete, rows kept, hidden summed across aliases, no capped issue.
        let withRows = try parse(page([row()], total: 4), assigned: page([], total: 2))
        #expect(withRows.complete && withRows.items.count == 1 && withRows.hidden == 5 && withRows.issues.isEmpty)
        if case .snapshot(let items, true, 5) = withRows.outcome { #expect(items.count == 1) } else { Issue.record("complete with hidden 5") }
        // Zero visible: complete, but hidden > 0 (the engine turns this into .hiddenOnly, never .empty).
        let none = try parse(page([], total: 3))
        #expect(none.complete && none.items.isEmpty && none.hidden == 3)
        // Capped: a full page with more matches, or hasNextPage, is Partial with no hidden count.
        for capped in [page(fullPage, total: 45), page([row()], total: 4, more: true)] {
            let result = try parse(capped)
            #expect(!result.complete && result.hidden == 0 && result.issues.contains(.capped("reviews0")))
            if case .snapshot(_, false, 0) = result.outcome {} else { Issue.record("capped stays Partial") }
        }
        // Unclear: GraphQL errors, a malformed row, or a missing source keep Partial and the hidden alias capped.
        let errored = try parse(page([row()], total: 4), errors: [["message": "partial failure"]])
        var bad = row("PR_fixture_9"); bad["url"] = "https://evil.example/x"
        let malformed = try parse(page([row(), bad], total: 6))
        var missingBody = envelope(plan); missingBody["reviews0"] = page([row()], total: 4); missingBody["assigned0"] = nil
        let missing = ScopedResponseParser.parse(try response(missingBody), plan: plan)
        for unclear in [errored, malformed, missing] {
            #expect(!unclear.complete && unclear.hidden == 0 && unclear.issues.contains(.capped("reviews0")))
            if case .snapshot(_, false, 0) = unclear.outcome {} else { Issue.record("unclear stays Partial without a hidden count") }
        }
        // Exact count: complete, nothing hidden.
        let exact = try parse(page([row()]))
        #expect(exact.complete && exact.hidden == 0)
    }

    @Test func batchedAliasesStillFailClosedForEveryQualityAndIdentityGuard() throws {
        let plan = try ScopeQueryPlan(scope: crossScope(), expectedAccount: accountA)
        let org = plan.scope.targets.firstIndex { $0.kind == .organization }!
        let repo = plan.scope.targets.firstIndex { $0.kind == .repository }!
        for kind in [ItemKind.reviewRequest, .assignedIssue] {
            let alias = (kind == .reviewRequest ? "reviews" : "assigned") + "0"
            for defect in ["missing", "cap", "contradiction", "row", "metadata", "unverified-org", "error", "account"] {
                var body = envelope(plan)
                body[alias] = page([], total: 1)
                var errors: [[String: Any]]?
                var validRow = row(repo: "other/pet")
                if kind == .assignedIssue {
                    validRow["__typename"] = "Issue"
                    validRow["url"] = "https://github.com/other/pet/issues/1"
                }
                switch defect {
                case "missing": body.removeValue(forKey: alias)
                case "cap": body[alias] = page([], total: 1, more: true)
                case "contradiction": body[alias] = page([validRow], total: 0)
                case "row": body[alias] = page([NSNull()], total: 2)
                case "metadata": body["target\(repo)"] = ["__typename": "Repository", "id": "R_fixture", "nameWithOwner": "different/pet"]
                case "unverified-org": body.removeValue(forKey: "target\(org)")
                case "error": errors = [["message": "fixture failure"]]
                default: body["viewer"] = ["id": accountB.viewerID, "login": "other-user"]
                }
                let result = ScopedResponseParser.parse(try response(body, errors: errors), plan: plan)
                #expect(!result.complete && result.hidden == 0, "\(alias) \(defect) must remain unverified")
            }
        }
    }

    @Test func malformedRowsCapsAndGraphQLErrorsCannotLookComplete() throws {
        let plan = try ScopeQueryPlan()
        let fullPage = (1...ScopeQueryPlan.rowsPerCategory).map { row("PR_fixture_\($0)") as Any }
        for badPage in [page([row(), NSNull()]), page(fullPage, total: 40),
                        page([], more: true), ["issueCount": true, "nodes": [], "pageInfo": ["hasNextPage": false]],
                        ["issueCount": 0, "nodes": []]] as [[String: Any]] {
            var body = envelope(plan); body["reviews0"] = badPage
            #expect(!ScopedResponseParser.parse(try response(body), plan: plan).complete)
        }
        var body = envelope(plan)
        var bad = row(); bad["url"] = "https://evil.example/fixture"
        body["reviews0"] = page([row(), bad])
        let partial = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(!partial.complete && partial.items.count == 1)
        #expect(partial.issues.contains(.malformedRow("reviews0")))
        #expect(!ScopedResponseParser.parse(try response(envelope(plan), errors: [["message": "partial failure"]]), plan: plan).complete)
        let limited = ScopedResponseParser.parse(try response(envelope(plan), errors: [["type": "RATE_LIMITED"]]), plan: plan)
        #expect(limited.issues.contains(.rateLimited))
        let noViewer = try JSONSerialization.data(withJSONObject: ["errors": [["type": "RATE_LIMITED"]]])
        #expect(ScopedResponseParser.parse(noViewer, plan: plan).issues.contains(.rateLimited))
        body = envelope(plan); body.removeValue(forKey: "assigned0")
        #expect(!ScopedResponseParser.parse(try response(body), plan: plan).complete)
    }

    @Test func metadataMismatchAndCrossScopeRowsAreNotVerified() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        var body = envelope(plan)
        body["reviews0"] = page([row(repo: "outside/pet")])
        #expect(ScopedResponseParser.parse(try response(body), plan: plan).issues.contains(.malformedRow("reviews0")))
        body = envelope(plan); body["target0"] = ["__typename": "Organization", "id": "O_other", "login": "other"]
        #expect(ScopedResponseParser.parse(try response(body), plan: plan).issues.contains(.malformedTarget(0)))
        body = envelope(plan); body["target0"] = ["__typename": "Organization", "id": "\n", "login": "example"]
        #expect(ScopedResponseParser.parse(try response(body), plan: plan).issues.contains(.malformedTarget(0)))
    }

    @Test func viewerMismatchNeverRelabelsSubmittedSelection() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        var body = envelope(plan); body["viewer"] = ["id": accountB.viewerID, "login": "other-user"]
        body["reviews0"] = page([row()])
        let result = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(result.viewer?.account == accountB)
        #expect(result.items.isEmpty && result.successfulSources == 0 && result.issues == [.identityMismatch])
    }

    @Test func malformedMetadataCountsDatesAndTitlesRemainIncomplete() throws {
        let plan = try ScopeQueryPlan()
        for key in ["updatedAt", "title", "id", "repository", "__typename"] {
            var bad = row(); bad.removeValue(forKey: key)
            var body = envelope(plan); body["reviews0"] = page([row(), bad])
            let parsed = ScopedResponseParser.parse(try response(body), plan: plan)
            #expect(!parsed.complete && parsed.items.count == 1)
        }
        var body = envelope(plan)
        body["reviews0"] = ["issueCount": 9.22e18, "nodes": [], "pageInfo": ["hasNextPage": false]]
        #expect(!ScopedResponseParser.parse(try response(body), plan: plan).complete)
    }

    @Test func fullJSONIdentifierSuffixesNeverProduceVerifiedEmptyOrCompleteData() throws {
        let everything = try ScopeQueryPlan()
        let selected = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        #expect(ScopedResponseParser.parse(try response(envelope(everything)), plan: everything).complete)
        #expect(ScopedResponseParser.parse(try response(envelope(selected)), plan: selected).complete)
        for suffix in lineTerminators {
            // The original940 JSON path accepted these viewer IDs for a fresh Everything fetch.
            var body = envelope(everything)
            body["viewer"] = ["id": accountA.viewerID + suffix, "login": "fixture-user"]
            let viewer = ScopedResponseParser.parse(try response(body), plan: everything)
            #expect(viewer.viewer == nil && !viewer.complete && viewer.successfulSources == 0)
            if case .failure = viewer.outcome {} else { Issue.record("malformed viewer must fail") }
            // Same original full JSON metadata cases, not a standalone regex surrogate.
            body = envelope(selected)
            body["target0"] = ["__typename": "Organization", "id": "O_fixture" + suffix, "login": "example"]
            let org = ScopedResponseParser.parse(try response(body), plan: selected)
            #expect(!org.complete && org.issues.contains(.malformedTarget(0)))
            body = envelope(selected)
            body["target1"] = ["__typename": "Repository", "id": "R_fixture" + suffix, "nameWithOwner": "example/pet"]
            let repo = ScopedResponseParser.parse(try response(body), plan: selected)
            #expect(!repo.complete && repo.issues.contains(.malformedTarget(1)))
            // JSONDecoder row IDs were rejected locally before the fix; preserve that result.
            body = envelope(everything); body["reviews0"] = page([row("PR_fixture_1" + suffix)])
            let item = ScopedResponseParser.parse(try response(body), plan: everything)
            #expect(!item.complete && item.items.isEmpty && item.issues.contains(.malformedRow("reviews0")))
        }
    }
}

private final class ScopeRunner: CommandRunner, @unchecked Sendable {
    var replies: [CommandResult]
    var calls: [[String]] = []
    var timeouts: [TimeInterval] = []
    var delay: TimeInterval = 0
    init(_ replies: [CommandResult]) { self.replies = replies }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append(arguments); timeouts.append(timeout)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return replies.removeFirst()
    }
}
@Suite struct ScopedClientTests {
    private func client(_ runner: ScopeRunner, timeout: TimeInterval = 20) -> ScopedGhClient {
        ScopedGhClient(locator: GhLocator(environment: [GhLocator.overrideVariable: "/fixture/gh"], isExecutable: { _ in true }),
                       runner: runner, timeout: timeout)
    }

    /// #137: a large scope runs one preflight, then its requests in order, and merges them.
    @Test func chunkedPollsMergeRequestsAndAnyFailureStaysPartial() throws {
        let targets = try (0..<80).map { try MonitoringTarget(repository: "owner-\($0)/project-\($0)") }
        let scope = try MonitoringScope(selected: targets)
        let plans = try ScopeQueryPlan.requests(scope: scope, expectedAccount: accountA)
        #expect(plans.count == 2)
        func repository(_ plan: ScopeQueryPlan) -> String { let target = scope.targets[plan.lookups[0]]; return "\(target.owner)/\(target.name!)" }
        func answer(_ plan: ScopeQueryPlan, hidden: Int = 0, viewer: ScopeAccount = accountA) throws -> CommandResult {
            var body = envelope(plan)
            body["viewer"] = ["id": viewer.viewerID, "login": "fixture-user"]
            let reviews = plan.searches.first { $0.kind == .reviewRequest }!.alias
            body[reviews] = page([row("PR_\(reviews)", repo: repository(plan))], total: 1 + hidden)
            return CommandResult(exitCode: 0, stdout: try response(body))
        }
        let preflight = CommandResult(exitCode: 0)
        let runner = ScopeRunner([preflight, try answer(plans[0], hidden: 2), try answer(plans[1], hidden: 3)])
        let clean = client(runner).fetch(scope: scope, expectedAccount: accountA)
        #expect(clean.complete && clean.items.count == 2 && clean.hidden == 5 && clean.successfulSources == plans.flatMap(\.searches).count)
        #expect(runner.calls == [GhFailure.authStatusArguments] + plans.map(\.arguments), "one preflight, then each request in order")
        // A later request that fails keeps the earlier rows, as Partial, with no hidden count.
        let transport = CommandResult(exitCode: 1, stderr: Data("dial tcp: lookup failed".utf8))
        let failedLater = client(ScopeRunner([preflight, try answer(plans[0], hidden: 2), transport])).fetch(scope: scope, expectedAccount: accountA)
        #expect(!failedLater.complete && failedLater.items.count == 1 && failedLater.hidden == 0 && failedLater.issues.contains(.transport))
        if case .snapshot(_, false, 0) = failedLater.outcome {} else { Issue.record("Partial expected: \(failedLater.outcome)") }
        var capped = try answer(plans[1]); capped = CommandResult(exitCode: 0, stdout: try {
            var body = envelope(plans[1]); body[plans[1].searches[0].alias] = page([], total: 1, more: true); return try response(body)
        }())
        let cappedLater = client(ScopeRunner([preflight, try answer(plans[0], hidden: 2), capped])).fetch(scope: scope, expectedAccount: accountA)
        #expect(!cappedLater.complete && cappedLater.hidden == 0 && cappedLater.issues.contains(.capped(plans[1].searches[0].alias)))
        // Another account answering any request wins at once: the session restores that account.
        let switched = client(ScopeRunner([preflight, try answer(plans[0]), try answer(plans[1], viewer: accountB)]))
            .fetch(scope: scope, expectedAccount: accountA)
        #expect(switched.issues == [.identityMismatch] && switched.viewer?.account == accountB && switched.items.isEmpty)
        // A first request with nothing usable ends the poll before the next one starts.
        let stopped = ScopeRunner([preflight, transport, try answer(plans[1])])
        let first = client(stopped).fetch(scope: scope, expectedAccount: accountA)
        #expect(first.issues == [.transport] && stopped.calls.count == 2)
        let signedOut = client(ScopeRunner([preflight, try answer(plans[0]), CommandResult(exitCode: 4, stderr: Data("gh auth login".utf8))]))
            .fetch(scope: scope, expectedAccount: accountA)
        #expect(signedOut.outcome == .failure(.unauthenticated))
    }

    /// An old gh without `auth status --active` fails the preflight with "unknown flag". That is only
    /// advisory: the request runs and its own result decides. Any other preflight failure stops first.
    @Test func oldGhWithoutActiveFlagLetsTheRequestDecide() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA, assignmentMode: .direct)
        let oldGh = CommandResult(exitCode: 1, stderr: Data("unknown flag: --active".utf8))
        let runner = ScopeRunner([oldGh, CommandResult(exitCode: 0, stdout: try response(envelope(plan)))])
        let result = client(runner).fetch(scope: plan.scope, expectedAccount: accountA, assignmentMode: .direct)
        #expect(runner.calls == [GhFailure.authStatusArguments, plan.arguments], "the request ran after the advisory preflight")
        #expect(result.issues.isEmpty)
        if case .failure = result.outcome { Issue.record("an old-gh preflight must not fail a good response") }

        let signedOut = ScopeRunner([CommandResult(exitCode: 1, stderr: Data("You are not logged in".utf8))])
        let blocked = client(signedOut).fetch(scope: plan.scope, expectedAccount: accountA, assignmentMode: .direct)
        #expect(signedOut.calls == [GhFailure.authStatusArguments], "a real sign-in failure never reaches the request")
        #expect(blocked.issues == [.signedOut] && blocked.items.isEmpty)
    }

    @Test func directAssignmentBindsViewerAndNeverFallsBackOnSearchFailure() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA, assignmentMode: .direct)
        var differentViewer = envelope(plan)
        differentViewer["viewer"] = ["id": accountB.viewerID, "login": "other-viewer"]
        let limited = try response(envelope(plan), errors: [["type": "RATE_LIMITED"]])
        let runner = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: try response(differentViewer)),
                                 CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: limited),
                                 CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: limited, outputComplete: false)])
        let client = client(runner)
        let budget = CommandBudget()
        let mismatch = client.fetch(scope: plan.scope, expectedAccount: accountA, assignmentMode: .direct, budget: budget)
        #expect(mismatch.issues == [.identityMismatch] && mismatch.items.isEmpty)
        let partial = client.fetch(scope: plan.scope, expectedAccount: accountA, assignmentMode: .direct, budget: budget)
        #expect(partial.issues == [.rateLimited])
        guard case .snapshot(let rows, false, 0) = partial.outcome else { Issue.record("rate limit must stay partial"); return }
        #expect(rows.isEmpty)
        let failure = client.fetch(scope: plan.scope, expectedAccount: accountA, assignmentMode: .direct, budget: budget)
        #expect(failure.issues == [.incompleteOutput])
        guard case .failure = failure.outcome else { Issue.record("truncated output must stay unknown"); return }
        #expect(runner.calls == Array(repeating: [GhFailure.authStatusArguments, plan.arguments], count: 3).flatMap { $0 })
        #expect(budget.consumedBytes > limited.count && budget.remaining <= CommandBudget.maximumSeconds)
    }
    @Test func identityOnlyRequestRunsNoSearchesAndDetectsTheViewer() throws {
        let plan = ScopeQueryPlan(identityFor: accountA)
        #expect(plan.identityOnly && plan.searches.isEmpty && plan.expectedAccount == accountA)
        let query = plan.arguments.joined(separator: " ")
        #expect(query.contains("viewer { id login }") && !query.contains("search(") && !query.contains("repository(")
                && !query.contains("organization("), "viewer only: no search aliases or target lookups")
        for (viewer, mismatch) in [(accountA, false), (accountB, true)] {
            let body = Data(#"{"data":{"viewer":{"id":"\#(viewer.viewerID)","login":"demo_sim"}}}"#.utf8)
            let runner = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: body)])
            let result = client(runner).fetchIdentity(expectedAccount: accountA, budget: CommandBudget(timeout: 20))
            #expect(runner.calls.count == 2 && runner.calls[1] == plan.arguments)
            #expect(result.viewer?.account == viewer && result.items.isEmpty && result.successfulSources == 0)
            #expect(result.issues.contains(.identityMismatch) == mismatch)
            if case .failure = result.outcome {} else { Issue.record("an identity reply is never a snapshot") }
        }
    }
    @Test func viewerDisplayLoginsAcceptManagedAccountsThroughBoundClient() throws {
        try checkViewerDisplayLogins { bytes, plan in
            let runner = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: bytes)])
            let result = client(runner).fetch(scope: plan.scope, expectedAccount: plan.expectedAccount)
            #expect(runner.calls.count == 2 && runner.calls[1] == plan.arguments, "display login never enters query argv")
            return result
        }
    }
    @Test func anyPresentErrorsMemberKeepsScopedClientIncompleteAndRetainsRows() throws {
        let scope = try mixedScope(), plan = try ScopeQueryPlan(scope: scope, expectedAccount: accountA)
        for includeRow in [false, true] {
            for errors in scopedErrorShapes {
                let runner = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0,
                    stdout: try scopedErrorPayload(plan, includeRow: includeRow, errorsJSON: errors))])
                let result = client(runner).fetch(scope: scope, expectedAccount: accountA)
                #expect(!result.complete && result.issues == [.graphQLError], "present errors shape \(errors)")
                #expect(result.viewer?.account == accountA && result.items.count == (includeRow ? 1 : 0))
                #expect(runner.calls.count == 2)
            }
            let control = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0,
                stdout: try scopedErrorPayload(plan, includeRow: includeRow))])
            #expect(client(control).fetch(scope: scope, expectedAccount: accountA).complete, "absent errors control")
            for rate in [#"[{"type":"RATE_LIMITED"}]"#, #"[{"extensions":{"type":"RATE_LIMITED"}}]"#] {
                let runner = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0,
                    stdout: try scopedErrorPayload(plan, includeRow: includeRow, errorsJSON: rate))])
                let limited = client(runner).fetch(scope: scope, expectedAccount: accountA)
                #expect(!limited.complete && limited.issues == [.rateLimited])
                #expect(limited.items.count == (includeRow ? 1 : 0))
            }
        }
    }
    @Test func injectableSingleOperationAndCompleteDefaultEverything() throws {
        let plan = try ScopeQueryPlan()
        let runner = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: try response(envelope(plan)))])
        #expect(client(runner).fetch().complete)
        #expect(runner.calls.count == 2)
        #expect(runner.calls[1] == plan.arguments)
        #expect(runner.timeouts[1] <= runner.timeouts[0])
    }
    @Test func oneTotalDeadlineIncludesPreflight() {
        let runner = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0)])
        runner.delay = 0.05
        #expect(client(runner, timeout: 0.08).fetch().issues == [.deadline])
        if runner.timeouts.count == 2 { #expect(runner.timeouts[1] < runner.timeouts[0]) }
        // If local load already consumed the whole budget in preflight, no second call is correct.
    }
    @Test func accountSwitchResponsesAreBoundToEachOperationIncludingReturnToA() throws {
        let scope = try mixedScope(), plan = try ScopeQueryPlan(scope: scope, expectedAccount: accountA)
        var other = envelope(plan); other["viewer"] = ["id": accountB.viewerID, "login": "other-user"]
        other["reviews0"] = page([row()])
        let runner = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: try response(other)),
                                 CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: try response(envelope(plan)))])
        let client = client(runner)
        let switched = client.fetch(scope: scope, expectedAccount: accountA)
        #expect(switched.items.isEmpty && switched.issues == [.identityMismatch])
        #expect(client.fetch(scope: scope, expectedAccount: accountA).complete)
        #expect(runner.calls.filter { $0.first == "api" }.count == 2, "each poll has its own viewer-bound operation")
    }
    @Test func signedOutTransportAndRateLimitRemainDistinct() {
        #expect(client(ScopeRunner([CommandResult(exitCode: 4)])).fetch().issues == [.signedOut])
        #expect(client(ScopeRunner([CommandResult(exitCode: 1, stderr: Data("network unavailable".utf8))])).fetch().issues == [.transport])
        #expect(client(ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1,
            stderr: Data("Bad credentials (HTTP 401)".utf8))])).fetch().issues == [.signedOut])
        #expect(client(ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1,
            stderr: Data("network unavailable".utf8))])).fetch().issues == [.transport])
        #expect(client(ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1,
            stderr: Data("API rate limit exceeded".utf8))])).fetch().issues == [.rateLimited])
    }
    /// #7: scope, SAML/SSO and HTTP 403 denials get one fixed, safe message; rate limits get
    /// their own. Neither echoes gh's stderr (which can name organizations) nor looks like an
    /// empty inbox.
    @Test func accessDenialsAndRateLimitsHaveFixedSafeMessages() throws {
        let denials = [
            "HTTP 403: Resource protected by organization SAML enforcement. You must grant your OAuth token access to secret-org.",
            "GraphQL: Your token has not been granted the required scopes to execute this query. The 'login' field requires one of the following scopes: ['read:org']",
            "HTTP 403: Must have admin rights to Repository. (https://api.github.com/graphql)",
            "error: this organization requires single sign-on (SSO) authorization",
        ]
        for stderr in denials {
            let result = client(ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1, stderr: Data(stderr.utf8))])).fetch()
            #expect(result.issues == [.accessDenied], "\(stderr)")
            #expect(result.outcome == .failure(.failed(ScopedPollResult.accessDeniedMessage)))
        }
        #expect(!ScopedPollResult.accessDeniedMessage.contains("secret-org"))
        // A 403 that is a rate limit stays a rate limit.
        let limited = client(ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1,
            stderr: Data("HTTP 403: API rate limit exceeded for user ID 1.".utf8))])).fetch()
        #expect(limited.issues == [.rateLimited])
        #expect(limited.outcome == .failure(.failed(ScopedPollResult.rateLimitedMessage)))
        // Controls keep their existing classification.
        #expect(client(ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1,
            stderr: Data("network unavailable".utf8))])).fetch().outcome == .failure(.failed("Monitoring scope could not be verified")))
        #expect(client(ScopeRunner([CommandResult(exitCode: 4)])).fetch().outcome == .failure(.unauthenticated))
    }

    /// #60 (PR64 LOW): another account answered AND gh printed a denial. Identity takes precedence:
    /// the result is identityMismatch with that viewer, so the session switches account instead of
    /// showing a denial for the wrong one. FAIL before: .accessDenied with no viewer.
    @Test func identityMismatchWinsOverDenialStderr() throws {
        let scope = try mixedScope(), plan = try ScopeQueryPlan(scope: scope, expectedAccount: accountA)
        var body = envelope(plan)
        body["viewer"] = ["id": accountB.viewerID, "login": "other-user"]
        let stderr = Data("GraphQL: Resource protected by organization SAML enforcement. (target0)".utf8)
        for exitCode: Int32 in [1, 0] {
            for errors in [[["type": "FORBIDDEN", "message": "Resource protected by organization SAML enforcement."]], nil] as [[[String: Any]]?] {
                let result = client(ScopeRunner([CommandResult(exitCode: 0),
                                                 CommandResult(exitCode: exitCode, stdout: try response(body, errors: errors), stderr: stderr)]))
                    .fetch(scope: scope, expectedAccount: accountA)
                #expect(result.issues == [.identityMismatch], "exit \(exitCode), errors \(errors != nil)")
                #expect(result.viewer?.account == accountB && result.items.isEmpty && !result.complete)
            }
        }
    }

    /// QA MED-1 on PR64: one SAML-enforced org in a Selected scope makes gh exit 1 with the SAML
    /// message on stderr AND the other targets' data on stdout. That is Partial with the readable
    /// rows and the denial quality line, not a whole-poll failure.
    @Test func samlDenialWithReadablePartialDataStaysPartialWithRows() throws {
        let scope = try crossScope(), plan = try ScopeQueryPlan(scope: scope, expectedAccount: accountA)
        let org = plan.scope.targets.firstIndex { $0.kind == .organization }!
        var body = envelope(plan)
        body["target\(org)"] = NSNull()
        body["reviews0"] = page([row(repo: "other/pet")])
        let stderr = Data("GraphQL: Resource protected by organization SAML enforcement. You must grant your Personal Access token access to this organization. (target0)".utf8)
        for errors in [[["type": "FORBIDDEN", "path": ["target\(org)"], "message": "Resource protected by organization SAML enforcement."]], nil] as [[[String: Any]]?] {
            let stdout = try response(body, errors: errors)
            let result = client(ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1, stdout: stdout, stderr: stderr)]))
                .fetch(scope: scope, expectedAccount: accountA)
            #expect(result.viewer?.account == accountA && result.items.count == 1, "readable rows survive (errors member: \(errors != nil))")
            #expect(result.issues.contains(.accessDenied) && !result.complete)
            guard case .snapshot(let items, false, 0) = result.outcome else { Issue.record("Partial expected: \(result.outcome)"); continue }
            #expect(items.count == 1)
            #expect(RepositoryScopeSession.qualitySummary(for: result.issues) == RepositoryScopeSession.accessDeniedQuality)
        }
        // Nothing usable came back: the whole poll is the fixed denial message.
        let nothing = client(ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1, stderr: stderr)])).fetch()
        #expect(nothing.issues == [.accessDenied] && nothing.outcome == .failure(.failed(ScopedPollResult.accessDeniedMessage)))
    }

    /// QA LOW-2 on PR64: a target named like "saml-team" is not a SAML denial.
    @Test func targetNamesContainingSamlAreNotDenials() throws {
        let notFound = "GraphQL: Could not resolve to an Organization with the login of 'saml-team'. (target0)"
        #expect(!ScopedGhClient.deniesAccess(notFound) && !ScopedGhClient.deniesAccess("Could not resolve repository 'sso-tools/single-sign-on'"))
        let result = client(ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1, stderr: Data(notFound.utf8))])).fetch()
        #expect(result.issues == [.transport])
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        let parsed = ScopedResponseParser.parse(try response(envelope(plan), errors: [["type": "NOT_FOUND", "message": notFound]]), plan: plan)
        #expect(parsed.issues.first == .graphQLError)
        // The GitHub SAML and SSO forms still match.
        for denial in ["Resource protected by organization SAML enforcement.", "the org has enabled SAML SSO",
                       "This organization has enabled or enforced SAML SSO", "requires single sign-on (SSO) authorization"] {
            #expect(ScopedGhClient.deniesAccess(denial), "\(denial)")
        }
    }

    @Test func graphQLDenialsAreClassifiedInsideTheResponse() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        let shapes: [([String: Any], ScopedFetchIssue)] = [
            (["type": "INSUFFICIENT_SCOPES", "message": "Your token has not been granted the required scopes"], .accessDenied),
            (["type": "FORBIDDEN", "path": ["target0"], "message": "Resource protected by organization SAML enforcement."], .accessDenied),
            (["extensions": ["type": "FORBIDDEN"], "message": "x"], .accessDenied),
            (["message": "Although you appear to have the correct authorization credentials, the org has enabled SAML SSO"], .accessDenied),
            (["type": "RATE_LIMITED", "message": "API rate limit exceeded"], .rateLimited),
            (["message": "fixture failure"], .graphQLError),
        ]
        for (error, issue) in shapes {
            let result = ScopedResponseParser.parse(try response(envelope(plan), errors: [error]), plan: plan)
            #expect(!result.complete && result.issues.first == issue, "\(error)")
        }
        // Rate limit wins when both appear; a denial wins over a generic error.
        let both = ScopedResponseParser.parse(try response(envelope(plan), errors: [
            ["type": "FORBIDDEN", "message": "x"], ["type": "RATE_LIMITED", "message": "y"]]), plan: plan)
        #expect(both.issues.first == .rateLimited)
        #expect(RepositoryScopeSession.qualitySummary(for: [.accessDenied, .graphQLError]) == RepositoryScopeSession.accessDeniedQuality)
        #expect(RepositoryScopeSession.qualitySummary(for: [.accessDenied, .rateLimited]) == "GitHub rate limit; scope results are incomplete.")
        #expect(!RepositoryScopeSession.accessDeniedQuality.contains("SAML enforcement."), "fixed text, not GitHub's message")
    }

    /// #60 (PR59 LOW-B): an error member with hidden results makes the hidden aliases capped too;
    /// the quality line must name the failure, not a result limit. FAIL before: "result limit reached".
    @Test func errorsTakePrecedenceOverCapsInTheQualityLine() throws {
        let plan = try ScopeQueryPlan()
        var body = envelope(plan)
        body["reviews0"] = page([row()], total: 4)
        let result = ScopedResponseParser.parse(try response(body, errors: [["message": "fixture failure"]]), plan: plan)
        #expect(result.issues.contains(.graphQLError) && result.issues.contains(.capped("reviews0")))
        let generic = "Monitoring scope could not be fully verified; retained rows may be incomplete."
        #expect(RepositoryScopeSession.qualitySummary(for: result.issues) == generic)
        for error in [ScopedFetchIssue.graphQLError, .missingSource("assigned0"), .malformedSource("assigned0"),
                      .malformedRow("reviews0"), .inconsistentDuplicate, .transport, .incompleteOutput] {
            #expect(RepositoryScopeSession.qualitySummary(for: [.capped("reviews0"), error]) == generic, "\(error)")
        }
        #expect(RepositoryScopeSession.qualitySummary(for: [.capped("reviews0"), .capped("assigned0")])
                == "Scope result limit reached; counts are incomplete.", "caps alone keep the limit wording")
        #expect(RepositoryScopeSession.qualitySummary(for: [.capped("reviews0"), .targetUnavailable(0)])
                == "A selected target could not be verified; results are incomplete.")
    }

    @Test func combinedOutputAndIncompleteCollectionCannotParseAsEmptySuccess() throws {
        let bytes = try response(envelope(ScopeQueryPlan()))
        let overflow = ScopeRunner([CommandResult(exitCode: 0, stderr: Data(count: CommandBudget.maximumBytes)),
                                    CommandResult(exitCode: 0, stdout: bytes)])
        #expect(client(overflow).fetch().issues == [.outputLimit])
        let incomplete = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: bytes, outputComplete: false)])
        #expect(client(incomplete).fetch().issues == [.incompleteOutput])
        let failed = ScopeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1, stdout: bytes)])
        #expect(!client(failed).fetch().complete)
    }

    @Test func realCollectorRejectsValidJSONBeforeEndlessStderrOverflow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("gh")
        let json = String(decoding: try response(envelope(ScopeQueryPlan())), as: UTF8.self)
            .replacingOccurrences(of: "'", with: "'\"'\"'")
        let script = "#!/bin/sh\nif [ \"$1\" = auth ]; then exit 0; fi\nprintf '%s' '\(json)'\nexec /usr/bin/yes >&2\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = ScopedGhClient(locator: GhLocator(environment: [GhLocator.overrideVariable: executable.path]), timeout: 5)
        let result = client.fetch()
        #expect(!result.complete && result.items.isEmpty && result.issues == [.outputLimit])
    }
}
