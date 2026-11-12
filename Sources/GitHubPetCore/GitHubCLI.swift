import Foundation

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum CommandError: Error, Equatable {
    case launchFailed(String)
    case timedOut
}

/// Runs a program with an explicit argv. Implementations must never go through a shell.
public protocol CommandRunner: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

/// `Process`-backed runner: argv only, no shell, stdin closed, bounded by a timeout.
public struct ProcessCommandRunner: CommandRunner {
    public var extraEnvironment: [String: String]

    public init(extraEnvironment: [String: String] = [
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "GH_SPINNER_DISABLED": "1",
        "NO_COLOR": "1",
    ]) {
        self.extraEnvironment = extraEnvironment
    }

    public func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        // Every wait below is bounded: a hung child, or a grandchild holding a pipe open,
        // can never block the caller past the timeout plus a short grace period.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(error.localizedDescription)
        }

        let output = PipeCollector(stdout.fileHandleForReading)
        let errors = PipeCollector(stderr.fileHandleForReading)
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw CommandError.timedOut
        }
        let outData = output.finish(within: 2)
        let errData = errors.finish(within: 2)
        return CommandResult(exitCode: process.terminationStatus, stdout: outData, stderr: errData)
    }
}

/// Drains a pipe on a background queue so a chatty child never blocks on a full pipe.
private final class PipeCollector: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    /// Collected bytes, or nothing if the pipe stays open past `seconds`.
    func finish(within seconds: TimeInterval) -> Data {
        done.wait(timeout: .now() + seconds) == .success ? data : Data()
    }
}

/// Finds the `gh` executable without consulting a shell.
public struct GhLocator: Sendable {
    public static let overrideVariable = "GITHUB_PET_GH_PATH"
    public var environment: [String: String]
    public var isExecutable: @Sendable (String) -> Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.environment = environment
        self.isExecutable = isExecutable
    }

    /// Candidate paths in priority order. An explicit override is the only candidate.
    public var candidates: [String] {
        if let override = environment[Self.overrideVariable], !override.isEmpty {
            return [override]
        }
        var paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        for dir in (environment["PATH"] ?? "").split(separator: ":") where dir.hasPrefix("/") {
            let path = "\(dir)/gh"
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    public func locate() -> URL? {
        candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}

public enum GhAuthState: Equatable, Sendable {
    case missing
    case unauthenticated
    case authenticated
    case error(String)
}

/// Talks to GitHub exclusively through the user's `gh` CLI. Never reads or stores tokens.
public struct GhClient: Sendable {
    public var locator: GhLocator
    public var runner: CommandRunner
    public var timeout: TimeInterval

    public init(locator: GhLocator = GhLocator(), runner: CommandRunner = ProcessCommandRunner(),
                timeout: TimeInterval = 20) {
        self.locator = locator
        self.runner = runner
        self.timeout = timeout
    }

    /// `gh` exits 4 when authentication is required; `auth status` exits 1 when logged out.
    static func isAuthFailure(_ result: CommandResult) -> Bool {
        if result.exitCode == 4 { return true }
        let text = result.stderrText.lowercased()
        return text.contains("not logged in") || text.contains("gh auth login")
            || text.contains("authentication required")
    }

    public func authState() -> GhAuthState {
        guard let gh = locator.locate() else { return .missing }
        do {
            let result = try runner.run(executable: gh,
                                        arguments: ["auth", "status", "--hostname", "github.com"],
                                        timeout: timeout)
            if result.exitCode == 0 { return .authenticated }
            if result.exitCode == 1 || Self.isAuthFailure(result) { return .unauthenticated }
            return .error("gh auth status exited \(result.exitCode)")
        } catch CommandError.timedOut {
            return .error("gh timed out")
        } catch {
            return .missing
        }
    }

    struct Query {
        var kind: ItemKind
        var arguments: [String]
    }

    static let searchFields = "number,title,url,repository,updatedAt"

    static let queries: [Query] = [
        Query(kind: .reviewRequest, arguments: ["search", "prs", "--review-requested=@me", "--state=open",
                                                "--json", searchFields, "--limit", "30"]),
        Query(kind: .assignedIssue, arguments: ["search", "issues", "--assignee=@me", "--state=open",
                                                "--json", searchFields, "--limit", "30"]),
    ]

    /// One poll: run each search and merge. Any sub-query failure makes the snapshot partial.
    public func fetch() -> FetchOutcome {
        switch authState() {
        case .missing: return .failure(.ghMissing)
        case .unauthenticated: return .failure(.unauthenticated)
        case .error(let message): return .failure(.failed(message))
        case .authenticated: break
        }
        guard let gh = locator.locate() else { return .failure(.ghMissing) }

        var items: [InboxItem] = []
        var failures = 0
        for query in Self.queries {
            do {
                let result = try runner.run(executable: gh, arguments: query.arguments, timeout: timeout)
                if Self.isAuthFailure(result) { return .failure(.unauthenticated) }
                guard result.exitCode == 0 else { failures += 1; continue }
                items += try GhSearchParser.parse(result.stdout, kind: query.kind)
            } catch {
                failures += 1
            }
        }
        if failures == Self.queries.count { return .failure(.failed("GitHub search failed")) }
        return .snapshot(items: items, complete: failures == 0)
    }
}

public enum GhSearchParser {
    struct Row: Decodable {
        struct Repository: Decodable { var nameWithOwner: String }
        var number: Int
        var title: String
        var url: String
        var repository: Repository
        var updatedAt: Date
    }

    public enum ParseError: Error { case malformed }

    /// Parse `gh search … --json number,title,url,repository,updatedAt` output.
    /// IDs are `<kind>:<owner/repo>#<number>`, stable across polls.
    public static func parse(_ data: Data, kind: ItemKind) throws -> [InboxItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let rows = try? decoder.decode([Row].self, from: data) else { throw ParseError.malformed }
        return rows.compactMap { row in
            let repo = row.repository.nameWithOwner
            guard !repo.isEmpty, row.number > 0 else { return nil }
            return InboxItem(id: "\(kind.rawValue):\(repo)#\(row.number)", kind: kind,
                             repository: repo, title: row.title,
                             url: SafeLink.validated(row.url), updatedAt: row.updatedAt)
        }
    }
}
