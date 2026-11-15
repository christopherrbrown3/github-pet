import Foundation

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    /// False if a descendant kept a pipe open beyond the bounded post-exit drain.
    public var outputComplete: Bool

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), outputComplete: Bool = true) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.outputComplete = outputComplete
    }

    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum CommandError: Error, Equatable {
    case launchFailed(String)
    case timedOut
    case outputLimitExceeded
    case cancelled
}

/// Runs a program with an explicit argv. Implementations must never go through a shell.
public protocol CommandRunner: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult
    func run(executable: URL, arguments: [String], budget: CommandBudget) throws -> CommandResult
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

    /// Only the active account matters: without `--active`, `gh auth status` fails when any stored
    /// account on the host (e.g. an expired inactive one) is invalid.
    static let authStatusArguments = ["auth", "status", "--active", "--hostname", "github.com"]

    public func authState() -> GhAuthState {
        authState(budget: CommandBudget(timeout: timeout))
    }

    private func authState(budget: CommandBudget) -> GhAuthState {
        guard let gh = locator.locate() else { return .missing }
        do {
            let result = try runner.run(executable: gh, arguments: Self.authStatusArguments, budget: budget)
            guard result.outputComplete else { return .error("gh output incomplete") }
            if result.exitCode == 0 { return .authenticated }
            // A gh too old for --active: the preflight is only advisory then; the GraphQL request
            // still maps exit 4 / "gh auth login" to signed out.
            if result.stderrText.lowercased().contains("unknown flag") { return .authenticated }
            if result.exitCode == 1 || Self.isAuthFailure(result) { return .unauthenticated }
            return .error("gh auth status exited \(result.exitCode)")
        } catch CommandError.timedOut {
            return .error("gh timed out")
        } catch CommandError.outputLimitExceeded {
            return .error("gh output limit exceeded")
        } catch CommandError.cancelled {
            return .error("gh cancelled")
        } catch {
            return .missing
        }
    }

    /// Per-search result cap. More matches than this (GraphQL `issueCount`) make the snapshot
    /// partial: its items are a lower bound.
    static let searchLimit = 30

    /// One GraphQL request answers the viewer's login and both searches, so the account and the
    /// items always come from the same token: `gh auth switch` mid-poll can't mix accounts.
    /// The searches match `gh search prs --review-requested=@me --state=open` and
    /// `gh search issues --assignee=@me --state=open` (checked: same items, order, URLs, dates).
    static let graphQLQuery = """
        query {
          viewer { login }
          reviews: search(query: "is:pr is:open review-requested:@me", type: ISSUE, first: \(searchLimit)) {
            issueCount
            nodes { ... on PullRequest { id number title url updatedAt repository { nameWithOwner } } }
          }
          assigned: search(query: "is:issue is:open assignee:@me", type: ISSUE, first: \(searchLimit)) {
            issueCount
            nodes { ... on Issue { id number title url updatedAt repository { nameWithOwner } } }
          }
        }
        """

    static var requestArguments: [String] { ["api", "graphql", "-f", "query=\(graphQLQuery)"] }

    /// One poll's result plus the account it belongs to (nil when the poll failed before the
    /// account was known).
    public struct AccountFetch: Sendable {
        public var account: String?
        public var outcome: FetchOutcome
    }

    public func fetch() -> FetchOutcome { fetchWithAccount().outcome }

    /// One poll: a single authenticated request for the account and both searches. A search that
    /// failed or hit the cap makes the snapshot partial; both failing is an error. The account lets
    /// the caller start a fresh baseline when `gh auth switch` changes who is signed in.
    public func fetchWithAccount() -> AccountFetch {
        let budget = CommandBudget(timeout: timeout)
        switch authState(budget: budget) {
        case .missing: return AccountFetch(account: nil, outcome: .failure(.ghMissing))
        case .unauthenticated: return AccountFetch(account: nil, outcome: .failure(.unauthenticated))
        case .error(let message): return AccountFetch(account: nil, outcome: .failure(.failed(message)))
        case .authenticated: break
        }
        guard let gh = locator.locate() else { return AccountFetch(account: nil, outcome: .failure(.ghMissing)) }
        let result: CommandResult
        do {
            result = try runner.run(executable: gh, arguments: Self.requestArguments, budget: budget)
        } catch {
            return AccountFetch(account: nil, outcome: .failure(.failed("GitHub search failed")))
        }
        if Self.isAuthFailure(result) { return AccountFetch(account: nil, outcome: .failure(.unauthenticated)) }
        guard result.outputComplete else { return AccountFetch(account: nil, outcome: .failure(.failed("GitHub output incomplete"))) }
        // gh exits non-zero when GraphQL reports errors but still prints the response, which may
        // hold one search's data: retain proven pages, but never certify them complete on failure.
        guard let response = GhGraphQLParser.parse(result.stdout), let account = response.account else {
            return AccountFetch(account: nil, outcome: .failure(.failed("GitHub search failed")))
        }
        do { try budget.check() } catch {
            return AccountFetch(account: nil, outcome: .failure(.failed("GitHub request budget exhausted")))
        }
        let pages = [response.reviews, response.assigned]
        let found = pages.compactMap { $0 }
        guard !found.isEmpty else { return AccountFetch(account: account, outcome: .failure(.failed("GitHub search failed"))) }
        let complete = result.exitCode == 0 && !response.hasErrorEnvelope
            && found.count == pages.count && found.allSatisfy { $0.total <= $0.items.count }
        return AccountFetch(account: account, outcome: .snapshot(items: found.flatMap(\.items), complete: complete))
    }
}

public enum GhGraphQLParser {
    public struct Page: Equatable, Sendable {
        public var items: [InboxItem]
        /// All matches (`issueCount`); more than `items` means the cap hid some.
        public var total: Int
    }

    public struct Response: Equatable, Sendable {
        public var account: String?
        public var reviews: Page?
        public var assigned: Page?
        /// An errors member, even malformed/null/empty, cannot certify a complete response.
        public var hasErrorEnvelope: Bool = false
    }

    private struct Envelope: Decodable {
        struct DataField: Decodable {
            struct Viewer: Decodable { var login: String? }
            var viewer: Viewer?
            var reviews: Search?
            var assigned: Search?
        }
        struct Search: Decodable {
            var issueCount: Int
            var nodes: [Node?]
        }
        struct Node: Decodable {
            struct Repository: Decodable { var nameWithOwner: String }
            var id: String?
            var number: Int?
            var title: String?
            var url: String?
            var updatedAt: Date?
            var repository: Repository?
        }
        var data: DataField?
        var hasErrorEnvelope: Bool
        private enum CodingKeys: String, CodingKey { case data, errors }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            data = try c.decodeIfPresent(DataField.self, forKey: .data)
            // Inspect presence without decoding error contents: valid pages remain available
            // as partial even if the errors value itself has an unexpected JSON shape.
            hasErrorEnvelope = c.contains(.errors)
        }
    }

    /// Parses the GraphQL response, or nil if it isn't one. IDs are `<kind>:<node id>`: GitHub's
    /// immutable node ID, so renaming or transferring a repository doesn't make an existing item
    /// look new. The repository name is display metadata only. Links outside https://github.com
    /// are dropped.
    public static func parse(_ data: Data) -> Response? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data), let body = envelope.data else { return nil }
        func page(_ search: Envelope.Search?, kind: ItemKind) -> Page? {
            guard let search else { return nil }
            let items: [InboxItem] = search.nodes.compactMap { node in
                guard let node, let nodeID = node.id, !nodeID.isEmpty, let number = node.number, number > 0,
                      let repo = node.repository?.nameWithOwner, !repo.isEmpty, let updatedAt = node.updatedAt else { return nil }
                return InboxItem(id: "\(kind.rawValue):\(nodeID)", kind: kind, repository: repo,
                                 title: node.title ?? "", url: node.url.flatMap { SafeLink.validated($0) }, updatedAt: updatedAt)
            }
            return Page(items: items, total: search.issueCount)
        }
        let login = body.viewer?.login.flatMap { $0.isEmpty ? nil : $0 }
        return Response(account: login, reviews: page(body.reviews, kind: .reviewRequest),
                        assigned: page(body.assigned, kind: .assignedIssue), hasErrorEnvelope: envelope.hasErrorEnvelope)
    }
}
