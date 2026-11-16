import Foundation

// MARK: Draft

/// Why a draft row (or the typed Add field) cannot be applied. Messages contain no target names.
public enum ScopeRowProblem: Equatable, Sendable {
    case empty, malformed, duplicate, overLimit
    /// Metadata validation: not found, or not readable by the validating account.
    case unavailable
    /// GitHub resolved the input to a different name (renamed/moved).
    case renamed

    public func message(for kind: MonitoringTarget.Kind) -> String {
        switch (self, kind) {
        case (.empty, .organization): return "Enter an organization login."
        case (.empty, .repository): return "Enter a repository as owner/name."
        case (.malformed, .organization): return "Use an organization login: letters, digits and hyphens, at most 39 characters."
        case (.malformed, .repository): return "Use owner/name: letters, digits and hyphens for the owner; letters, digits, '.', '-' and '_' for the name."
        case (.duplicate, _): return "Already in the selection."
        case (.overLimit, _): return "At most \(MonitoringScope.maximumTargets) organizations and repositories in total."
        case (.unavailable, .organization): return "Not found, or this account cannot read this organization."
        case (.unavailable, .repository): return "Not found, or this account cannot read this repository."
        case (.renamed, _): return "GitHub reports a different current name. Enter the current name."
        }
    }
}

public struct ScopeDraftRow: Identifiable, Equatable, Sendable {
    public let id: Int
    public let kind: MonitoringTarget.Kind
    public var text: String
    public var target: MonitoringTarget? { ScopeDraft.parse(text, kind) }
}

/// Settings edits before Apply. Pure value: never persisted and never reaches the active scope
/// except through validated Apply. Trimming/lowercasing comes from `MonitoringTarget`.
public struct ScopeDraft: Equatable, Sendable {
    public var mode: MonitoringScope.Mode
    public private(set) var rows: [ScopeDraftRow] = []
    /// Validation findings keyed by normalized target, so editing a row clears its own finding.
    public private(set) var accessProblems: [MonitoringTarget: ScopeRowProblem] = [:]
    private var nextID = 0

    /// A corrupt saved selection (nil) opens as an empty Selected draft: never Everything.
    public init(scope: MonitoringScope?) {
        mode = scope?.mode ?? .selected
        for target in scope?.targets ?? [] {
            append(target.kind, target.name.map { "\(target.owner)/\($0)" } ?? target.owner)
        }
    }

    static func parse(_ text: String, _ kind: MonitoringTarget.Kind) -> MonitoringTarget? {
        kind == .organization ? try? MonitoringTarget(organization: text) : try? MonitoringTarget(repository: text)
    }

    public func rows(_ kind: MonitoringTarget.Kind) -> [ScopeDraftRow] { rows.filter { $0.kind == kind } }

    private mutating func append(_ kind: MonitoringTarget.Kind, _ text: String) {
        rows.append(ScopeDraftRow(id: nextID, kind: kind, text: text)); nextID += 1
    }

    /// Typed Add: rejected input is not added, so the list never holds an un-addable entry.
    public func addProblem(_ text: String, kind: MonitoringTarget.Kind) -> ScopeRowProblem? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        guard let target = Self.parse(text, kind) else { return .malformed }
        if rows.contains(where: { $0.target == target }) { return .duplicate }
        if rows.count >= MonitoringScope.maximumTargets { return .overLimit }
        return nil
    }

    @discardableResult
    public mutating func add(_ text: String, kind: MonitoringTarget.Kind) -> ScopeRowProblem? {
        if let problem = addProblem(text, kind: kind) { return problem }
        append(kind, text.trimmingCharacters(in: .whitespacesAndNewlines))
        return nil
    }

    public mutating func update(_ id: Int, text: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].text = text
    }

    public mutating func remove(_ id: Int) { rows.removeAll { $0.id == id } }

    public mutating func recordAccessProblems(_ problems: [MonitoringTarget: ScopeRowProblem]) { accessProblems = problems }

    /// Inline row findings: first occurrence wins, later case-insensitive duplicates are flagged.
    public var problems: [Int: ScopeRowProblem] {
        var result: [Int: ScopeRowProblem] = [:], seen = Set<MonitoringTarget>()
        for row in rows {
            if row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result[row.id] = .empty; continue }
            guard let target = row.target else { result[row.id] = .malformed; continue }
            if !seen.insert(target).inserted { result[row.id] = .duplicate; continue }
            if let access = accessProblems[target] { result[row.id] = access }
        }
        return result
    }

    /// Syntactically valid scope for validation; nil when empty, malformed or duplicated.
    /// Access findings do not block a retry: Apply re-validates the whole selection.
    public var candidate: MonitoringScope? {
        if mode == .everything { return .everything }
        guard problems.values.allSatisfy({ $0 == .unavailable || $0 == .renamed }) else { return nil }
        return try? MonitoringScope(selected: rows.compactMap(\.target))
    }

    public var blockingMessage: String? {
        guard mode == .selected else { return nil }
        if rows.isEmpty { return "Add at least one organization or repository." }
        if candidate == nil { return "Correct the highlighted entries before applying." }
        return nil
    }
}

// MARK: Access validation (viewer + per-target metadata, one operation)

public enum ScopeAccessFailure: Equatable, Sendable {
    case identityMismatch, viewerUnavailable, graphQLError, malformedResponse
    case rateLimited, ghMissing, signedOut, transport, deadline, outputLimit, incompleteOutput, cancelled

    /// No target names, query text or raw diagnostics.
    public var message: String {
        switch self {
        case .identityMismatch: return "The GitHub CLI account changed during the check. Nothing was applied."
        case .viewerUnavailable, .malformedResponse: return "GitHub returned an incomplete answer. Nothing was applied."
        case .graphQLError: return "GitHub reported an error. Nothing was applied."
        case .rateLimited: return "GitHub rate limit reached. Try again later; nothing was applied."
        case .ghMissing: return "GitHub CLI is unavailable. Nothing was applied."
        case .signedOut: return "Sign in with GitHub CLI (gh auth login), then try again. Nothing was applied."
        case .transport: return "Could not reach GitHub. Nothing was applied."
        case .deadline: return "The check reached its time limit. Nothing was applied."
        case .outputLimit, .incompleteOutput: return "GitHub's answer exceeded the safe size limit. Nothing was applied."
        case .cancelled: return "The check was cancelled. Nothing was applied."
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
}

public enum ScopeAccessOutcome: Equatable, Sendable {
    /// Every target resolved under the expected viewer.
    case verified(ScopeViewer)
    /// The viewer was proven; these targets were not.
    case rejected(ScopeViewer, [MonitoringTarget: ScopeRowProblem])
    case failed(ScopeAccessFailure)
}

/// A zero-match search proves nothing: access is the target's own metadata, read in the same
/// request that names the viewer, so the result belongs to that request's account.
public struct ScopeAccessPlan: Sendable {
    public let scope: MonitoringScope
    public let expectedAccount: ScopeAccount
    public let arguments: [String]

    public init(scope: MonitoringScope, expectedAccount: ScopeAccount) {
        self.scope = scope; self.expectedAccount = expectedAccount
        var definitions: [String] = [], variables: [String] = [], fields = ["viewer { id login }"]
        for (index, target) in scope.targets.enumerated() {
            definitions.append("$owner\(index): String!"); variables += ["-f", "owner\(index)=\(target.owner)"]
            if let name = target.name {
                definitions.append("$name\(index): String!"); variables += ["-f", "name\(index)=\(name)"]
                fields.append("target\(index): repository(owner: $owner\(index), name: $name\(index)) { __typename id nameWithOwner }")
            } else {
                fields.append("target\(index): organization(login: $owner\(index)) { __typename id login }")
            }
        }
        let header = definitions.isEmpty ? "query" : "query(\(definitions.joined(separator: ", ")))"
        arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=\(header) {\n\(fields.joined(separator: "\n"))\n}"] + variables
    }
}

enum ScopeGraphQL {
    static func viewer(_ body: [String: Any]?) -> ScopeViewer? {
        guard let raw = body?["viewer"] as? [String: Any], let id = raw["id"] as? String,
              let login = raw["login"] as? String, viewerLogin(login),
              let account = try? ScopeAccount(viewerID: id) else { return nil }
        return ScopeViewer(account: account, login: login)
    }
    static func viewerLogin(_ value: String) -> Bool {
        let bytes = value.utf8
        func alphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
        return (1...39).contains(bytes.count) && alphanumeric(bytes.first!) && alphanumeric(bytes.last!)
            && bytes.allSatisfy { alphanumeric($0) || $0 == 45 || $0 == 95 }
    }
    static func rateLimited(_ errors: [[String: Any]]) -> Bool {
        errors.contains { ($0["type"] as? String) == "RATE_LIMITED"
            || (($0["extensions"] as? [String: Any])?["type"] as? String) == "RATE_LIMITED" }
    }
    static func envelope(_ bytes: Data) -> [String: Any]? {
        guard bytes.count <= CommandBudget.maximumBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
    /// gh exits 4 when authentication is required.
    static func authFailure(_ result: CommandResult) -> Bool {
        let message = result.stderrText.lowercased()
        return GhClient.isAuthFailure(result) || message.contains("bad credentials") || message.contains("http 401")
    }
    /// Pre-parse transport classification shared by validation and discovery pages.
    static func transportFailure(_ result: CommandResult) -> ScopeAccessFailure? {
        if authFailure(result) { return .signedOut }
        if !result.outputComplete { return .incompleteOutput }
        if result.exitCode != 0 && result.stderrText.lowercased().contains("rate limit") { return .rateLimited }
        return nil
    }
}

public enum ScopeAccessParser {
    /// Per-target NOT_FOUND/FORBIDDEN errors are expected answers (with a null alias); any other
    /// error, an unknown path, or a missing viewer leaves the selection unverified.
    public static func parse(_ bytes: Data, plan: ScopeAccessPlan) -> ScopeAccessOutcome {
        guard bytes.count <= CommandBudget.maximumBytes else { return .failed(.outputLimit) }
        guard let envelope = ScopeGraphQL.envelope(bytes) else { return .failed(.malformedResponse) }
        var deniedAliases = Set<String>()
        if let rawErrors = envelope["errors"] {
            guard let errors = rawErrors as? [[String: Any]], !errors.isEmpty else { return .failed(.graphQLError) }
            if ScopeGraphQL.rateLimited(errors) { return .failed(.rateLimited) }
            for error in errors {
                let type = error["type"] as? String
                guard type == "NOT_FOUND" || type == "FORBIDDEN", let path = error["path"] as? [Any], path.count == 1,
                      let alias = path.first as? String, plan.scope.targets.indices.contains(where: { "target\($0)" == alias }) else {
                    return .failed(.graphQLError)
                }
                deniedAliases.insert(alias)
            }
        }
        let body = envelope["data"] as? [String: Any]
        guard let viewer = ScopeGraphQL.viewer(body) else { return .failed(.viewerUnavailable) }
        guard viewer.account == plan.expectedAccount else { return .failed(.identityMismatch) }
        var problems: [MonitoringTarget: ScopeRowProblem] = [:]
        for (index, target) in plan.scope.targets.enumerated() {
            let alias = "target\(index)"
            guard let value = body?[alias] else { return .failed(.malformedResponse) }
            if value is NSNull { problems[target] = .unavailable; continue }
            guard !deniedAliases.contains(alias), let metadata = value as? [String: Any],
                  let id = metadata["id"] as? String, ScopeASCII.nodeID(id) else { return .failed(.malformedResponse) }
            let type = metadata["__typename"] as? String
            let reported: String?
            if target.kind == .organization {
                guard type == "Organization" else { return .failed(.malformedResponse) }
                reported = metadata["login"] as? String
            } else {
                guard type == "Repository" else { return .failed(.malformedResponse) }
                reported = metadata["nameWithOwner"] as? String
            }
            guard let reported else { return .failed(.malformedResponse) }
            if reported.lowercased() != (target.name.map { "\(target.owner)/\($0)" } ?? target.owner) { problems[target] = .renamed }
        }
        return problems.isEmpty ? .verified(viewer) : .rejected(viewer, problems)
    }
}

// MARK: Discovery suggestions (bounded, identity-checked hints)

public enum ScopeDiscoveryCompletion: Equatable, Sendable {
    /// No further pages from this endpoint. Still not every readable target.
    case exhausted
    /// Page cap reached while GitHub reported more.
    case capped
    /// Some pages arrived, then a failure, malformed entry or missing cursor.
    case partial
    case failed
}

public struct ScopeDiscoveryCategory: Equatable, Sendable {
    public var suggestions: [String] = []
    public var completion: ScopeDiscoveryCompletion = .failed
    public var pages = 0
    public init(suggestions: [String] = [], completion: ScopeDiscoveryCompletion = .failed, pages: Int = 0) {
        self.suggestions = suggestions; self.completion = completion; self.pages = pages
    }
}

public struct ScopeDiscoveryResult: Equatable, Sendable {
    public var viewer: ScopeViewer?
    public var organizations = ScopeDiscoveryCategory()
    public var repositories = ScopeDiscoveryCategory()
    public var failure: ScopeAccessFailure?
    public init(viewer: ScopeViewer? = nil, organizations: ScopeDiscoveryCategory = .init(),
                repositories: ScopeDiscoveryCategory = .init(), failure: ScopeAccessFailure? = nil) {
        self.viewer = viewer; self.organizations = organizations; self.repositories = repositories; self.failure = failure
    }
    public static func failed(_ failure: ScopeAccessFailure) -> Self { Self(failure: failure) }
}

public struct ScopeDiscoveryPagePlan: Equatable, Sendable {
    public static let maximumPages = 3
    public static let pageSize = 50
    public let organizationCursor: String??
    public let repositoryCursor: String??
    public let arguments: [String]

    /// `.none` omits a category; `.some(nil)` requests its first page.
    public init(organizationCursor: String??, repositoryCursor: String??) {
        self.organizationCursor = organizationCursor; self.repositoryCursor = repositoryCursor
        var definitions: [String] = [], variables: [String] = [], fields: [String] = []
        let page = "pageInfo { hasNextPage endCursor }"
        if case .some(let cursor) = organizationCursor {
            var after = ""
            if let cursor { definitions.append("$organizationCursor: String!"); variables += ["-f", "organizationCursor=\(cursor)"]; after = ", after: $organizationCursor" }
            fields.append("organizations(first: \(Self.pageSize)\(after)) { \(page) nodes { login } }")
        }
        if case .some(let cursor) = repositoryCursor {
            var after = ""
            if let cursor { definitions.append("$repositoryCursor: String!"); variables += ["-f", "repositoryCursor=\(cursor)"]; after = ", after: $repositoryCursor" }
            fields.append("repositories(first: \(Self.pageSize)\(after), affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER], ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]) { \(page) nodes { nameWithOwner } }")
        }
        let header = definitions.isEmpty ? "query" : "query(\(definitions.joined(separator: ", ")))"
        arguments = ["api", "graphql", "--hostname", "github.com",
                     "-f", "query=\(header) {\nviewer { id login\n\(fields.joined(separator: "\n"))\n}\n}"] + variables
    }
}

/// Manual cursors, at most 3 pages × 50 per category, one shared 20 s / 2 MiB budget and a
/// viewer check on every page. The page function runs one gh call; tests inject replies.
public enum ScopeDiscovery {
    static func cursor(_ value: Any?) -> String? {
        guard let value = value as? String, ScopeASCII.nodeID(value, maximum: 1024) else { return nil }
        return value
    }
    /// Only a genuine JSON boolean; `as? Bool` would also accept the NSNumbers JSON 0/1 decode to.
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    public static func run(expectedAccount: ScopeAccount, budget: CommandBudget,
                           page fetch: (ScopeDiscoveryPagePlan) throws -> CommandResult) -> ScopeDiscoveryResult {
        var result = ScopeDiscoveryResult()
        result.organizations.completion = .partial; result.repositories.completion = .partial
        var organizationCursor: String?? = .some(nil), repositoryCursor: String?? = .some(nil)
        var organizationSeen = Set<String>(), repositorySeen = Set<String>()
        var organizationMalformed = false, repositoryMalformed = false

        func finishOpen(_ failure: ScopeAccessFailure) {
            result.failure = failure
            if organizationCursor != nil { result.organizations.completion = result.organizations.pages > 0 ? .partial : .failed }
            if repositoryCursor != nil { result.repositories.completion = result.repositories.pages > 0 ? .partial : .failed }
        }

        for pageNumber in 1...ScopeDiscoveryPagePlan.maximumPages where organizationCursor != nil || repositoryCursor != nil {
            let plan = ScopeDiscoveryPagePlan(organizationCursor: organizationCursor, repositoryCursor: repositoryCursor)
            let reply: CommandResult
            do { try budget.check(); reply = try fetch(plan); try budget.check() }
            catch { finishOpen(ScopeAccessFailure(error)); break }
            if let failure = ScopeGraphQL.transportFailure(reply) { finishOpen(failure); break }
            guard let envelope = ScopeGraphQL.envelope(reply.stdout) else {
                finishOpen(reply.stdout.count > CommandBudget.maximumBytes ? .outputLimit : reply.exitCode != 0 ? .transport : .malformedResponse); break
            }
            // A failed process can print useful data, but cannot certify the end or cap of
            // any category requested on this page. Classify before consume clears cursors.
            var pageError: ScopeAccessFailure? = reply.exitCode != 0 ? .transport : nil
            if let errors = envelope["errors"] {
                pageError = ScopeGraphQL.rateLimited(errors as? [[String: Any]] ?? []) ? .rateLimited : .graphQLError
            }
            let data = envelope["data"] as? [String: Any]
            guard let viewer = ScopeGraphQL.viewer(data) else { finishOpen(pageError ?? .viewerUnavailable); break }
            // Every page must name the same, expected account; a mismatch discards all hints.
            // Identity is the opaque viewer ID: a display-login rename mid-run is the same account.
            guard viewer.account == expectedAccount, result.viewer.map({ $0.account == viewer.account }) ?? true else {
                return .failed(.identityMismatch)
            }
            result.viewer = viewer
            let raw = data?["viewer"] as? [String: Any]

            func consume(_ field: String, cursor: inout String??, seen: inout Set<String>, malformed: inout Bool,
                         category: inout ScopeDiscoveryCategory, normalize: (String) -> MonitoringTarget?) {
                guard cursor != nil else { return }
                guard let connection = raw?[field] as? [String: Any], let nodes = connection["nodes"] as? [Any],
                      nodes.count <= ScopeDiscoveryPagePlan.pageSize, let info = connection["pageInfo"] as? [String: Any],
                      let more = Self.boolean(info["hasNextPage"]) else {
                    category.completion = reply.exitCode != 0 || category.pages > 0 ? .partial : .failed
                    cursor = nil; return
                }
                category.pages += 1
                let key = field == "organizations" ? "login" : "nameWithOwner"
                for node in nodes {
                    guard let value = (node as? [String: Any])?[key] as? String, let target = normalize(value) else { malformed = true; continue }
                    if seen.insert(target.qualifier).inserted { category.suggestions.append(value) }
                }
                if pageError != nil { category.completion = .partial; cursor = nil; return }
                if !more { category.completion = malformed ? .partial : .exhausted; cursor = nil; return }
                if pageNumber == ScopeDiscoveryPagePlan.maximumPages { category.completion = malformed ? .partial : .capped; cursor = nil; return }
                guard let next = Self.cursor(info["endCursor"]) else { category.completion = .partial; cursor = nil; return }
                cursor = .some(next)
            }
            consume("organizations", cursor: &organizationCursor, seen: &organizationSeen, malformed: &organizationMalformed,
                    category: &result.organizations) { try? MonitoringTarget(organization: $0) }
            consume("repositories", cursor: &repositoryCursor, seen: &repositorySeen, malformed: &repositoryMalformed,
                    category: &result.repositories) { try? MonitoringTarget(repository: $0) }
            if let pageError { result.failure = pageError; break }
        }
        return result
    }
}

// MARK: gh transport

/// Draft validation and suggestions. Live code uses gh; the offline simulation conforms too.
public protocol ScopeAccessChecking: Sendable {
    func validate(scope: MonitoringScope, expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeAccessOutcome
    func discover(expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeDiscoveryResult
}

public struct ScopeGhAccess: ScopeAccessChecking {
    public var locator: GhLocator
    public var runner: CommandRunner
    public init(locator: GhLocator = GhLocator(), runner: CommandRunner = ProcessCommandRunner()) {
        self.locator = locator; self.runner = runner
    }

    public func validate(scope: MonitoringScope, expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeAccessOutcome {
        guard scope.mode == .selected else { return .failed(.malformedResponse) }
        guard let gh = locator.locate() else { return .failed(.ghMissing) }
        let plan = ScopeAccessPlan(scope: scope, expectedAccount: expectedAccount)
        do {
            let result = try runner.run(executable: gh, arguments: plan.arguments, budget: budget)
            if let failure = ScopeGraphQL.transportFailure(result) { return .failed(failure) }
            // gh exits nonzero for per-target NOT_FOUND errors yet still prints the JSON answer.
            let parsed = ScopeAccessParser.parse(result.stdout, plan: plan)
            try budget.check()
            if result.exitCode != 0, case .verified = parsed { return .failed(.transport) }
            if result.exitCode != 0, case .failed(.malformedResponse) = parsed { return .failed(.transport) }
            return parsed
        } catch { return .failed(ScopeAccessFailure(error)) }
    }

    public func discover(expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeDiscoveryResult {
        guard let gh = locator.locate() else { return .failed(.ghMissing) }
        return ScopeDiscovery.run(expectedAccount: expectedAccount, budget: budget) { plan in
            try runner.run(executable: gh, arguments: plan.arguments, budget: budget)
        }
    }
}
