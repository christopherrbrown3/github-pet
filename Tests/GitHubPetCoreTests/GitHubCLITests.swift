import Foundation
import Testing
@testable import GitHubPetCore

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

@Suite struct GhAuthTests {
    @Test func exitCodeFourMeansAuthRequired() {
        #expect(GhAuth.isAuthFailure(CommandResult(exitCode: 4)))
        #expect(!GhAuth.isAuthFailure(CommandResult(exitCode: 2)))
    }

    @Test func signedOutStderrMeansAuthRequired() {
        #expect(GhAuth.isAuthFailure(CommandResult(exitCode: 1, stderr: Data("You are not logged in".utf8))))
        #expect(!GhAuth.isAuthFailure(CommandResult(exitCode: 1, stderr: Data("boom".utf8))))
    }

    @Test func onlyTheActiveAccountIsChecked() {
        #expect(GhAuth.authStatusArguments == ["auth", "status", "--active", "--hostname", "github.com"])
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

    /// /dev/fd is process-wide, so this must run alone in its process: scripts/test.sh (no
    /// arguments) and CI both do that. In a shared parallel run it can flake (#102).
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
