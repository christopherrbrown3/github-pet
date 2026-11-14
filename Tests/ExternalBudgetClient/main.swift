// Deliberately compiled as a separate client with NORMAL import, never @testable.
import Foundation
import GitHubPetCore

struct ExternalChunkRunner: CommandRunner {
    let output: [Data]
    let errors: [Data]
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        try run(executable: executable, arguments: arguments, budget: CommandBudget(timeout: timeout))
    }
    func run(executable: URL, arguments: [String], budget: CommandBudget) throws -> CommandResult {
        var stdout = Data(), stderr = Data()
        for chunk in output {
            try budget.check()
            guard budget.reserve(chunk.count) else { throw CommandError.outputLimitExceeded }
            stdout.append(chunk)
        }
        for chunk in errors {
            try budget.check()
            guard budget.reserve(chunk.count) else { throw CommandError.outputLimitExceeded }
            stderr.append(chunk)
        }
        try budget.check()
        return CommandResult(exitCode: 0, stdout: stdout, stderr: stderr)
    }
}

let executable = URL(fileURLWithPath: "/unused/in-memory-fixture")
let shared = CommandBudget(timeout: 2, maximumBytes: 9)
let first = ExternalChunkRunner(output: [Data("abc".utf8)], errors: [Data("def".utf8)])
let result = try first.run(executable: executable, arguments: [], budget: shared)
precondition(result.stdout.count + result.stderr.count == 6 && shared.consumedBytes == 6)
_ = try ExternalChunkRunner(output: [Data("ghi".utf8)], errors: []).run(executable: executable, arguments: [], budget: shared)
precondition(shared.consumedBytes == 9)
do {
    _ = try ExternalChunkRunner(output: [], errors: [Data("j".utf8)]).run(executable: executable, arguments: [], budget: shared)
    fatalError("external runner accepted aggregate overflow")
} catch { precondition(error as? CommandError == .outputLimitExceeded) }
precondition(shared.consumedBytes == 9)
do { try shared.check(); fatalError("overflow was not latched") }
catch { precondition(error as? CommandError == .outputLimitExceeded) }

let concurrent = CommandBudget(timeout: 2, maximumBytes: 1000)
DispatchQueue.concurrentPerform(iterations: 4) { _ in
    for _ in 0..<250 { precondition(concurrent.reserve(1)) }
}
precondition(concurrent.consumedBytes == 1000 && !concurrent.reserve(1))
let noWithdrawal = CommandBudget()
precondition(!noWithdrawal.reserve(-1) && noWithdrawal.consumedBytes == 0)
do { try CommandBudget(timeout: 0).check(); fatalError("expired external budget succeeded") }
catch { precondition(error as? CommandError == .timedOut) }
print("PASS external normal-import CommandRunner: shared stdout/stderr + commands, typed/latching overflow, atomic accounting and deadline")
