import Foundation
import Testing
@testable import GitHubPetCore

/// Records argv and replies from a script keyed by the first two arguments.
private final class FakeRunner: CommandRunner, @unchecked Sendable {
    var replies: [String: CommandResult] = [:]
    var throwing: Error?
    private(set) var calls: [(URL, [String])] = []

    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append((executable, arguments))
        if let throwing { throw throwing }
        return replies[arguments.prefix(2).joined(separator: " ")] ?? CommandResult(exitCode: 127)
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

private func node(_ number: Int, repo: String = "example/repo", url: String? = nil) -> String {
    let link = url ?? "https://github.com/\(repo)/pull/\(number)"
    return #"{"number":\#(number),"title":"Item \#(number)","url":"\#(link)","updatedAt":"2026-11-12T10:00:00Z","repository":{"nameWithOwner":"\#(repo)"}}"#
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
        #expect(runner.calls.first?.1 == ["auth", "status", "--hostname", "github.com"])
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
        guard case .snapshot(let items, let complete) = fetch.outcome else {
            Issue.record("expected snapshot")
            return
        }
        #expect(fetch.account == "second-user")
        #expect(complete)
        #expect(items.map(\.id) == ["reviewRequest:example/repo#12", "reviewRequest:example/repo#3",
                                     "assignedIssue:example/other#7"])
        #expect(items[0].url?.absoluteString == "https://github.com/example/repo/pull/12")
        #expect(items[1].url == nil, "unsafe link is dropped at parse time")
        // Exactly two gh calls: the auth check and ONE request for account + both searches.
        let commands = runner.calls.map { Array($0.1.prefix(2)) }
        #expect(commands == [["auth", "status"], ["api", "graphql"]])
        let query = runner.calls[1].1.last ?? ""
        #expect(query.hasPrefix("query=") && query.contains("viewer { login }"))
        #expect(query.contains("review-requested:@me") && query.contains("assignee:@me") && query.contains("is:open"))
        #expect(runner.calls.allSatisfy { $0.0.path == "/opt/homebrew/bin/gh" })
    }

    @Test func accountAlwaysComesFromTheSameResponseAsItsItems() {
        // gh auth switch A -> B -> A between polls: each poll's items carry that poll's own login,
        // so no poll can mix accounts or tag one account's items with another's login.
        for (login, repo) in [("user-a", "a/repo"), ("user-b", "b/repo"), ("user-a", "a/repo")] {
            let (client, _) = client(CommandResult(exitCode: 0, stdout: graphQL(login: login, reviews: [node(1, repo: repo)])))
            let fetch = client.fetchWithAccount()
            #expect(fetch.account == login)
            #expect(fetch.outcome == .snapshot(items: [InboxItem(id: "reviewRequest:\(repo)#1", kind: .reviewRequest,
                                                                 repository: repo, title: "Item 1",
                                                                 url: URL(string: "https://github.com/\(repo)/pull/1"),
                                                                 updatedAt: Date(timeIntervalSince1970: 1_794_477_600))],
                                               complete: true))
        }
    }

    @Test func oneFailedSearchMakesSnapshotPartial() {
        let (client, _) = client(CommandResult(exitCode: 1, stdout: graphQL(reviews: [node(12)], assigned: nil)))
        guard case .snapshot(let items, false) = client.fetch() else {
            Issue.record("expected partial snapshot")
            return
        }
        #expect(items.count == 1)
    }

    @Test func moreMatchesThanTheCapIsPartial() {
        let rows = (1...GhClient.searchLimit).map { node($0) }
        let (capped, runner) = client(CommandResult(exitCode: 0, stdout: graphQL(reviews: rows, reviewTotal: 31)))
        guard case .snapshot(let items, let complete) = capped.fetch() else {
            Issue.record("expected snapshot")
            return
        }
        #expect(items.count == GhClient.searchLimit)
        #expect(!complete, "issueCount 31 > 30 returned: more matches are hidden")
        #expect(runner.calls[1].1.last?.contains("first: \(GhClient.searchLimit)") == true)
        // Exactly 30 matches is complete (the old row-count rule couldn't tell).
        let (exact, _) = client(CommandResult(exitCode: 0, stdout: graphQL(reviews: rows, reviewTotal: 30)))
        guard case .snapshot(_, true) = exact.fetch() else {
            Issue.record("expected complete snapshot")
            return
        }
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
        let started = Date()
        // The shell exits at once; its background child keeps stdout and stderr open for 5 s.
        let result = try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                    arguments: ["-c", "sleep 5 & echo hi"], timeout: 5)
        #expect(Date().timeIntervalSince(started) < 4.5, "collector deadline, not the descendant, bounds the wait")
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
