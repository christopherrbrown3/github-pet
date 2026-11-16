import Foundation
import Testing
@testable import GitHubPetCore

/// Records argv and replies from a script keyed by the first two arguments.
private final class FakeRunner: CommandRunner, @unchecked Sendable {
    var replies: [String: CommandResult] = [:]
    /// Answers before `replies` when it returns a result (full argv in hand).
    var handler: (([String]) -> CommandResult?)?
    var beforeReply: (([String], TimeInterval) -> Void)?
    var throwing: Error?
    private(set) var calls: [(URL, [String])] = []

    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append((executable, arguments))
        beforeReply?(arguments, timeout)
        if let throwing { throw throwing }
        if let answer = handler?(arguments) { return answer }
        return replies[arguments.prefix(2).joined(separator: " ")] ?? CommandResult(exitCode: 127)
    }
}

/// Records the client's actual shared budget while forwarding accounting to the shipped
/// protocol implementation on the existing in-memory runner (no duplicate budget logic).
private final class RecordingLegacyBudgetRunner: CommandRunner, @unchecked Sendable {
    let fixture: FakeRunner
    private(set) var budgets: [CommandBudget] = []
    private(set) var remainingBeforeCommand: [TimeInterval] = []
    private(set) var bytesBeforeCommand: [Int] = []
    init(_ fixture: FakeRunner) { self.fixture = fixture }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        try fixture.run(executable: executable, arguments: arguments, timeout: timeout)
    }
    func run(executable: URL, arguments: [String], budget: CommandBudget) throws -> CommandResult {
        budgets.append(budget) // Keep references alive so pointer reuse cannot fake shared identity.
        remainingBeforeCommand.append(budget.remaining)
        bytesBeforeCommand.append(budget.consumedBytes)
        return try fixture.run(executable: executable, arguments: arguments, budget: budget)
    }
}

private func locator(_ path: String?) -> GhLocator {
    GhLocator(environment: ["PATH": "/usr/bin:/bin"], isExecutable: { $0 == path })
}

/// A GraphQL response: viewer login plus the two searches (nil search = errored alias).
private func graphQL(login: String? = "first-user", reviews: [String]? = [], reviewTotal: Int? = nil,
                     assigned: [String]? = [], assignedTotal: Int? = nil) -> Data {
    func search(_ nodes: [String]?, _ total: Int?) -> String {
        guard let nodes else { return "null" }
        return #"{"issueCount":\#(total ?? nodes.count),"nodes":[\#(nodes.joined(separator: ","))]}"#
    }
    let viewer = login.map { #"{"login":"\#($0)"}"# } ?? "null"
    return Data(#"{"data":{"viewer":\#(viewer),"reviews":\#(search(reviews, reviewTotal)),"assigned":\#(search(assigned, assignedTotal))}}"#.utf8)
}

private func node(_ number: Int, repo: String = "example/repo", url: String? = nil, id: String? = nil) -> String {
    let link = url ?? "https://github.com/\(repo)/pull/\(number)"
    let nodeID = id ?? "N_\(repo.replacingOccurrences(of: "/", with: "_"))_\(number)"
    return #"{"id":"\#(nodeID)","number":\#(number),"title":"Item \#(number)","url":"\#(link)","updatedAt":"2026-11-12T10:00:00Z","repository":{"nameWithOwner":"\#(repo)"}}"#
}

private func graphQLWithErrors(_ rawErrors: String, reviews: [String] = []) -> Data {
    let json = String(decoding: graphQL(reviews: reviews), as: UTF8.self)
    return Data((json.dropLast() + ",\"errors\":" + rawErrors + "}").utf8)
}


@Suite struct GhLocatorTests {
    @Test func overrideIsTheOnlyCandidate() {
        let locator = GhLocator(environment: ["GITHUB_PET_GH_PATH": "/nonexistent/gh", "PATH": "/opt/homebrew/bin"],
                                isExecutable: { _ in false })
        #expect(locator.candidates == ["/nonexistent/gh"])
        #expect(locator.locate() == nil)
    }

    @Test func searchesHomebrewThenAbsolutePathEntriesOnly() {
        let locator = GhLocator(environment: ["PATH": "relative/bin:/usr/bin:/opt/homebrew/bin"],
                                isExecutable: { $0 == "/usr/bin/gh" })
        #expect(locator.candidates == ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"])
        #expect(locator.locate()?.path == "/usr/bin/gh")
    }
}

@Suite struct GhClientTests {
    @Test func missingGhIsReportedWithoutRunningAnything() {
        let runner = FakeRunner()
        let client = GhClient(locator: locator(nil), runner: runner)
        #expect(client.authState() == .missing)
        #expect(client.fetch() == .failure(.ghMissing))
        #expect(runner.calls.isEmpty)
    }

    @Test func loggedOutGhIsUnauthenticated() {
        let runner = FakeRunner()
        runner.replies["auth status"] = CommandResult(exitCode: 1, stderr: Data("You are not logged into any GitHub hosts. To log in, run: gh auth login".utf8))
        let client = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: runner)
        #expect(client.authState() == .unauthenticated)
        #expect(client.fetch() == .failure(.unauthenticated))
        #expect(runner.calls.first?.1 == ["auth", "status", "--active", "--hostname", "github.com"])
    }

    @Test func onlyTheActiveAccountIsChecked() {
        // A valid active account with an expired inactive one: plain `auth status` fails, --active passes.
        let runner = FakeRunner()
        runner.handler = { args in
            guard args.starts(with: ["auth", "status"]) else { return nil }
            return args.contains("--active")
                ? CommandResult(exitCode: 0)
                : CommandResult(exitCode: 1, stderr: Data("X Failed to log in to github.com account old-user".utf8))
        }
        runner.replies["api graphql"] = CommandResult(exitCode: 0, stdout: graphQL(reviews: [node(1)]))
        let client = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: runner)
        #expect(client.authState() == .authenticated)
        guard case .snapshot(let items, true, _) = client.fetch() else {
            Issue.record("expected the active account's items")
            return
        }
        #expect(items.count == 1)
    }

    @Test func oldGhWithoutActiveFlagLetsTheRequestDecide() {
        let runner = FakeRunner()
        runner.replies["auth status"] = CommandResult(exitCode: 1, stderr: Data("unknown flag: --active".utf8))
        runner.replies["api graphql"] = CommandResult(exitCode: 4)
        let client = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: runner)
        #expect(client.authState() == .authenticated, "preflight is advisory on an old gh")
        #expect(client.fetch() == .failure(.unauthenticated), "the request still maps exit 4 to signed out")
    }

    @Test func exitCodeFourMeansAuthRequired() {
        #expect(GhClient.isAuthFailure(CommandResult(exitCode: 4)))
        #expect(!GhClient.isAuthFailure(CommandResult(exitCode: 2)))
    }

    private func client(_ reply: CommandResult, path: String = "/opt/homebrew/bin/gh") -> (GhClient, FakeRunner) {
        let runner = FakeRunner()
        runner.replies["auth status"] = CommandResult(exitCode: 0)
        runner.replies["api graphql"] = reply
        return (GhClient(locator: locator(path), runner: runner), runner)
    }

    @Test func oneRequestReturnsAccountAndItemsWithStableIDs() {
        let reply = CommandResult(exitCode: 0, stdout: graphQL(login: "second-user",
                                                               reviews: [node(12), node(3, url: "javascript:alert(1)")],
                                                               assigned: [node(7, repo: "example/other")]))
        let (client, runner) = client(reply)
        let fetch = client.fetchWithAccount()
        guard case .snapshot(let items, let complete, _) = fetch.outcome else {
            Issue.record("expected snapshot")
            return
        }
        #expect(fetch.account == "second-user")
        #expect(complete)
        #expect(items.map(\.id) == ["reviewRequest:N_example_repo_12", "reviewRequest:N_example_repo_3",
                                     "assignedIssue:N_example_other_7"])
        #expect(items.map(\.repository) == ["example/repo", "example/repo", "example/other"])
        #expect(items[0].url?.absoluteString == "https://github.com/example/repo/pull/12")
        #expect(items[1].url == nil, "unsafe link is dropped at parse time")
        // Exactly two gh calls: the auth check and ONE request for account + both searches.
        let commands = runner.calls.map { Array($0.1.prefix(2)) }
        #expect(commands == [["auth", "status"], ["api", "graphql"]])
        let query = runner.calls[1].1.last ?? ""
        #expect(query.hasPrefix("query=") && query.contains("viewer { login }"))
        #expect(query.contains("review-requested:@me") && query.contains("assignee:@me") && query.contains("is:open"))
        #expect(query.components(separatedBy: "{ id number").count == 3, "both fragments request the node id")
        #expect(runner.calls.allSatisfy { $0.0.path == "/opt/homebrew/bin/gh" })
    }

    @Test func accountAlwaysComesFromTheSameResponseAsItsItems() {
        // gh auth switch A -> B -> A between polls: each poll's items carry that poll's own login,
        // so no poll can mix accounts or tag one account's items with another's login.
        for (login, repo) in [("user-a", "a/repo"), ("user-b", "b/repo"), ("user-a", "a/repo")] {
            let (client, _) = client(CommandResult(exitCode: 0, stdout: graphQL(login: login, reviews: [node(1, repo: repo)])))
            let fetch = client.fetchWithAccount()
            #expect(fetch.account == login)
            let nodeID = "N_\(repo.replacingOccurrences(of: "/", with: "_"))_1"
            #expect(fetch.outcome == .snapshot(items: [InboxItem(id: "reviewRequest:\(nodeID)", kind: .reviewRequest,
                                                                 repository: repo, title: "Item 1",
                                                                 url: URL(string: "https://github.com/\(repo)/pull/1"),
                                                                 updatedAt: Date(timeIntervalSince1970: 1_794_477_600))],
                                               complete: true))
        }
    }

    @Test func repositoryRenameKeepsTheItemsIdentity() {
        // Same review request (node id) before and after its repository is renamed.
        let before = GhGraphQLParser.parse(graphQL(reviews: [node(5, repo: "old-org/repo", id: "PR_kwStable5")]))?.reviews?.items
        let after = GhGraphQLParser.parse(graphQL(reviews: [node(5, repo: "new-org/renamed", id: "PR_kwStable5")]))?.reviews?.items
        #expect(before?.map(\.id) == ["reviewRequest:PR_kwStable5"] && before?.map(\.id) == after?.map(\.id))
        #expect(after?.first?.repository == "new-org/renamed", "the name is display metadata")
        // So the engine doesn't announce it again.
        let engine = InboxEngine()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        engine.apply(.snapshot(items: before ?? [], complete: true), now: t0)
        #expect(engine.apply(.snapshot(items: after ?? [], complete: true), now: t0 + 60).isEmpty)
    }

    @Test func nodesWithoutAnIDAreSkipped() {
        let page = GhGraphQLParser.parse(graphQL(reviews: [#"{"number":1,"title":"x","url":"https://github.com/a/b/pull/1","updatedAt":"2026-11-12T10:00:00Z","repository":{"nameWithOwner":"a/b"}}"#]))
        #expect(page?.reviews?.items.isEmpty == true)
    }

    @Test func oneFailedSearchMakesSnapshotPartial() {
        let (client, _) = client(CommandResult(exitCode: 1, stdout: graphQL(reviews: [node(12)], assigned: nil)))
        guard case .snapshot(let items, false, _) = client.fetch() else {
            Issue.record("expected partial snapshot")
            return
        }
        #expect(items.count == 1)
    }

    @Test func nonzeroExitNeverMakesValidPagesComplete() {
        for rows in [[], [node(12)]] as [[String]] {
            let fetch = client(CommandResult(exitCode: 7, stdout: graphQL(reviews: rows))).0.fetchWithAccount()
            #expect(fetch.account == "first-user", "identity still belongs to the same response")
            guard case .snapshot(let items, let complete, _) = fetch.outcome else {
                Issue.record("valid response pages should remain available as partial data"); continue
            }
            #expect(!complete && items.count == rows.count)
            let engine = InboxEngine()
            engine.apply(fetch.outcome, now: Date(timeIntervalSince1970: 1000))
            #expect(engine.state == .partial && !engine.state.countIsKnown, "never verified empty")
        }
    }

    @Test func graphQLErrorMemberCannotMakeCompleteDataEvenAtExitZero() {
        // Presence fails closed, including malformed/null/empty errors members. Proven data
        // remains usable; the server's raw error messages never become source success.
        for errors in [#"[{"message":"fixture failure"}]"#, #""malformed""#, "{}", "null", "[]", "[null]", "[{}]", "true", "0"] {
            for rows in [[], [node(12)]] as [[String]] {
                let fetch = client(CommandResult(exitCode: 0, stdout: graphQLWithErrors(errors, reviews: rows))).0.fetchWithAccount()
                #expect(fetch.account == "first-user")
                guard case .snapshot(let items, false, _) = fetch.outcome else {
                    Issue.record("errors member must preserve valid pages only as partial: \(errors)"); continue
                }
                #expect(items.count == rows.count)
            }
        }
    }

    @Test func realGhFixtureExitAndErrorQualityKeepsValidZeroControl() throws {
        let cases: [(exit: Int, rows: [String], errors: String?, complete: Bool)] = [
            (7, [], nil, false), (7, [node(12)], nil, false),
            (0, [], #"[{"message":"fixture error"}]"#, false), (0, [], nil, true),
        ]
        for fixture in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("gh")
            let payload = fixture.errors.map { graphQLWithErrors($0, reviews: fixture.rows) } ?? graphQL(reviews: fixture.rows)
            try payload.write(to: directory.appendingPathComponent("payload.json"))
            let script = "#!/bin/sh\nif [ \"$1\" = auth ]; then exit 0; fi\n/bin/cat \"${0%/*}/payload.json\"\nexit \(fixture.exit)\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let gh = GhClient(locator: GhLocator(environment: [GhLocator.overrideVariable: executable.path]))
            let fetch = gh.fetchWithAccount()
            #expect(fetch.account == "first-user")
            guard case .snapshot(let items, let complete, _) = fetch.outcome else {
                Issue.record("expected fixture pages"); continue
            }
            #expect(complete == fixture.complete && items.count == fixture.rows.count)
        }
    }

    @Test func legacyIncompleteAuthOrQueryCannotAcceptValidEmptyPayload() {
        for incompleteAuth in [true, false] {
            let fixture = FakeRunner()
            fixture.replies["auth status"] = CommandResult(exitCode: 0, stdout: graphQL(), outputComplete: !incompleteAuth)
            fixture.replies["api graphql"] = CommandResult(exitCode: 0, stdout: graphQL(), outputComplete: incompleteAuth)
            let gh = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: fixture)
            let fetch = gh.fetchWithAccount()
            #expect(fetch.account == nil)
            if case .failure(.failed) = fetch.outcome {} else { Issue.record("incomplete output must fail, not return an empty snapshot") }
            #expect(fixture.calls.count == (incompleteAuth ? 1 : 2))
            if incompleteAuth {
                #expect(!fixture.calls.contains { $0.1.starts(with: ["api", "graphql"]) }, "incomplete auth cannot launch query")
            }
        }
    }

    @Test func legacyAggregatePreflightQueryBytesShareOneBudgetAndKeepExactControl() {
        let payload = graphQL(), preflightBytes = CommandBudget.maximumBytes / 2
        for extraByte in [0, 1] {
            let fixture = FakeRunner()
            fixture.replies["auth status"] = CommandResult(exitCode: 0,
                stdout: Data(count: preflightBytes / 2), stderr: Data(count: preflightBytes / 2))
            fixture.replies["api graphql"] = CommandResult(exitCode: 0, stdout: payload,
                stderr: Data(count: CommandBudget.maximumBytes - preflightBytes - payload.count + extraByte))
            let recorded = RecordingLegacyBudgetRunner(fixture)
            let fetch = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: recorded).fetchWithAccount()
            #expect(recorded.budgets.count == 2 && recorded.budgets[0] === recorded.budgets[1])
            #expect(recorded.remainingBeforeCommand.count == 2 && recorded.remainingBeforeCommand[1] <= recorded.remainingBeforeCommand[0])
            #expect(recorded.bytesBeforeCommand == [0, preflightBytes], "preflight stdout+stderr debit carries into query")
            if extraByte == 0 {
                #expect(fetch.account == "first-user" && fetch.outcome == .snapshot(items: [], complete: true),
                        "full valid zero-row control at exact aggregate limit remains complete")
            } else {
                #expect(fetch.account == nil)
                if case .failure(.failed) = fetch.outcome {} else { Issue.record("aggregate +1 byte must fail before parsing valid JSON") }
            }
        }
    }

    @Test func legacyExhaustedPreflightDeadlineNeverLaunchesQuery() {
        let fixture = FakeRunner()
        fixture.replies["auth status"] = CommandResult(exitCode: 0)
        fixture.replies["api graphql"] = CommandResult(exitCode: 0, stdout: graphQL())
        fixture.beforeReply = { arguments, remaining in
            if arguments.starts(with: ["auth", "status"]) {
                // Consume the supplied remaining monotonic budget synchronously. No cooperative
                // continuation or cancellation ordering; scheduler overshoot is also exhaustion.
                _ = DispatchSemaphore(value: 0).wait(timeout: .now() + remaining)
            }
        }
        let fetch = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: fixture, timeout: 0.05).fetchWithAccount()
        #expect(fetch.account == nil)
        if case .failure(.failed) = fetch.outcome {} else { Issue.record("exhausted preflight must fail") }
        #expect(fixture.calls.count <= 1 && !fixture.calls.contains { $0.1.starts(with: ["api", "graphql"]) })
    }

    @Test func legacyQueryDeadlineCannotTurnLateValidJSONIntoCompleteEmpty() {
        let fixture = FakeRunner()
        fixture.replies["auth status"] = CommandResult(exitCode: 0)
        fixture.replies["api graphql"] = CommandResult(exitCode: 0, stdout: graphQL())
        fixture.beforeReply = { arguments, remaining in
            if arguments.starts(with: ["api", "graphql"]) {
                _ = DispatchSemaphore(value: 0).wait(timeout: .now() + remaining)
            }
        }
        let recorded = RecordingLegacyBudgetRunner(fixture)
        let fetch = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: recorded, timeout: 0.05).fetchWithAccount()
        #expect(fetch.account == nil)
        if case .failure(.failed) = fetch.outcome {} else { Issue.record("expired query must reject its superficially valid empty JSON") }
        if recorded.budgets.count == 2 { #expect(recorded.budgets[0] === recorded.budgets[1]) }
        // If load exhausted the budget before query launch, failing without the query is correct.
        #expect(fixture.calls.filter { $0.1.starts(with: ["api", "graphql"]) }.count <= 1)
    }

    @Test func moreMatchesThanTheCapIsPartial() {
        let rows = (1...GhClient.searchLimit).map { node($0) }
        let (capped, runner) = client(CommandResult(exitCode: 0, stdout: graphQL(reviews: rows, reviewTotal: 31)))
        guard case .snapshot(let items, let complete, _) = capped.fetch() else {
            Issue.record("expected snapshot")
            return
        }
        #expect(items.count == GhClient.searchLimit)
        #expect(!complete, "issueCount 31 > 30 returned: more matches are hidden")
        #expect(runner.calls[1].1.last?.contains("first: \(GhClient.searchLimit)") == true)
        // Exactly 30 matches is complete (the old row-count rule couldn't tell).
        let (exact, _) = client(CommandResult(exitCode: 0, stdout: graphQL(reviews: rows, reviewTotal: 30)))
        guard case .snapshot(_, true, _) = exact.fetch() else {
            Issue.record("expected complete snapshot")
            return
        }
    }

    /// #35 decision table for the legacy client (no pageInfo: a full page with a larger count is the cap).
    @Test func hiddenMatchesAreInformationalAndUnclearResultsStayPartial() {
        func outcome(_ reply: CommandResult) -> FetchOutcome { client(reply).0.fetch() }
        // Rows plus hidden in both searches: complete for visible results, hidden summed.
        let rows = outcome(CommandResult(exitCode: 0, stdout: graphQL(reviews: [node(1)], reviewTotal: 3, assigned: [], assignedTotal: 2)))
        guard case .snapshot(let items, true, 4) = rows else { Issue.record("complete, hidden 4: \(rows)"); return }
        #expect(items.count == 1)
        // Zero visible with hidden matches: complete, nothing shown, hidden count kept.
        #expect(outcome(CommandResult(exitCode: 0, stdout: graphQL(reviews: [], reviewTotal: 5))) == .snapshot(items: [], complete: true, hidden: 5))
        // Capped: a full page with more matches is Partial without a hidden count.
        let full = (1...GhClient.searchLimit).map { node($0) }
        guard case .snapshot(_, false, 0) = outcome(CommandResult(exitCode: 0, stdout: graphQL(reviews: full, reviewTotal: 40))) else {
            Issue.record("capped stays Partial"); return
        }
        // Unclear: nonzero exit, an errors member, a dropped malformed node, or a missing search.
        let unclear: [CommandResult] = [
            CommandResult(exitCode: 1, stdout: graphQL(reviews: [node(1)], reviewTotal: 3)),
            CommandResult(exitCode: 0, stdout: graphQLWithErrors("[]", reviews: [node(1)])),
            CommandResult(exitCode: 0, stdout: graphQL(reviews: [node(1), #"{"number":2}"#], reviewTotal: 4)),
            CommandResult(exitCode: 0, stdout: graphQL(reviews: [node(1)], reviewTotal: 3, assigned: nil)),
        ]
        for reply in unclear {
            guard case .snapshot(_, false, 0) = outcome(reply) else { Issue.record("unclear stays Partial: \(reply.exitCode)"); continue }
        }
        // Exact: complete and nothing hidden.
        #expect(outcome(CommandResult(exitCode: 0, stdout: graphQL(reviews: [node(1)]))) == .snapshot(items: GhGraphQLParser.parse(graphQL(reviews: [node(1)]))!.reviews!.items, complete: true))
    }

    @Test func contradictoryTotalsInEitherCategoryKeepVisibleRowsPartialWithoutHiddenCounts() {
        for (reviewTotal, assignedTotal) in [(4, 0), (0, 4)] {
            let result = client(CommandResult(exitCode: 0, stdout: graphQL(
                reviews: [node(1)], reviewTotal: reviewTotal,
                assigned: [node(2)], assignedTotal: assignedTotal))).0.fetch()
            guard case .snapshot(let items, false, 0) = result else {
                Issue.record("Contradictory totals must stay Partial, without a trusted hidden count: \(result)")
                continue
            }
            #expect(items.count == 2, "Usable rows survive a contradictory total")
        }
        // Exact totals, including an empty category, remain verified controls.
        let exact = client(CommandResult(exitCode: 0, stdout: graphQL(
            reviews: [node(1)], reviewTotal: 1, assigned: [], assignedTotal: 0))).0.fetch()
        guard case .snapshot(let items, true, 0) = exact else { Issue.record("Exact totals remain complete"); return }
        #expect(items.count == 1)
    }

    @Test func bothSearchesFailingOrMalformedOutputIsAnError() {
        let (both, _) = client(CommandResult(exitCode: 1, stdout: graphQL(reviews: nil, assigned: nil)))
        #expect(both.fetch() == .failure(.failed("GitHub search failed")))
        let (malformed, _) = client(CommandResult(exitCode: 0, stdout: Data("{oops".utf8)))
        #expect(malformed.fetch() == .failure(.failed("GitHub search failed")))
    }

    @Test func missingViewerIsAFailureNotAnEmptyInbox() {
        let fetch = client(CommandResult(exitCode: 0, stdout: graphQL(login: nil))).0.fetchWithAccount()
        #expect(fetch.account == nil)
        #expect(fetch.outcome == .failure(.failed("GitHub search failed")))
    }

    @Test func authFailureOnTheRequestIsUnauthenticated() {
        #expect(client(CommandResult(exitCode: 4)).0.fetch() == .failure(.unauthenticated))
        let notLoggedIn = CommandResult(exitCode: 1, stderr: Data("To get started with GitHub CLI, please run:  gh auth login".utf8))
        #expect(client(notLoggedIn).0.fetch() == .failure(.unauthenticated))
    }

    @Test func launchFailureIsTreatedAsMissing() {
        let runner = FakeRunner()
        runner.throwing = CommandError.launchFailed("no such file")
        let client = GhClient(locator: locator("/usr/local/bin/gh"), runner: runner)
        #expect(client.authState() == .missing)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ProcessRunnerTests {
    @Test func argumentsAreNeverInterpretedByAShell() throws {
        let tricky = "a; echo injected $(whoami) `id` > /dev/null | cat"
        let result = try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/echo"),
                                                    arguments: [tricky], timeout: 5)
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == tricky + "\n")
    }

    @Test func nonzeroExitAndStderrAreCaptured() throws {
        let result = try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/ls"),
                                                    arguments: ["/definitely/not/here"], timeout: 5)
        #expect(result.exitCode != 0)
        #expect(!result.stderr.isEmpty)
    }

    @Test func missingExecutableThrowsLaunchFailed() {
        #expect(throws: CommandError.self) {
            try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/nonexistent/gh"),
                                           arguments: [], timeout: 5)
        }
    }

    @Test func searchesArePinnedToGitHubDotCom() throws {
        // The launching shell may point GH_HOST at another host; the child must not inherit it.
        let result = try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/env"),
                                                    arguments: [], timeout: 5)
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("GH_HOST=") } == ["GH_HOST=github.com"])
    }

    @Test func descendantHoldingThePipeDoesNotLeakReadsOrDescriptors() throws {
        func openDescriptors() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
        }
        let before = openDescriptors()
        let clock = ContinuousClock()
        let started = clock.now
        // The shell exits at once; its background child keeps stdout and stderr open for 5 s.
        let result = try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                    arguments: ["-c", "sleep 5 & echo hi"], timeout: 5)
        #expect(started.duration(to: clock.now) < .milliseconds(4500), "collector deadline, not the descendant, bounds the wait")
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hi\n", "bytes read before the deadline are kept")
        #expect(openDescriptors() <= before, "both pipe read ends are closed")
    }

    @Test func timeoutTerminatesTheChild() {
        #expect(throws: CommandError.timedOut) {
            try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                           arguments: ["10"], timeout: 0.3)
        }
    }
}
