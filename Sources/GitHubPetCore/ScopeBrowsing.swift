import Foundation

// MARK: Scope browser (#137): owners, per-owner repository pages and per-owner search

/// Whose repositories a sidebar row lists. Only organizations can become an "All repositories"
/// target; your own account and "Shared with you" offer repository targets only.
public enum ScopeBrowseOwnerKind: String, Sendable, Hashable, CaseIterable {
    case viewer, shared, organization
}

public struct ScopeBrowseOwner: Hashable, Sendable, Identifiable {
    public let kind: ScopeBrowseOwnerKind
    /// The organization or viewer login; empty for "Shared with you".
    public let login: String
    /// GitHub's total, or nil when it withheld the list (SSO / scope) or did not say.
    public let repositoryCount: Int?
    /// GitHub withheld this owner's repositories (FORBIDDEN, typically unauthorized SSO).
    public let denied: Bool
    public var id: String { kind == .shared ? "shared" : "\(kind.rawValue):\(login.lowercased())" }
    public init(kind: ScopeBrowseOwnerKind, login: String, repositoryCount: Int?, denied: Bool = false) {
        self.kind = kind; self.login = login; self.repositoryCount = repositoryCount; self.denied = denied
    }
    /// The organization target "All repositories" adds; nil for your account and shared.
    public var organizationTarget: MonitoringTarget? {
        kind == .organization ? try? MonitoringTarget(organization: login) : nil
    }
}

public struct ScopeBrowseRepository: Hashable, Sendable, Identifiable {
    public let nameWithOwner: String
    public let isPrivate: Bool
    public let isArchived: Bool
    public let isFork: Bool
    public let pushedAt: Date?
    public var id: String { nameWithOwner.lowercased() }
    public var owner: String { String(nameWithOwner.split(separator: "/").first ?? "") }
    public var name: String { String(nameWithOwner.split(separator: "/").last ?? "") }
    public var target: MonitoringTarget? { try? MonitoringTarget(repository: nameWithOwner) }
    public init(nameWithOwner: String, isPrivate: Bool, isArchived: Bool, isFork: Bool, pushedAt: Date?) {
        self.nameWithOwner = nameWithOwner; self.isPrivate = isPrivate; self.isArchived = isArchived
        self.isFork = isFork; self.pushedAt = pushedAt
    }
}

public enum ScopeBrowseSort: String, Sendable, CaseIterable {
    case pushed, name
    var orderBy: String { self == .pushed ? "{field: PUSHED_AT, direction: DESC}" : "{field: NAME, direction: ASC}" }
}

/// Why a browse request produced nothing usable. Messages are fixed and name no target, so they
/// can be announced; each maps to a distinct presentation that never reads as "no repositories".
public enum ScopeBrowseFailure: Error, Equatable, Sendable {
    case identityMismatch, accessDenied, signedOut, ghMissing
    case rateLimited(resetAt: Date?)
    case transport, deadline, outputLimit, malformedResponse, graphQLError, cancelled

    public var message: String {
        switch self {
        case .identityMismatch: return "The GitHub CLI account changed. Loaded repositories were discarded."
        case .accessDenied: return "GitHub withheld this list. Single sign-on or a token scope blocks it. Run gh auth refresh and authorize SSO, then Retry."
        case .signedOut: return "Sign in to GitHub CLI to browse (gh auth login)."
        case .ghMissing: return "Install GitHub CLI to browse."
        case .rateLimited: return "GitHub rate limit reached. Loaded repositories stay usable."
        case .transport: return "Could not reach GitHub."
        case .deadline: return "GitHub took too long to answer."
        case .outputLimit: return "GitHub's answer exceeded the safe size limit."
        case .malformedResponse, .graphQLError: return "GitHub returned an answer the app could not read."
        case .cancelled: return "Loading was cancelled."
        }
    }

    public init(_ error: Error) {
        switch error {
        case CommandError.outputLimitExceeded: self = .outputLimit
        case CommandError.timedOut: self = .deadline
        case CommandError.cancelled: self = .cancelled
        default: self = .transport
        }
    }

    /// Classification from gh's exit status and stderr, through GhFailure only.
    static func transport(_ result: CommandResult) -> ScopeBrowseFailure? {
        if GhFailure.isSignedOut(result) { return .signedOut }
        if !result.outputComplete { return .outputLimit }
        guard result.exitCode != 0 else { return nil }
        if GhFailure.isRateLimited(result.stderrText) { return .rateLimited(resetAt: nil) }
        if GhFailure.deniesAccess(result.stderrText) { return .accessDenied }
        return nil
    }
}

/// Fields every repository row reads. Avatars are never fetched (that would be a request outside gh).
let scopeBrowseRepositoryFields = "nameWithOwner isPrivate isArchived isFork pushedAt"
let scopeBrowseRateLimit = "rateLimit { remaining resetAt }"

/// Viewer, organizations with counts, and the viewer's own and shared counts: one request.
public struct ScopeOwnersPlan: Equatable, Sendable {
    public static let organizationPageSize = 100
    public let expectedAccount: ScopeAccount
    public let arguments: [String]
    public init(expectedAccount: ScopeAccount) {
        self.expectedAccount = expectedAccount
        let query = """
        query {
        viewer { id login
        own: repositories(ownerAffiliations: [OWNER]) { totalCount }
        shared: repositories(affiliations: [COLLABORATOR], ownerAffiliations: [COLLABORATOR]) { totalCount }
        organizations(first: \(Self.organizationPageSize)) { totalCount pageInfo { hasNextPage } nodes { login repositories { totalCount } } }
        }
        \(scopeBrowseRateLimit)
        }
        """
        arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=\(query)"]
    }
}

public struct ScopeOwnersResult: Equatable, Sendable {
    public var viewer: ScopeViewer?
    /// Your account and "Shared with you" first, then organizations in GitHub's order.
    public var owners: [ScopeBrowseOwner] = []
    /// More organizations exist than one page lists.
    public var moreOrganizations = false
    public var rateLimitReset: Date?
    public var failure: ScopeBrowseFailure?
    public init(viewer: ScopeViewer? = nil, owners: [ScopeBrowseOwner] = [], moreOrganizations: Bool = false,
                rateLimitReset: Date? = nil, failure: ScopeBrowseFailure? = nil) {
        self.viewer = viewer; self.owners = owners; self.moreOrganizations = moreOrganizations
        self.rateLimitReset = rateLimitReset; self.failure = failure
    }
}

/// One page of one owner's repositories, newest push first (or by name). Page size 100 is
/// GitHub's maximum (`first: 101` is EXCESSIVE_PAGINATION). Owner login and cursor are variables.
public struct ScopeRepositoryPagePlan: Equatable, Sendable {
    public static let pageSize = 100
    public let owner: ScopeBrowseOwner
    public let cursor: String?
    public let sort: ScopeBrowseSort
    public let expectedAccount: ScopeAccount
    public let arguments: [String]

    public init(owner: ScopeBrowseOwner, cursor: String?, sort: ScopeBrowseSort, expectedAccount: ScopeAccount) {
        self.owner = owner; self.cursor = cursor; self.sort = sort; self.expectedAccount = expectedAccount
        var definitions: [String] = [], variables: [String] = []
        var after = ""
        if let cursor { definitions.append("$cursor: String!"); variables += ["-f", "cursor=\(cursor)"]; after = ", after: $cursor" }
        let connection = "totalCount pageInfo { hasNextPage endCursor } nodes { \(scopeBrowseRepositoryFields) }"
        let arguments = "first: \(Self.pageSize)\(after), orderBy: \(sort.orderBy)"
        let body: String
        switch owner.kind {
        case .organization:
            definitions.insert("$owner: String!", at: 0); variables = ["-f", "owner=\(owner.login)"] + variables
            body = "viewer { id login }\norganization(login: $owner) { page: repositories(\(arguments)) { \(connection) } }"
        case .viewer:
            body = "viewer { id login\npage: repositories(\(arguments), ownerAffiliations: [OWNER]) { \(connection) } }"
        case .shared:
            body = "viewer { id login\npage: repositories(\(arguments), affiliations: [COLLABORATOR], ownerAffiliations: [COLLABORATOR]) { \(connection) } }"
        }
        let header = definitions.isEmpty ? "query" : "query(\(definitions.joined(separator: ", ")))"
        self.arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=\(header) {\n\(body)\n\(scopeBrowseRateLimit)\n}"] + variables
    }
}

/// Typed search words, reduced to plain name fragments. Qualifiers (`user:`, `repo:`, `org:`,
/// `is:` and any other `key:value`), boolean operators, negation and quoting are dropped, so the
/// owner qualifier the app adds is the only one GitHub sees.
public enum ScopeSearchTerm {
    public static let maximumLength = 64
    public static func sanitize(_ text: String) -> String? {
        var words: [String] = []
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            if token.contains(":") { continue }
            let kept = String(token.unicodeScalars.filter {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == ".")
            }.map(Character.init))
            // A leading '-' negates in GitHub search; operators are not name fragments.
            let word = String(kept.drop(while: { $0 == "-" }))
            if word.isEmpty || ["AND", "OR", "NOT"].contains(word) { continue }
            words.append(word)
        }
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(maximumLength)).trimmingCharacters(in: .whitespaces)
    }
}

/// Server search within one owner, 50 results, run only on an explicit action. The whole search
/// string is built here and travels as one `-f searchQuery=` variable.
public struct ScopeRepositorySearchPlan: Equatable, Sendable {
    public static let resultLimit = 50
    public let owner: ScopeBrowseOwner
    public let term: String
    public let searchQuery: String
    public let expectedAccount: ScopeAccount
    public let arguments: [String]

    /// Nil when the owner cannot be searched (shared has no owner qualifier) or nothing is left
    /// of the typed term after sanitizing.
    public init?(owner: ScopeBrowseOwner, typed: String, expectedAccount: ScopeAccount) {
        guard let term = ScopeSearchTerm.sanitize(typed), owner.kind != .shared,
              ScopeGraphQL.viewerLogin(owner.login) else { return nil }
        self.owner = owner; self.term = term; self.expectedAccount = expectedAccount
        let qualifier = owner.kind == .organization ? "org" : "user"
        searchQuery = "\(qualifier):\(owner.login) \(term) in:name fork:true"
        let query = """
        query($searchQuery: String!) {
        viewer { id login }
        search(type: REPOSITORY, query: $searchQuery, first: \(Self.resultLimit)) { repositoryCount nodes { ... on Repository { \(scopeBrowseRepositoryFields) } } }
        \(scopeBrowseRateLimit)
        }
        """
        arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=\(query)", "-f", "searchQuery=\(searchQuery)"]
    }
}

public struct ScopeRepositoryPage: Equatable, Sendable {
    public var viewer: ScopeViewer?
    public var repositories: [ScopeBrowseRepository] = []
    public var totalCount: Int?
    public var nextCursor: String?
    /// `.exhausted`: GitHub's complete answer; `.capped`: more exist (Load 100 More);
    /// `.partial`: some rows, then an error or unreadable entries; `.failed`: nothing usable.
    public var completion: ScopeDiscoveryCompletion = .failed
    public var rateLimitReset: Date?
    public var failure: ScopeBrowseFailure?
    public init(viewer: ScopeViewer? = nil, repositories: [ScopeBrowseRepository] = [], totalCount: Int? = nil,
                nextCursor: String? = nil, completion: ScopeDiscoveryCompletion = .failed,
                rateLimitReset: Date? = nil, failure: ScopeBrowseFailure? = nil) {
        self.viewer = viewer; self.repositories = repositories; self.totalCount = totalCount; self.nextCursor = nextCursor
        self.completion = completion; self.rateLimitReset = rateLimitReset; self.failure = failure
    }
    public static func failed(_ failure: ScopeBrowseFailure) -> Self { Self(failure: failure) }
}

/// Strict parsing shared by the gh transport and the offline simulation: viewer check on every
/// answer, strict booleans, validated names and cursors, bounded node counts.
public enum ScopeBrowseParser {
    public static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]; return formatter
    }()

    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let int = Int(exactly: number), int >= 0 else { return nil }
        return int
    }

    static func rateLimitReset(_ data: [String: Any]?) -> Date? {
        ((data?["rateLimit"] as? [String: Any])?["resetAt"] as? String).flatMap(dates.date(from:))
    }

    /// FORBIDDEN or SAML wording means GitHub withheld the list, not that it is empty.
    static func denies(_ error: [String: Any]) -> Bool {
        (error["type"] as? String) == "FORBIDDEN"
            || GhFailure.deniesAccess(error["message"] as? String ?? "")
    }

    /// Envelope, transport and identity checks common to every browse answer.
    static func open(_ result: CommandResult, expectedAccount: ScopeAccount)
        -> Result<(data: [String: Any], viewer: ScopeViewer, errors: [[String: Any]]), ScopeBrowseFailure> {
        if let failure = ScopeBrowseFailure.transport(result) {
            // gh exits nonzero for FORBIDDEN data errors but still prints the JSON; prefer it.
            let printedAnswer = failure == .accessDenied && ScopeGraphQL.envelope(result.stdout) != nil
            if !printedAnswer { return .failure(failure) }
        }
        guard result.stdout.count <= CommandBudget.maximumBytes else { return .failure(.outputLimit) }
        guard let envelope = ScopeGraphQL.envelope(result.stdout) else {
            return .failure(result.exitCode != 0 ? .transport : .malformedResponse)
        }
        var errors: [[String: Any]] = []
        if let raw = envelope["errors"] {
            guard let list = raw as? [[String: Any]], !list.isEmpty else { return .failure(.graphQLError) }
            if ScopeGraphQL.rateLimited(list) {
                return .failure(.rateLimited(resetAt: rateLimitReset(envelope["data"] as? [String: Any])))
            }
            errors = list
        }
        let data = envelope["data"] as? [String: Any] ?? [:]
        guard let viewer = ScopeGraphQL.viewer(data) else {
            return .failure(errors.contains(where: denies) ? .accessDenied : errors.isEmpty ? .malformedResponse : .graphQLError)
        }
        guard viewer.account == expectedAccount else { return .failure(.identityMismatch) }
        return .success((data, viewer, errors))
    }

    public static func owners(_ result: CommandResult, plan: ScopeOwnersPlan) -> ScopeOwnersResult {
        let opened: (data: [String: Any], viewer: ScopeViewer, errors: [[String: Any]])
        switch open(result, expectedAccount: plan.expectedAccount) {
        case .failure(let failure): return ScopeOwnersResult(failure: failure)
        case .success(let value): opened = value
        }
        var output = ScopeOwnersResult(viewer: opened.viewer, rateLimitReset: rateLimitReset(opened.data))
        let raw = opened.data["viewer"] as? [String: Any]
        // Only per-organization FORBIDDEN errors are expected: they mark that row denied.
        var deniedIndices = Set<Int>()
        for error in opened.errors {
            let path = error["path"] as? [Any] ?? []
            if denies(error), path.count >= 4, path[0] as? String == "viewer", path[1] as? String == "organizations",
               path[2] as? String == "nodes", let index = path[3] as? Int {
                deniedIndices.insert(index)
            } else {
                output.failure = .graphQLError
            }
        }
        output.owners.append(ScopeBrowseOwner(kind: .viewer, login: opened.viewer.login,
                                              repositoryCount: count((raw?["own"] as? [String: Any])?["totalCount"])))
        output.owners.append(ScopeBrowseOwner(kind: .shared, login: "",
                                              repositoryCount: count((raw?["shared"] as? [String: Any])?["totalCount"])))
        guard let organizations = raw?["organizations"] as? [String: Any], let nodes = organizations["nodes"] as? [Any],
              nodes.count <= ScopeOwnersPlan.organizationPageSize,
              let more = ScopeDiscovery.boolean((organizations["pageInfo"] as? [String: Any])?["hasNextPage"]) else {
            output.failure = output.failure ?? .malformedResponse
            return output
        }
        output.moreOrganizations = more
        var seen = Set<String>()
        for (index, node) in nodes.enumerated() {
            guard let fields = node as? [String: Any], let login = fields["login"] as? String,
                  let target = try? MonitoringTarget(organization: login), seen.insert(target.owner).inserted else {
                output.failure = output.failure ?? .malformedResponse; continue
            }
            let denied = deniedIndices.contains(index) || fields["repositories"] is NSNull
            let total = denied ? nil : count((fields["repositories"] as? [String: Any])?["totalCount"])
            output.owners.append(ScopeBrowseOwner(kind: .organization, login: login, repositoryCount: total, denied: denied))
        }
        return output
    }

    static func repository(_ node: Any) -> ScopeBrowseRepository? {
        // Owners may be managed-user logins with '_' (not a monitorable target, but a real row).
        guard let fields = node as? [String: Any], let name = fields["nameWithOwner"] as? String,
              case let parts = name.split(separator: "/", omittingEmptySubsequences: false), parts.count == 2,
              ScopeGraphQL.viewerLogin(String(parts[0])), ScopeASCII.repositoryName(String(parts[1])),
              let isPrivate = ScopeDiscovery.boolean(fields["isPrivate"]),
              let isArchived = ScopeDiscovery.boolean(fields["isArchived"]),
              let isFork = ScopeDiscovery.boolean(fields["isFork"]) else { return nil }
        let pushed = (fields["pushedAt"] as? String).flatMap(dates.date(from:))
        return ScopeBrowseRepository(nameWithOwner: name, isPrivate: isPrivate, isArchived: isArchived, isFork: isFork, pushedAt: pushed)
    }

    static func page(nodes: [Any], into output: inout ScopeRepositoryPage, owner: ScopeBrowseOwner) -> Bool {
        var malformed = false, seen = Set<String>()
        for node in nodes {
            guard let repository = repository(node),
                  owner.kind != .organization || repository.owner.lowercased() == owner.login.lowercased(),
                  seen.insert(repository.id).inserted else { malformed = true; continue }
            output.repositories.append(repository)
        }
        return malformed
    }

    public static func repositories(_ result: CommandResult, plan: ScopeRepositoryPagePlan) -> ScopeRepositoryPage {
        let opened: (data: [String: Any], viewer: ScopeViewer, errors: [[String: Any]])
        switch open(result, expectedAccount: plan.expectedAccount) {
        case .failure(let failure): return .failed(failure)
        case .success(let value): opened = value
        }
        var output = ScopeRepositoryPage(viewer: opened.viewer, rateLimitReset: rateLimitReset(opened.data))
        let container = plan.owner.kind == .organization ? opened.data["organization"] : opened.data["viewer"]
        let connection = (container as? [String: Any])?["page"]
        if opened.errors.contains(where: denies), connection == nil || connection is NSNull || container is NSNull {
            output.failure = .accessDenied; return output
        }
        guard let connection = connection as? [String: Any], let nodes = connection["nodes"] as? [Any],
              nodes.count <= ScopeRepositoryPagePlan.pageSize,
              let info = connection["pageInfo"] as? [String: Any], let more = ScopeDiscovery.boolean(info["hasNextPage"]) else {
            output.failure = opened.errors.isEmpty ? .malformedResponse : .graphQLError
            return output
        }
        output.totalCount = count(connection["totalCount"])
        let malformed = page(nodes: nodes, into: &output, owner: plan.owner)
        if !opened.errors.isEmpty || result.exitCode != 0 {
            output.completion = output.repositories.isEmpty ? .failed : .partial
            output.failure = opened.errors.contains(where: denies) ? .accessDenied : .graphQLError
        } else if more {
            if let next = ScopeDiscovery.cursor(info["endCursor"]) { output.nextCursor = next; output.completion = malformed ? .partial : .capped }
            else { output.completion = .partial }
        } else {
            output.completion = malformed ? .partial : .exhausted
        }
        return output
    }

    /// Search results are never "complete": a zero count only means no name matched.
    public static func search(_ result: CommandResult, plan: ScopeRepositorySearchPlan) -> ScopeRepositoryPage {
        let opened: (data: [String: Any], viewer: ScopeViewer, errors: [[String: Any]])
        switch open(result, expectedAccount: plan.expectedAccount) {
        case .failure(let failure): return .failed(failure)
        case .success(let value): opened = value
        }
        var output = ScopeRepositoryPage(viewer: opened.viewer, rateLimitReset: rateLimitReset(opened.data))
        guard opened.errors.isEmpty, let search = opened.data["search"] as? [String: Any],
              let nodes = search["nodes"] as? [Any], nodes.count <= ScopeRepositorySearchPlan.resultLimit else {
            output.failure = opened.errors.contains(where: denies) ? .accessDenied : opened.errors.isEmpty ? .malformedResponse : .graphQLError
            return output
        }
        output.totalCount = count(search["repositoryCount"])
        let malformed = page(nodes: nodes, into: &output, owner: plan.owner)
        output.completion = malformed ? .partial : (output.totalCount ?? 0) > output.repositories.count ? .capped : .exhausted
        return output
    }
}

// MARK: Transport

/// The browser's data source. Live code uses gh; the offline simulation and Demo conform too.
/// Every call is one gh request with its own budget; a failure affects only that request.
public protocol ScopeBrowsing: Sendable {
    func owners(_ plan: ScopeOwnersPlan, budget: CommandBudget) -> ScopeOwnersResult
    func repositories(_ plan: ScopeRepositoryPagePlan, budget: CommandBudget) -> ScopeRepositoryPage
    func search(_ plan: ScopeRepositorySearchPlan, budget: CommandBudget) -> ScopeRepositoryPage
}

extension ScopeGhAccess: ScopeBrowsing {
    private func run<T>(_ arguments: [String], budget: CommandBudget, failed: (ScopeBrowseFailure) -> T,
                        parse: (CommandResult) -> T) -> T {
        guard let gh = locator.locate() else { return failed(.ghMissing) }
        do {
            try budget.check()
            let result = try runner.run(executable: gh, arguments: arguments, budget: budget)
            try budget.check()
            return parse(result)
        } catch { return failed(ScopeBrowseFailure(error)) }
    }

    public func owners(_ plan: ScopeOwnersPlan, budget: CommandBudget) -> ScopeOwnersResult {
        run(plan.arguments, budget: budget, failed: { ScopeOwnersResult(failure: $0) }) { ScopeBrowseParser.owners($0, plan: plan) }
    }
    public func repositories(_ plan: ScopeRepositoryPagePlan, budget: CommandBudget) -> ScopeRepositoryPage {
        run(plan.arguments, budget: budget, failed: { .failed($0) }) { ScopeBrowseParser.repositories($0, plan: plan) }
    }
    public func search(_ plan: ScopeRepositorySearchPlan, budget: CommandBudget) -> ScopeRepositoryPage {
        run(plan.arguments, budget: budget, failed: { .failed($0) }) { ScopeBrowseParser.search($0, plan: plan) }
    }
}
