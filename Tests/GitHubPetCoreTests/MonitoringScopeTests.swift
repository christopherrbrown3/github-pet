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
        let suite = "scope.tests.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
    @Test func anyPresentErrorsMemberKeepsScopedParserIncompleteAndRetainsRows() throws {
        let plan = try ScopeQueryPlan(scope: mixedScope(), expectedAccount: accountA)
        for includeRow in [false, true] {
            for errors in scopedErrorShapes {
                let result = ScopedResponseParser.parse(try scopedErrorPayload(plan, includeRow: includeRow, errorsJSON: errors), plan: plan)
                #expect(!result.complete && result.issues == [.graphQLError], "present errors shape \(errors)")
                #expect(result.viewer?.account == accountA && result.items.count == (includeRow ? 1 : 0))
                if case .snapshot(_, false) = result.outcome {} else { Issue.record("errors member cannot produce complete empty/data") }
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

    @Test func malformedRowsCapsAndGraphQLErrorsCannotLookComplete() throws {
        let plan = try ScopeQueryPlan()
        for badPage in [page([row(), NSNull()]), page([row(repo: "outside/pet")], total: 40),
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
