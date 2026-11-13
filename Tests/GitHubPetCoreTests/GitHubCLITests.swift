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

private let searchJSON = """
[{"number":12,"title":"Fix the thing","url":"https://github.com/example/repo/pull/12",
  "repository":{"name":"repo","nameWithOwner":"example/repo"},"updatedAt":"2026-11-12T10:00:00Z"},
 {"number":3,"title":"Evil link","url":"javascript:alert(1)",
  "repository":{"name":"repo","nameWithOwner":"example/repo"},"updatedAt":"2026-11-12T09:00:00Z"}]
"""

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

    @Test func authenticatedFetchUsesArgvAndBuildsStableIDs() {
        let runner = FakeRunner()
        runner.replies["auth status"] = CommandResult(exitCode: 0)
        runner.replies["api user"] = CommandResult(exitCode: 0, stdout: Data("first-user\n".utf8))
        runner.replies["search prs"] = CommandResult(exitCode: 0, stdout: Data(searchJSON.utf8))
        runner.replies["search issues"] = CommandResult(exitCode: 0, stdout: Data("[]".utf8))
        let client = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: runner)
        guard case .snapshot(let items, let complete) = client.fetch() else {
            Issue.record("expected snapshot")
            return
        }
        #expect(complete)
        #expect(items.map(\.id) == ["reviewRequest:example/repo#12", "reviewRequest:example/repo#3"])
        #expect(items[0].url?.absoluteString == "https://github.com/example/repo/pull/12")
        #expect(items[1].url == nil, "unsafe link is dropped at parse time")
        let prs = runner.calls.first { $0.1.starts(with: ["search", "prs"]) }?.1 ?? []
        #expect(prs.contains("--review-requested=@me"))
        #expect(runner.calls.allSatisfy { $0.0.path == "/opt/homebrew/bin/gh" })
    }

    @Test func oneFailingQueryMakesSnapshotPartial() {
        let runner = FakeRunner()
        runner.replies["auth status"] = CommandResult(exitCode: 0)
        runner.replies["api user"] = CommandResult(exitCode: 0, stdout: Data("first-user\n".utf8))
        runner.replies["search prs"] = CommandResult(exitCode: 0, stdout: Data(searchJSON.utf8))
        runner.replies["search issues"] = CommandResult(exitCode: 1, stderr: Data("HTTP 502".utf8))
        let client = GhClient(locator: locator("/usr/local/bin/gh"), runner: runner)
        guard case .snapshot(let items, false) = client.fetch() else {
            Issue.record("expected partial snapshot")
            return
        }
        #expect(items.count == 2)
    }

    private func rows(_ count: Int) -> Data {
        let row = { (n: Int) in
            #"{"number":\#(n),"title":"t\#(n)","url":"https://github.com/example/repo/pull/\#(n)","repository":{"nameWithOwner":"example/repo"},"updatedAt":"2026-11-12T10:00:00Z"}"#
        }
        return Data("[\((1...max(1, count)).map(row).joined(separator: ","))]".utf8)
    }

    @Test func queryAtTheResultCapIsPartial() {
        let runner = FakeRunner()
        runner.replies["auth status"] = CommandResult(exitCode: 0)
        runner.replies["api user"] = CommandResult(exitCode: 0, stdout: Data("first-user\n".utf8))
        runner.replies["search prs"] = CommandResult(exitCode: 0, stdout: rows(GhClient.searchLimit))
        runner.replies["search issues"] = CommandResult(exitCode: 0, stdout: Data("[]".utf8))
        let client = GhClient(locator: locator("/usr/local/bin/gh"), runner: runner)
        guard case .snapshot(let items, let complete) = client.fetch() else {
            Issue.record("expected snapshot")
            return
        }
        #expect(items.count == GhClient.searchLimit)
        #expect(!complete, "a full page may hide more matches")
        let limitArgument = runner.calls.first { $0.1.starts(with: ["search", "prs"]) }?.1.drop { $0 != "--limit" }.dropFirst().first
        #expect(limitArgument == "\(GhClient.searchLimit)")
    }

    @Test func queryBelowTheCapIsComplete() {
        let runner = FakeRunner()
        runner.replies["auth status"] = CommandResult(exitCode: 0)
        runner.replies["api user"] = CommandResult(exitCode: 0, stdout: Data("first-user\n".utf8))
        runner.replies["search prs"] = CommandResult(exitCode: 0, stdout: rows(GhClient.searchLimit - 1))
        runner.replies["search issues"] = CommandResult(exitCode: 0, stdout: Data("[]".utf8))
        let client = GhClient(locator: locator("/usr/local/bin/gh"), runner: runner)
        guard case .snapshot(_, true) = client.fetch() else {
            Issue.record("expected complete snapshot")
            return
        }
    }

    @Test func malformedOutputCountsAsFailure() {
        let runner = FakeRunner()
        runner.replies["auth status"] = CommandResult(exitCode: 0)
        runner.replies["api user"] = CommandResult(exitCode: 0, stdout: Data("first-user\n".utf8))
        runner.replies["search prs"] = CommandResult(exitCode: 0, stdout: Data("{oops".utf8))
        runner.replies["search issues"] = CommandResult(exitCode: 0, stdout: Data("nope".utf8))
        let client = GhClient(locator: locator("/usr/local/bin/gh"), runner: runner)
        #expect(client.fetch() == .failure(.failed("GitHub search failed")))
    }

    @Test func authFailureDuringSearchWins() {
        let runner = FakeRunner()
        runner.replies["auth status"] = CommandResult(exitCode: 0)
        runner.replies["api user"] = CommandResult(exitCode: 0, stdout: Data("first-user\n".utf8))
        runner.replies["search prs"] = CommandResult(exitCode: 4)
        let client = GhClient(locator: locator("/usr/local/bin/gh"), runner: runner)
        #expect(client.fetch() == .failure(.unauthenticated))
    }

    @Test func launchFailureIsTreatedAsMissing() {
        let runner = FakeRunner()
        runner.throwing = CommandError.launchFailed("no such file")
        let client = GhClient(locator: locator("/usr/local/bin/gh"), runner: runner)
        #expect(client.authState() == .missing)
    }
}

@Suite struct GhAccountTests {
    private func authenticatedRunner() -> FakeRunner {
        let runner = FakeRunner()
        runner.replies["auth status"] = CommandResult(exitCode: 0)
        runner.replies["search prs"] = CommandResult(exitCode: 0, stdout: Data("[]".utf8))
        runner.replies["search issues"] = CommandResult(exitCode: 0, stdout: Data("[]".utf8))
        return runner
    }

    @Test func fetchReportsTheActiveAccount() {
        let runner = authenticatedRunner()
        runner.replies["api user"] = CommandResult(exitCode: 0, stdout: Data("second-user\n".utf8))
        let fetch = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: runner).fetchWithAccount()
        #expect(fetch.account == "second-user")
        #expect(fetch.outcome == .snapshot(items: [], complete: true))
        #expect(runner.calls.map(\.1).contains(GhClient.accountArguments))
    }

    @Test func unidentifiedAccountIsAFailureNotAnEmptyInbox() {
        let runner = authenticatedRunner()
        runner.replies["api user"] = CommandResult(exitCode: 1, stderr: Data("HTTP 502".utf8))
        let fetch = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: runner).fetchWithAccount()
        #expect(fetch.account == nil)
        guard case .failure(.failed) = fetch.outcome else {
            Issue.record("expected failure, got \(fetch.outcome)")
            return
        }
        #expect(!runner.calls.contains { $0.1.first == "search" }, "no searches for an unknown account")
    }

    @Test func authFailureWhileIdentifyingIsUnauthenticated() {
        let runner = authenticatedRunner()
        runner.replies["api user"] = CommandResult(exitCode: 4)
        let fetch = GhClient(locator: locator("/opt/homebrew/bin/gh"), runner: runner).fetchWithAccount()
        #expect(fetch.outcome == .failure(.unauthenticated))
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
