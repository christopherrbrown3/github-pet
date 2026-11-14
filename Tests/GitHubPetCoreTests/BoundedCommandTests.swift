import Foundation
import Testing
@testable import GitHubPetCore

@Suite(.serialized, .timeLimit(.minutes(1))) struct BoundedCommandTests {
    @Test func exactBoundarySucceedsAndOneExtraByteIsTypedOverflow() throws {
        let runner = ProcessCommandRunner()
        let exact = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["12345"],
                                   budget: CommandBudget(timeout: 2, maximumBytes: 5))
        #expect(exact.stdout == Data("12345".utf8) && exact.outputComplete)
        #expect(throws: CommandError.outputLimitExceeded) {
            try runner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["123456"],
                           budget: CommandBudget(timeout: 2, maximumBytes: 5))
        }
    }
    @Test func stdoutAndStderrShareOneCollectionBudget() {
        let budget = CommandBudget(timeout: 5, maximumBytes: 1500)
        #expect(throws: CommandError.outputLimitExceeded) {
            try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", """
                i=0; while [ "$i" -lt 100 ]; do printf '0123456789'; printf '0123456789' >&2; i=$((i+1)); done
                """], budget: budget)
        }
        #expect(budget.consumedBytes <= 1500)
    }
    @Test func neverExitingChattyProducerIsStoppedDuringCollection() {
        let budget = CommandBudget(timeout: 15, maximumBytes: 4096)
        let clock = ContinuousClock(), start = clock.now
        #expect(throws: CommandError.outputLimitExceeded) {
            try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], budget: budget)
        }
        #expect(start.duration(to: clock.now) < .seconds(5), "overflow must not wait for process exit or its 15s timeout")
        #expect(budget.consumedBytes <= 4096)
    }
    @Test func budgetSpansCommandsAndDoesNotResetAfterPreflight() throws {
        let runner = ProcessCommandRunner(), budget = CommandBudget(timeout: 5, maximumBytes: 9)
        _ = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["12345"], budget: budget)
        #expect(throws: CommandError.outputLimitExceeded) {
            try runner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["67890"], budget: budget)
        }
        #expect(budget.consumedBytes <= 9)
    }
    @Test func monotonicDeadlineSpansActualProcesses() throws {
        let runner = ProcessCommandRunner(), budget = CommandBudget(timeout: 0.3)
        #expect(throws: CommandError.timedOut) {
            _ = try runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.2"], budget: budget)
            try runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.2"], budget: budget)
        }
    }
    @Test func descendantPipeDrainIsBoundedAndMarkedIncomplete() throws {
        let runner = ProcessCommandRunner(), start = ContinuousClock.now
        let result = try runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                    arguments: ["-c", "sleep 5 & echo hi"], timeout: 5)
        #expect(result.stdout == Data("hi\n".utf8))
        #expect(!result.outputComplete)
        #expect(start.duration(to: .now) < .seconds(4.5))
    }
    @Test func deadlineAndCancellationTerminateOnlyTheirChild() async {
        #expect(throws: CommandError.timedOut) {
            try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
        }
        let task = Task.detached {
            try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 10)
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; Issue.record("cancelled command succeeded") }
        catch { #expect(error as? CommandError == .cancelled) }
    }
}
