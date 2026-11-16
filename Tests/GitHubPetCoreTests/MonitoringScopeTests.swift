import Foundation
import Testing
@testable import GitHubPetCore

private let accountA = try! ScopeAccount(viewerID: "U_fixture_A")
private let accountB = try! ScopeAccount(viewerID: "U_fixture_B")
private let lineTerminators = ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"]
private func mixedScope() throws -> MonitoringScope {
    try MonitoringScope(selected: [MonitoringTarget(organization: "Example"), MonitoringTarget(repository: "example/pet")])
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
        let ten = try (0..<10).map { try MonitoringTarget(organization: "fixture\($0)") }
        #expect(try MonitoringScope(selected: ten).targets.count == 10)
        #expect(throws: ScopeValidationError.tooManyTargets) {
            try MonitoringScope(selected: ten + [MonitoringTarget(organization: "extra")])
        }
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
    @Test func oneOperationBindsViewerMetadataAndPerInclusionSearches() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        #expect(plan.searches.count == 4)
        let query = try #require(plan.arguments.first { $0.hasPrefix("query=") })
        #expect(query.contains("viewer { id login }"))
        #expect(query.contains("organization(login: $owner0)"))
        #expect(query.contains("repository(owner: $owner1, name: $name1)"))
        #expect(!query.contains("example"), "all target values are GraphQL variables")
        #expect(plan.arguments.contains("reviews0=is:pr is:open review-requested:@me org:example"))
        #expect(plan.arguments.contains("reviews1=is:pr is:open review-requested:@me repo:example/pet"))
        #expect(plan.arguments.prefix(4) == ["api", "graphql", "--hostname", "github.com"])
        #expect(try ScopeQueryPlan().searches.count == 2)
        let ten = try MonitoringScope(selected: (0..<10).map { try MonitoringTarget(organization: "fixture\($0)") })
        #expect(try ScopeQueryPlan(scope: ten, expectedAccount: accountA).searches.count == 20)
        #expect(throws: ScopeValidationError.invalidIdentity) { try ScopeQueryPlan(scope: mixedScope()) }
    }

    @Test func verifiedEmptyDiffersFromUnavailableTarget() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        var body = envelope(plan)
        let empty = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(empty.complete && empty.items.isEmpty)
        body["target0"] = NSNull()
        let partial = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(!partial.complete && partial.issues.contains(.targetUnavailable(0)))
        body["target1"] = NSNull()
        #expect(ScopedResponseParser.parse(try response(body), plan: plan).successfulSources == 0)
    }

    @Test func overlapProducesOneStableItemAndOneEvent() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        var body = envelope(plan)
        body["reviews0"] = page([row()]); body["reviews1"] = page([row()])
        let result = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(result.complete && result.items.count == 1)
        #expect(result.items.first?.id == "reviewRequest:PR_fixture_1")
        let engine = InboxEngine(), now = Date(timeIntervalSince1970: 1000)
        #expect(engine.apply(result.outcome, now: now).isEmpty)
        body["reviews0"] = page([row(), row("PR_fixture_2")]); body["reviews1"] = page([row(), row("PR_fixture_2")])
        let changed = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(changed.complete && changed.items.count == 2)
        #expect(engine.apply(changed.outcome, now: now + 1).map(\.item.id) == ["reviewRequest:PR_fixture_2"])
        #expect(engine.apply(changed.outcome, now: now + 2).isEmpty)
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

    @Test func verifiedOrganizationCoverageCountsHiddenMatchesOncePerCategory() throws {
        let org = try MonitoringTarget(organization: "ExAmPlE")
        let repo = try MonitoringTarget(repository: "EXAMPLE/Pet")
        for targets in [[org, repo], [repo, org]] {
            let plan = try ScopeQueryPlan(scope: MonitoringScope(selected: targets), expectedAccount: accountA)
            for kind in [ItemKind.reviewRequest, .assignedIssue] {
                var body = envelope(plan)
                for (index, target) in plan.scope.targets.enumerated() {
                    var metadata = body["target\(index)"] as! [String: Any]
                    metadata[target.kind == .organization ? "login" : "nameWithOwner"] =
                        target.kind == .organization ? "EXAMPLE" : "Example/PET"
                    body["target\(index)"] = metadata
                }
                for search in plan.searches where search.kind == kind { body[search.alias] = page([], total: 1) }
                let result = ScopedResponseParser.parse(try response(body), plan: plan)
                #expect(result.complete && result.items.isEmpty && result.hidden == 1)
                let engine = InboxEngine()
                #expect(engine.apply(result.outcome, now: Date()).isEmpty)
                #expect(engine.state == .hiddenOnly(1), "Hidden-only overlap must never become All clear or double-count")
            }
        }

        // Multiple covered repositories add no duplicate count; unrelated owners and the
        // disjoint issue/review categories still contribute independently. Visible IDs dedupe.
        let targets = try [org, repo, MonitoringTarget(repository: "example/tools"),
                           MonitoringTarget(repository: "other/pet")]
        let plan = try ScopeQueryPlan(scope: MonitoringScope(selected: targets), expectedAccount: accountA)
        var body = envelope(plan)
        for search in plan.searches {
            let target = plan.scope.targets[search.targetIndex!]
            if target.owner == "other" {
                body[search.alias] = page([], total: search.kind == .reviewRequest ? 2 : 0)
            } else if search.kind == .reviewRequest {
                body[search.alias] = page([row(repo: "example/pet")], total: 4)
                if target.name == "tools" { body[search.alias] = page([], total: 1) }
            } else { body[search.alias] = page([], total: 5) }
        }
        let result = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(result.complete && result.items.count == 1 && result.hidden == 10)
    }

    /// #35 MED-1: a covered repository reporting more hidden matches than its organization in the
    /// same category is a contradiction, so it must not be dropped into an All clear.
    @Test func coveredRepositoryHiddenAboveItsOrganizationIsPartialNeverAllClear() throws {
        let org = try MonitoringTarget(organization: "example")
        let repo = try MonitoringTarget(repository: "example/pet")
        for targets in [[org, repo], [repo, org]] {
            let plan = try ScopeQueryPlan(scope: MonitoringScope(selected: targets), expectedAccount: accountA)
            let orgIndex = plan.scope.targets.firstIndex(of: org)!, repoIndex = plan.scope.targets.firstIndex(of: repo)!
            for kind in [ItemKind.reviewRequest, .assignedIssue] {
                let prefix = kind == .reviewRequest ? "reviews" : "assigned"
                for (orgHidden, repoHidden, contradiction) in [(0, 3, true), (2, 3, true), (3, 3, false), (5, 3, false)] {
                    var body = envelope(plan)
                    for search in plan.searches { body[search.alias] = page([], total: 0) }
                    body[prefix + String(orgIndex)] = page([], total: orgHidden)
                    body[prefix + String(repoIndex)] = page([], total: repoHidden)
                    let result = ScopedResponseParser.parse(try response(body), plan: plan)
                    let engine = InboxEngine()
                    _ = engine.apply(result.outcome, now: Date())
                    if contradiction {
                        #expect(!result.complete && result.hidden == 0, "\(prefix) org \(orgHidden) < repo \(repoHidden)")
                        #expect(result.issues.contains(.capped(prefix + String(repoIndex))))
                        #expect(engine.state == .partial, "never All clear or a trusted hidden count")
                    } else {
                        #expect(result.complete && result.hidden == orgHidden, "\(prefix) org \(orgHidden) covers repo \(repoHidden)")
                        #expect(engine.state == .hiddenOnly(orgHidden))
                    }
                }
            }
        }
    }

    @Test func overlappingAliasesStillFailClosedForEveryQualityAndIdentityGuard() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        let org = plan.scope.targets.firstIndex { $0.kind == .organization }!
        let repo = plan.scope.targets.firstIndex { $0.kind == .repository }!
        let full = (1...ScopeQueryPlan.rowsPerCategory).map { row("PR_fixture_\($0)") as Any }
        for kind in [ItemKind.reviewRequest, .assignedIssue] {
            let prefix = kind == .reviewRequest ? "reviews" : "assigned"
            for defect in ["missing", "cap", "contradiction", "row", "metadata", "unverified-org", "error", "account"] {
                var body = envelope(plan)
                body[prefix + String(org)] = page([], total: 1)
                body[prefix + String(repo)] = page([], total: 1)
                var errors: [[String: Any]]?
                var validRow = row()
                if kind == .assignedIssue {
                    validRow["__typename"] = "Issue"
                    validRow["url"] = "https://github.com/example/pet/issues/1"
                }
                switch defect {
                case "missing": body.removeValue(forKey: prefix + String(repo))
                case "cap": body[prefix + String(repo)] = page([], total: 1, more: true)
                case "contradiction": body[prefix + String(repo)] = page([validRow], total: 0)
                case "row": body[prefix + String(repo)] = page([NSNull()], total: 2)
                case "metadata": body["target\(repo)"] = ["__typename": "Repository", "id": "R_fixture", "nameWithOwner": "different/pet"]
                case "unverified-org": body.removeValue(forKey: "target\(org)")
                case "error": errors = [["message": "fixture failure"]]
                default: body["viewer"] = ["id": accountB.viewerID, "login": "other-user"]
                }
                let result = ScopedResponseParser.parse(try response(body, errors: errors), plan: plan)
                #expect(!result.complete && result.hidden == 0, "\(prefix) \(defect) must remain unverified")
            }
        }
        // A full-page cap must also survive exclusion of the repository's hidden contribution.
        var body = envelope(plan)
        body["reviews\(org)"] = page([], total: 1)
        body["reviews\(repo)"] = page(full, total: 40)
        let capped = ScopedResponseParser.parse(try response(body), plan: plan)
        #expect(!capped.complete && capped.hidden == 0 && capped.issues.contains(.capped("reviews\(repo)")))
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
