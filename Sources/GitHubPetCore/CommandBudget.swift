import Foundation

/// Shared by preflight, request, stdout and stderr. Production collectors reserve bytes BEFORE
/// retaining them; injected runners use the same accounting through the protocol's default method.
public final class CommandBudget: @unchecked Sendable {
    public static let maximumBytes = 2 * 1024 * 1024
    public static let maximumSeconds: TimeInterval = 20
    let deadline: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    let usesSystemClock: Bool
    private let lock = NSLock()
    private let limit: Int
    private var used = 0
    private var overflow = false
    private var cancelled = false

    public convenience init(timeout: TimeInterval = CommandBudget.maximumSeconds, maximumBytes: Int = CommandBudget.maximumBytes) {
        self.init(timeout: timeout, maximumBytes: maximumBytes, now: { ContinuousClock.now }, usesSystemClock: true)
    }

    /// Internal deterministic seam for in-memory fixture runners, never real subprocesses.
    convenience init(timeout: TimeInterval, maximumBytes: Int = CommandBudget.maximumBytes,
                     now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.init(timeout: timeout, maximumBytes: maximumBytes, now: now, usesSystemClock: false)
    }
    private init(timeout: TimeInterval, maximumBytes: Int,
                 now: @escaping @Sendable () -> ContinuousClock.Instant, usesSystemClock: Bool) {
        self.now = now; self.usesSystemClock = usesSystemClock
        let seconds = timeout.isFinite ? min(Self.maximumSeconds, max(0, timeout)) : 0
        deadline = now().advanced(by: .seconds(seconds))
        limit = min(Self.maximumBytes, max(0, maximumBytes))
    }

    public var remaining: TimeInterval {
        let parts = now().duration(to: deadline).components
        return max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
    public var consumedBytes: Int { lock.lock(); defer { lock.unlock() }; return used }

    static func seconds(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let parts = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    @discardableResult
    /// Atomically debit a complete chunk BEFORE retaining it. Shared across streams/commands.
    /// A negative or overflowing reservation fails closed and latches outputLimitExceeded;
    /// callers must stop collection on false and must never append that chunk.
    public func reserve(_ bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !overflow, bytes >= 0, bytes <= limit - used else { overflow = true; return false }
        used += bytes
        return true
    }

    /// Latch cancellation for every command sharing this budget. Work on Dispatch threads has no
    /// Task to observe, so the owner bridges its Task cancellation here; it is never cleared.
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Check the latched byte error, latched or current-Task cancellation and monotonic deadline.
    /// Real-I/O implementations call this while collecting and waiting, not only on exit.
    public func check() throws {
        lock.lock(); let exceeded = overflow, cancelled = cancelled; lock.unlock()
        if exceeded { throw CommandError.outputLimitExceeded }
        if cancelled || Task.isCancelled { throw CommandError.cancelled }
        if remaining <= 0 { throw CommandError.timedOut }
    }
}

public extension CommandRunner {
    /// Compatibility for in-memory/test runners. Real I/O MUST implement this requirement with
    /// collection-time accounting, as ProcessCommandRunner does; this fallback cannot bound I/O.
    func run(executable: URL, arguments: [String], budget: CommandBudget) throws -> CommandResult {
        try budget.check()
        let result = try run(executable: executable, arguments: arguments, timeout: budget.remaining)
        guard budget.reserve(result.stdout.count), budget.reserve(result.stderr.count) else {
            throw CommandError.outputLimitExceeded
        }
        try budget.check()
        return result
    }
}

/// Safe argv, no stdin, one monotonic active deadline. Teardown has a SHARED 2-second grace;
/// after that only the direct child is SIGKILLed, without waiting indefinitely on descendants.
public struct ProcessCommandRunner: CommandRunner {
    public var extraEnvironment: [String: String]
    public static let cleanupGrace: TimeInterval = 2
    public static let postExitDrain: TimeInterval = 2

    public init(extraEnvironment: [String: String] = [
        "GH_HOST": "github.com", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
        "GH_SPINNER_DISABLED": "1", "NO_COLOR": "1",
    ]) {
        self.extraEnvironment = extraEnvironment
    }

    public func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        try run(executable: executable, arguments: arguments,
                budget: CommandBudget(timeout: timeout))
    }

    public func run(executable: URL, arguments: [String], budget: CommandBudget) throws -> CommandResult {
        guard budget.usesSystemClock else { throw CommandError.launchFailed("Real subprocesses require the system deadline clock") }
        try budget.check()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let wake = DispatchSemaphore(value: 0)
        let exited = DispatchGroup(); exited.enter()
        process.terminationHandler = { _ in exited.leave(); wake.signal() }
        do { try process.run() } catch { throw CommandError.launchFailed(error.localizedDescription) }
        let output = PipeCollector(stdout.fileHandleForReading, budget: budget) { wake.signal() }
        let errors = PipeCollector(stderr.fileHandleForReading, budget: budget) { wake.signal() }
        var teardownDeadline: ContinuousClock.Instant?
        func teardownEnd() -> ContinuousClock.Instant {
            if let teardownDeadline { return teardownDeadline }
            let end = ContinuousClock.now.advanced(by: .seconds(Self.cleanupGrace))
            teardownDeadline = end
            return end
        }

        func cleanup() {
            let end = teardownEnd()
            output.cancel(); errors.cancel()
            if process.isRunning { process.terminate() }
            _ = exited.wait(timeout: .now() + CommandBudget.seconds(until: end))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = output.wait(until: end); _ = errors.wait(until: end)
        }
        do {
            while process.isRunning {
                try budget.check()
                // Wake on exit/overflow, and check task cancellation at most 50 ms apart.
                _ = wake.wait(timeout: .now() + min(0.05, budget.remaining))
            }
            try budget.check()
            let drainEnd = min(budget.deadline, ContinuousClock.now.advanced(by: .seconds(Self.postExitDrain)))
            _ = output.wait(until: drainEnd); _ = errors.wait(until: drainEnd)
            if !output.isClosed || !errors.isClosed {
                output.cancel(); errors.cancel()
                let end = teardownEnd()
                guard output.wait(until: end), errors.wait(until: end) else { throw CommandError.timedOut }
            }
            try budget.check()
            return CommandResult(exitCode: process.terminationStatus, stdout: output.bytes, stderr: errors.bytes,
                                 outputComplete: output.reachedEOF && errors.reachedEOF)
        } catch {
            cleanup()
            throw error
        }
    }
}

/// Nonblocking drains share a byte budget across BOTH pipes and all commands in the poll.
/// A failed reservation retains none of that chunk and wakes the parent immediately.
final class PipeCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GitHubPet.PipeCollector")
    private let source: DispatchSourceRead
    private let closed = DispatchGroup()
    private let fd: Int32
    private let budget: CommandBudget
    private let failed: @Sendable () -> Void
    private let lock = NSLock()
    private var data = Data()
    private var eof = false

    init(_ handle: FileHandle, budget: CommandBudget, failed: @escaping @Sendable () -> Void) {
        self.budget = budget; self.failed = failed
        fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        closed.enter()
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [closed] in try? handle.close(); closed.leave() }
        source.resume()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Yield regularly so cancellation is never stuck behind a chatty descendant.
        for _ in 0..<32 {
            guard !source.isCancelled else { return }
            do { try budget.check() } catch { source.cancel(); failed(); return }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard budget.reserve(count) else { source.cancel(); failed(); return }
                lock.lock(); data.append(buffer, count: count); lock.unlock()
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                if count == 0 {
                    lock.lock(); eof = true; lock.unlock()
                    source.cancel()
                } else if errno != EAGAIN { source.cancel() }
                return
            }
        }
    }

    func cancel() { source.cancel() }
    var isClosed: Bool { closed.wait(timeout: .now()) == .success }
    func wait(until end: ContinuousClock.Instant) -> Bool {
        closed.wait(timeout: .now() + CommandBudget.seconds(until: end)) == .success
    }
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
    var reachedEOF: Bool { lock.lock(); defer { lock.unlock() }; return eof }
}
