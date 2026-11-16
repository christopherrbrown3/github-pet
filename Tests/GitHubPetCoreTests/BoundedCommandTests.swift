import Foundation
import Darwin
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
    @Test func deadlineTerminatesTheChild() {
        #expect(throws: CommandError.timedOut) {
            try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
        }
    }

    @Test func prelaunchCancellationDoesNotSpawnAChild() async throws {
        let directory = try cancellationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let gate = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .high) {
            guard waitForGate(gate) else { throw CommandError.launchFailed("test launch gate") }
            return try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf launched > \"$1\"", "fixture", marker.path], timeout: 10)
        }
        task.cancel()
        gate.signal()
        do { _ = try await task.value; Issue.record("cancelled command succeeded") }
        catch { #expect(error as? CommandError == .cancelled) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func inFlightCancellationUsesChildHandshakeAndIndependentScheduling() async throws {
        let directory = try cancellationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("started")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let fd = open(fifo.path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { Issue.record("could not open child-start handshake"); return }
        var observerOwnsFD = false
        defer { if !observerOwnsFD { close(fd) } }
        let observerDone = DispatchGroup()
        let receipt = CancellationReceipt()

        // A separate test-owned process waits for stdin, rather than expiring on a timer.
        let unrelated = Process(), unrelatedInput = Pipe(), unrelatedEnded = DispatchGroup()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/cat")
        unrelated.standardInput = unrelatedInput
        unrelated.standardOutput = FileHandle.nullDevice; unrelated.standardError = FileHandle.nullDevice
        unrelatedEnded.enter(); unrelated.terminationHandler = { _ in unrelatedEnded.leave() }
        try unrelated.run()
        defer {
            try? unrelatedInput.fileHandleForWriting.close()
            if unrelated.isRunning { unrelated.terminate() }
            if !waitForGroup(unrelatedEnded, seconds: 2), unrelated.isRunning { kill(unrelated.processIdentifier, SIGKILL) }
        }

        let budget = CommandBudget(timeout: 10) // Same command deadline as the original test.
        let task = Task.detached(priority: .high) {
            try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s\\n' $$ > \"$1\"; exec /bin/sleep 10", "fixture", fifo.path], budget: budget)
        }
        // This POSIX readiness wait and cancellation run on a GCD queue, not the cooperative
        // executor that is busy running the synchronous full test suite. No Task.sleep ordering.
        observerDone.enter()
        observerOwnsFD = true
        DispatchQueue(label: "scope.tests.independent-cancellation").async {
            defer { close(fd); observerDone.leave() }
            let pid = waitForChildPID(fd, seconds: 5)
            receipt.record(pid: pid, remaining: budget.remaining)
            task.cancel()
        }
        do { _ = try await task.value; Issue.record("in-flight cancellation succeeded") }
        catch { #expect(error as? CommandError == .cancelled) } // Never accepts timedOut.
        #expect(waitForGroup(observerDone, seconds: 2), "bounded independent observer must finish")
        let observed = receipt.value
        #expect(observed.pid != nil && observed.alive, "actual child-start receipt is required")
        #expect(observed.remaining > 0, "cancellation must precede the active deadline")
        if let pid = observed.pid {
            #expect(pid != unrelated.processIdentifier)
            let status = kill(pid, 0), error = errno
            #expect(status == -1 && error == ESRCH, "cancelled child is gone/reaped")
        }
        #expect(unrelated.isRunning, "cancellation must not signal another process or process group")
    }

    /// Dispatch threads have no Task, so the latched budget flag is the only cancellation signal.
    @Test func latchedBudgetCancellationReachesWorkWithoutATaskContext() {
        let budget = CommandBudget(timeout: 5)
        #expect(!budget.isCancelled)
        budget.cancel(); budget.cancel()
        #expect(budget.isCancelled)
        let group = DispatchGroup(), receipt = ErrorReceipt()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try budget.check() } catch { receipt.record(error) }
        }
        #expect(waitForGroup(group, seconds: 2))
        #expect(receipt.value as? CommandError == .cancelled)
        #expect(budget.remaining > 0, "cancellation is not reported as a deadline")
        #expect(CommandBudget(timeout: 5).isCancelled == false, "a replacement budget is independent")
    }

    @Test func budgetCancellationFromAnotherThreadStopsAndReapsTheChild() throws {
        let directory = try cancellationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("started")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let fd = open(fifo.path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { Issue.record("could not open child-start handshake"); return }
        defer { close(fd) }
        let budget = CommandBudget(timeout: 10), receipt = CancellationReceipt(), errors = ErrorReceipt()
        let done = DispatchGroup()
        done.enter()
        // The runner executes on a plain Dispatch thread, exactly like ScopeEditor's off-pool work.
        DispatchQueue(label: "scope.tests.offpool-runner").async {
            defer { done.leave() }
            do {
                _ = try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf '%s\\n' $$ > \"$1\"; exec /bin/sleep 3", "fixture", fifo.path], budget: budget)
            } catch { errors.record(error) }
        }
        let pid = waitForChildPID(fd, seconds: 5)
        receipt.record(pid: pid, remaining: budget.remaining)
        budget.cancel()
        #expect(waitForGroup(done, seconds: 5), "bounded runner must return")
        #expect(errors.value as? CommandError == .cancelled, "never timedOut or a normal exit")
        let observed = receipt.value
        #expect(observed.pid != nil && observed.alive, "actual child-start receipt is required")
        if let pid = observed.pid {
            let status = kill(pid, 0), error = errno
            #expect(status == -1 && error == ESRCH, "cancelled child is gone/reaped")
        }
    }

    @Test func cancelledBudgetLaunchesNoChild() throws {
        let directory = try cancellationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let budget = CommandBudget(timeout: 5)
        budget.cancel()
        #expect(throws: CommandError.cancelled) {
            try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf launched > \"$1\"", "fixture", marker.path], budget: budget)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

private func cancellationDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
private func waitForGate(_ gate: DispatchSemaphore) -> Bool { gate.wait(timeout: .now() + 5) == .success }
private func waitForGroup(_ group: DispatchGroup, seconds: TimeInterval) -> Bool {
    group.wait(timeout: .now() + seconds) == .success
}
private func waitForChildPID(_ fd: Int32, seconds: TimeInterval) -> Int32? {
    let end = ContinuousClock.now.advanced(by: .seconds(seconds))
    while true {
        let parts = ContinuousClock.now.duration(to: end).components
        let remaining = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        guard remaining > 0 else { return nil }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up)))
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0, let pid = Int32(String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }
}
private final class ErrorReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func record(_ error: Error) { lock.lock(); self.error = error; lock.unlock() }
    var value: Error? { lock.lock(); defer { lock.unlock() }; return error }
}
private final class CancellationReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (pid: Int32?, remaining: TimeInterval, alive: Bool) = (nil, 0, false)
    func record(pid: Int32?, remaining: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        state = (pid, remaining, pid.map { kill($0, 0) == 0 } ?? false)
    }
    var value: (pid: Int32?, remaining: TimeInterval, alive: Bool) {
        lock.lock(); defer { lock.unlock() }; return state
    }
}
