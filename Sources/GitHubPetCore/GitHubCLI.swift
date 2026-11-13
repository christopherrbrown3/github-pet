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

    /// `GH_HOST` is pinned so searches use the same host as `auth status --hostname github.com`,
    /// whatever the launching shell has configured.
    public init(extraEnvironment: [String: String] = [
        "GH_HOST": "github.com",
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
            output.cancel()
            errors.cancel()
            throw CommandError.timedOut
        }
        let outData = output.finish(within: 2)
        let errData = errors.finish(within: 2)
        return CommandResult(exitCode: process.terminationStatus, stdout: outData, stderr: errData)
    }
}

/// Drains a pipe with non-blocking reads from a dispatch source, so a chatty child never
/// blocks on a full pipe and no thread is ever parked in `read`. Cancelling (on EOF, a
/// collector deadline or a command timeout) closes the descriptor, even if a descendant
/// still holds the write end open.
final class PipeCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GitHubPet.PipeCollector")
    private let source: DispatchSourceRead
    private let closed = DispatchSemaphore(value: 0)
    private let fd: Int32
    private var data = Data()   // only touched on `queue`

    init(_ handle: FileHandle) {
        fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [closed] in
            try? handle.close()
            closed.signal()
        }
        source.resume()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                if count == 0 || errno != EAGAIN { source.cancel() }   // EOF or a real error
                return
            }
        }
    }

    /// Stops reading and closes the pipe. Safe to call more than once.
    func cancel() {
        source.cancel()
    }

    /// Bytes read until EOF, or what arrived within `seconds` if the pipe stays open longer.
    /// Either way the descriptor is closed before this returns.
    func finish(within seconds: TimeInterval) -> Data {
        if closed.wait(timeout: .now() + seconds) == .timedOut {
            source.cancel()
            closed.wait()
        }
        return queue.sync { data }
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
    /// Per-query result cap. A query that fills it may have more matches, so it is partial.
    static let searchLimit = 30

    static let queries: [Query] = [
        Query(kind: .reviewRequest, arguments: ["search", "prs", "--review-requested=@me", "--state=open",
                                                "--json", searchFields, "--limit", "\(searchLimit)"]),
        Query(kind: .assignedIssue, arguments: ["search", "issues", "--assignee=@me", "--state=open",
                                                "--json", searchFields, "--limit", "\(searchLimit)"]),
    ]

    /// Login of the active github.com account; only compared in memory, never shown or stored.
    static let accountArguments = ["api", "user", "--jq", ".login"]

    /// One poll's result plus the account it belongs to (nil when the poll failed before
    /// the account was known).
    public struct AccountFetch: Sendable {
        public var account: String?
        public var outcome: FetchOutcome
    }

    public func fetch() -> FetchOutcome { fetchWithAccount().outcome }

    /// One poll: identify the active account, then run each search and merge. Any sub-query
    /// failure makes the snapshot partial. The account lets the caller start a fresh baseline
    /// when `gh auth switch` changes who is signed in.
    public func fetchWithAccount() -> AccountFetch {
        switch authState() {
        case .missing: return AccountFetch(account: nil, outcome: .failure(.ghMissing))
        case .unauthenticated: return AccountFetch(account: nil, outcome: .failure(.unauthenticated))
        case .error(let message): return AccountFetch(account: nil, outcome: .failure(.failed(message)))
        case .authenticated: break
        }
        guard let gh = locator.locate() else { return AccountFetch(account: nil, outcome: .failure(.ghMissing)) }
        let account: String
        do {
            let result = try runner.run(executable: gh, arguments: Self.accountArguments, timeout: timeout)
            if Self.isAuthFailure(result) { return AccountFetch(account: nil, outcome: .failure(.unauthenticated)) }
            let login = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitCode == 0, !login.isEmpty else {
                return AccountFetch(account: nil, outcome: .failure(.failed("Couldn't identify the GitHub account")))
            }
            account = login
        } catch {
            return AccountFetch(account: nil, outcome: .failure(.failed("Couldn't identify the GitHub account")))
        }
        return AccountFetch(account: account, outcome: search(gh))
    }

    private func search(_ gh: URL) -> FetchOutcome {

        var items: [InboxItem] = []
        var failures = 0
        var capped = false
        for query in Self.queries {
            do {
                let result = try runner.run(executable: gh, arguments: query.arguments, timeout: timeout)
                if Self.isAuthFailure(result) { return .failure(.unauthenticated) }
                guard result.exitCode == 0 else { failures += 1; continue }
                let page = try GhSearchParser.parsePage(result.stdout, kind: query.kind)
                items += page.items
                if page.rowCount >= Self.searchLimit { capped = true }
            } catch {
                failures += 1
            }
        }
        if failures == Self.queries.count { return .failure(.failed("GitHub search failed")) }
        return .snapshot(items: items, complete: failures == 0 && !capped)
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
        try parsePage(data, kind: kind).items
    }

    /// Items plus the raw row count (used to detect a query that hit its result cap).
    public static func parsePage(_ data: Data, kind: ItemKind) throws -> (items: [InboxItem], rowCount: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let rows = try? decoder.decode([Row].self, from: data) else { throw ParseError.malformed }
        let items: [InboxItem] = rows.compactMap { row in
            let repo = row.repository.nameWithOwner
            guard !repo.isEmpty, row.number > 0 else { return nil }
            return InboxItem(id: "\(kind.rawValue):\(repo)#\(row.number)", kind: kind,
                             repository: repo, title: row.title,
                             url: SafeLink.validated(row.url), updatedAt: row.updatedAt)
        }
        return (items, rows.count)
    }
}
