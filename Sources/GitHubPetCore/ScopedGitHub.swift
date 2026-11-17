import Foundation
import CoreFoundation

/// One operation, one request-bound viewer. Every search has exactly one safe inclusion qualifier.
public struct ScopeQueryPlan: Sendable {
    public static let rowsPerCategory = 30
    /// One search per category and inclusion. Additive: a new category is one more entry here
    /// (and its row handling in `ScopedResponseParser`).
    public struct Category: Sendable {
        public let kind: ItemKind
        public let aliasPrefix: String
        public let query: String
        public let type: String
        /// Extra PullRequest/Issue fields after the shared row fields.
        public let fields: String
    }
    public static let categories: [Category] = [
        Category(kind: .reviewRequest, aliasPrefix: "reviews", query: "is:pr is:open review-requested:@me",
                 type: "PullRequest", fields: ""),
        Category(kind: .assignedIssue, aliasPrefix: "assigned", query: "is:issue is:open assignee:@me",
                 type: "Issue", fields: ""),
        // #9: your open PRs; only those needing your action become rows (see AuthoredAttention).
        Category(kind: .authoredPullRequest, aliasPrefix: "authored", query: "is:pr is:open author:@me archived:false",
                 type: "PullRequest",
                 fields: " isDraft reviewDecision mergeable commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }"),
    ]
    /// Changes whenever the category set changes, so a persisted baseline from an older set
    /// re-baselines silently instead of announcing a new category's existing items (#12).
    public static let categoriesVersion = 2
    public struct Search: Sendable {
        public let alias: String
        public let kind: ItemKind
        public let targetIndex: Int?
    }
    public let scope: MonitoringScope
    public let expectedAccount: ScopeAccount?
    public let searches: [Search]
    public let arguments: [String]
    /// Viewer only: no search aliases and no target lookups, so no rows and no search cost.
    public let identityOnly: Bool

    /// Identity-only request: resolves (or verifies) the viewer while no valid selection is known.
    public init(identityFor expectedAccount: ScopeAccount?) {
        scope = .everything; self.expectedAccount = expectedAccount; searches = []; identityOnly = true
        arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=query {\nviewer { id login }\n}"]
    }

    public init(scope: MonitoringScope = .everything, expectedAccount: ScopeAccount? = nil) throws {
        guard scope.mode == .everything || expectedAccount != nil else { throw ScopeValidationError.invalidIdentity }
        self.scope = scope; self.expectedAccount = expectedAccount
        var definitions: [String] = [], variables: [(String, String)] = [], fields = ["viewer { id login }"]
        var searches: [Search] = []
        func variable(_ key: String, _ value: String) {
            definitions.append("$\(key): String!"); variables.append((key, value))
        }
        for (index, target) in scope.targets.enumerated() {
            variable("owner\(index)", target.owner)
            if let name = target.name {
                variable("name\(index)", name)
                fields.append("target\(index): repository(owner: $owner\(index), name: $name\(index)) { __typename id nameWithOwner }")
            } else {
                fields.append("target\(index): organization(login: $owner\(index)) { __typename id login }")
            }
        }
        let inclusions: [MonitoringTarget?] = scope.mode == .everything ? [nil] : scope.targets.map(Optional.some)
        for (index, target) in inclusions.enumerated() {
            for category in Self.categories {
                let alias = category.aliasPrefix + String(index)
                variable(alias, category.query + (target.map { " " + $0.qualifier } ?? ""))
                fields.append("""
                    \(alias): search(query: $\(alias), type: ISSUE, first: \(Self.rowsPerCategory)) {
                      issueCount pageInfo { hasNextPage }
                      nodes { __typename ... on \(category.type) { id number title url updatedAt repository { nameWithOwner }\(category.fields) } }
                    }
                    """)
                searches.append(Search(alias: alias, kind: category.kind, targetIndex: target == nil ? nil : index))
            }
        }
        self.searches = searches
        identityOnly = false
        let query = "query(\(definitions.joined(separator: ", "))) {\n\(fields.joined(separator: "\n"))\n}"
        self.arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=\(query)"]
            + variables.flatMap { ["-f", "\($0.0)=\($0.1)"] }
    }
}

public enum ScopedFetchIssue: Equatable, Sendable {
    case viewerUnavailable, identityMismatch, identityRequired
    case targetUnavailable(Int), malformedTarget(Int)
    case missingSource(String), malformedSource(String), malformedRow(String), capped(String), inconsistentDuplicate
    case graphQLError, rateLimited, ghMissing, signedOut, transport, deadline, outputLimit, incompleteOutput, cancelled
    /// Missing token scopes, SAML/SSO authorization or an HTTP 403 that is not a rate limit (#7).
    case accessDenied
}

public struct ScopedPollResult: Equatable, Sendable {
    public let viewer: ScopeViewer?
    public let items: [InboxItem]
    public let issues: [ScopedFetchIssue]
    public let successfulSources: Int
    /// Matches GitHub counted but the viewer can't see (#35): only for a fully clean response.
    public let hidden: Int
    /// Your open PRs that need nothing from you right now, or whose conflict status GitHub is
    /// still computing (#9). Informational only: never rows, counts, badges or alerts.
    public let waitingOnOthers: Int
    public init(viewer: ScopeViewer?, items: [InboxItem], issues: [ScopedFetchIssue], successfulSources: Int, hidden: Int = 0,
                waitingOnOthers: Int = 0) {
        self.viewer = viewer; self.items = items; self.issues = issues; self.successfulSources = successfulSources
        self.hidden = hidden; self.waitingOnOthers = waitingOnOthers
    }
    public var complete: Bool { viewer != nil && successfulSources > 0 && issues.isEmpty }
    /// Fixed texts (#7): never gh's stderr or GitHub's message, which can name organizations.
    public static let accessDeniedMessage = "GitHub denied access: the GitHub CLI sign-in lacks a token scope or SAML single sign-on authorization. Run gh auth refresh, and authorize SSO if your organization requires it"
    public static let rateLimitedMessage = "GitHub rate limit reached. GitHub Pet will try again on the next refresh"
    public var outcome: FetchOutcome {
        if issues.contains(.ghMissing) { return .failure(.ghMissing) }
        if issues.contains(.signedOut) { return .failure(.unauthenticated) }
        guard viewer != nil, successfulSources > 0 else {
            if issues.contains(.rateLimited) { return .failure(.failed(Self.rateLimitedMessage)) }
            if issues.contains(.accessDenied) { return .failure(.failed(Self.accessDeniedMessage)) }
            return .failure(.failed("Monitoring scope could not be verified"))
        }
        return .snapshot(items: items, complete: complete, hidden: complete ? hidden : 0)
    }
    public static func failure(_ issue: ScopedFetchIssue, viewer: ScopeViewer? = nil) -> Self {
        Self(viewer: viewer, items: [], issues: [issue], successfulSources: 0)
    }
}

public enum ScopedResponseParser {
    private struct Row: Decodable {
        struct Repository: Decodable { let nameWithOwner: String }
        let __typename: String
        let id: String
        let number: Int
        let title: String
        let url: String
        let updatedAt: Date
        let repository: Repository
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= Double(Int32.max),
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    /// Display metadata only: github.com managed logins also contain underscores.
    /// Keep full-input validation separate from target qualifiers and node-ID identity.
    private static func viewerLogin(_ value: String) -> Bool {
        func alphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        let bytes = value.utf8
        return (1...39).contains(bytes.count) && alphanumeric(bytes.first!) && alphanumeric(bytes.last!)
            && bytes.allSatisfy { alphanumeric($0) || $0 == 45 || $0 == 95 }
    }
    public static func parse(_ bytes: Data, plan: ScopeQueryPlan) -> ScopedPollResult {
        guard bytes.count <= CommandBudget.maximumBytes else { return .failure(.outputLimit) }
        guard let envelope = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            return .failure(.viewerUnavailable)
        }
        var issues: [ScopedFetchIssue] = []
        if let errors = envelope["errors"] {
            let array = errors as? [[String: Any]] ?? []
            func type(_ error: [String: Any]) -> String? {
                error["type"] as? String ?? (error["extensions"] as? [String: Any])?["type"] as? String
            }
            let limited = array.contains { type($0) == "RATE_LIMITED" }
            let denied = array.contains { error in
                ["FORBIDDEN", "INSUFFICIENT_SCOPES"].contains(type(error) ?? "")
                    || (error["message"] as? String).map(ScopedGhClient.deniesAccess) == true
            }
            issues.append(limited ? .rateLimited : denied ? .accessDenied : .graphQLError)
        }
        guard let body = envelope["data"] as? [String: Any],
              let rawViewer = body["viewer"] as? [String: Any], let id = rawViewer["id"] as? String,
              let login = rawViewer["login"] as? String, viewerLogin(login),
              let account = try? ScopeAccount(viewerID: id) else {
            return ScopedPollResult(viewer: nil, items: [], issues: issues + [.viewerUnavailable], successfulSources: 0)
        }
        let viewer = ScopeViewer(account: account, login: login)
        if let expected = plan.expectedAccount, expected != account { return .failure(.identityMismatch, viewer: viewer) }
        var verified = Set<Int>()
        var verifiedOwners: [Int: String] = [:]
        for (index, target) in plan.scope.targets.enumerated() {
            guard let metadata = body["target\(index)"] as? [String: Any] else {
                issues.append(.targetUnavailable(index)); continue
            }
            guard let id = metadata["id"] as? String, ScopeASCII.nodeID(id) else {
                issues.append(.malformedTarget(index)); continue
            }
            let type = metadata["__typename"] as? String
            let matches: Bool
            if target.kind == .organization {
                matches = type == "Organization" && (metadata["login"] as? String)?.lowercased() == target.owner
            } else {
                matches = type == "Repository" && (metadata["nameWithOwner"] as? String)?.lowercased() == "\(target.owner)/\(target.name!)"
            }
            if matches {
                verified.insert(index)
                // Use the canonical response name only after metadata has verified this target.
                let canonicalName = metadata[target.kind == .organization ? "login" : "nameWithOwner"] as? String
                verifiedOwners[index] = canonicalName?.split(separator: "/").first.map { String($0).lowercased() }
            } else { issues.append(.malformedTarget(index)) }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var items: [String: InboxItem] = [:], successes = 0
        var waiting = Set<String>()
        var authoredStates: [String: AuthoredAttention] = [:]
        var hiddenByAlias: [String: Int] = [:]
        for search in plan.searches {
            if let index = search.targetIndex, !verified.contains(index) { continue }
            guard let page = body[search.alias] as? [String: Any] else { issues.append(.missingSource(search.alias)); continue }
            guard let count = integer(page["issueCount"]), let nodes = page["nodes"] as? [Any],
                  nodes.count <= ScopeQueryPlan.rowsPerCategory,
                  let info = page["pageInfo"] as? [String: Any], let more = boolean(info["hasNextPage"]) else {
                issues.append(.malformedSource(search.alias)); continue
            }
            successes += 1
            // #35: a full page with more matches (or a next page) is capped: Partial. Fewer nodes
            // than a page with no next page means GitHub counted matches the viewer can't see.
            if more || (nodes.count >= ScopeQueryPlan.rowsPerCategory && count > nodes.count) {
                issues.append(.capped(search.alias))
            } else if count > nodes.count {
                hiddenByAlias[search.alias] = count - nodes.count
            }
            if count < nodes.count { issues.append(.malformedSource(search.alias)) }
            var sourceIDs = Set<String>()
            for node in nodes {
                guard let data = try? JSONSerialization.data(withJSONObject: node, options: [.fragmentsAllowed]),
                      let row = try? decoder.decode(Row.self, from: data), row.number > 0,
                      ScopeASCII.nodeID(row.id),
                      row.__typename == (search.kind == .assignedIssue ? "Issue" : "PullRequest"),
                      let repository = try? MonitoringTarget(repository: row.repository.nameWithOwner),
                      let url = SafeLink.validated(row.url),
                      url.path.lowercased() == "/\(repository.owner)/\(repository.name!)/\(search.kind == .assignedIssue ? "issues" : "pull")/\(row.number)",
                      search.targetIndex.map({ plan.scope.targets[$0].includes(row.repository.nameWithOwner) }) ?? true else {
                    issues.append(.malformedRow(search.alias)); continue
                }
                let key = "\(search.kind.rawValue):\(row.id)"
                guard sourceIDs.insert(key).inserted else { issues.append(.malformedRow(search.alias)); continue }
                var attention: String?, attentionKeys: [String] = []
                if search.kind == .authoredPullRequest {
                    guard let state = AuthoredAttention(node) else { issues.append(.malformedRow(search.alias)); continue }
                    // One PR seen through overlapping inclusions must agree, or the poll is Partial.
                    if let seen = authoredStates.updateValue(state, forKey: row.id), seen != state {
                        issues.append(.inconsistentDuplicate)
                    }
                    guard case .needsAction(let reasons) = state else { waiting.insert(row.id); continue }
                    // One row per PR (stable ID). Each reason is its own event key, so only a gained
                    // reason, or checks failing on a new head commit, announces (#9 MED-1).
                    attention = reasons.map(\.text).joined(separator: ", ")
                    attentionKeys = reasons.map { key + "#" + $0.idComponent }
                }
                let item = InboxItem(id: key, kind: search.kind, repository: row.repository.nameWithOwner,
                                     title: row.title, url: url, updatedAt: row.updatedAt, attention: attention,
                                     attentionKeys: attentionKeys)
                if let old = items[key], old != item { issues.append(.inconsistentDuplicate) }
                if items[key].map({ $0.updatedAt > item.updatedAt }) != true { items[key] = item }
            }
        }
        // Hidden counts are trusted only in a clean response. With any error, malformed or missing
        // source/row, those aliases stay capped (Partial) exactly as before: when in doubt, Partial.
        // An org search already counts its repositories for the same category, so a covered
        // repository's hidden count is excluded. No containment is inferred for unverified owners.
        var organizationHidden: [ItemKind: [String: Int]] = [:]
        for search in plan.searches {
            guard let index = search.targetIndex, plan.scope.targets[index].kind == .organization,
                  let owner = verifiedOwners[index] else { continue }
            organizationHidden[search.kind, default: [:]][owner] = max(organizationHidden[search.kind]?[owner] ?? 0,
                                                                      hiddenByAlias[search.alias] ?? 0)
        }
        /// The verified owner of a repository search whose org is also searched for the same kind.
        func coveringOwner(_ search: ScopeQueryPlan.Search) -> String? {
            guard let index = search.targetIndex, plan.scope.targets[index].kind == .repository,
                  let owner = verifiedOwners[index], organizationHidden[search.kind]?[owner] != nil else { return nil }
            return owner
        }
        func coveringHidden(_ search: ScopeQueryPlan.Search) -> Int? {
            coveringOwner(search).flatMap { organizationHidden[search.kind]?[$0] }
        }
        // Covered repositories' hidden matches are a subset of their org's, so their per-owner sum
        // above the org's count contradicts that coverage (#35 MED-1, #60 LOW-A): never drop it into
        // All clear; treat the response as capped (Partial).
        if issues.isEmpty {
            var coveredHidden: [ItemKind: [String: Int]] = [:]
            for search in plan.searches {
                guard let owner = coveringOwner(search) else { continue }
                coveredHidden[search.kind, default: [:]][owner, default: 0] += hiddenByAlias[search.alias] ?? 0
            }
            issues += plan.searches.filter { search in
                guard let owner = coveringOwner(search), let org = organizationHidden[search.kind]?[owner] else { return false }
                return (coveredHidden[search.kind]?[owner] ?? 0) > org
            }.map { ScopedFetchIssue.capped($0.alias) }
        }
        var hidden = 0
        if issues.isEmpty {
            for search in plan.searches where coveringHidden(search) == nil {
                hidden += hiddenByAlias[search.alias] ?? 0
            }
        } else {
            let capped = Set(issues.compactMap { issue -> String? in if case .capped(let alias) = issue { return alias }; return nil })
            issues += hiddenByAlias.keys.sorted().filter { !capped.contains($0) }.map { ScopedFetchIssue.capped($0) }
        }
        // A PR needing action in one inclusion is never also counted as waiting.
        let actionable = Set(items.values.filter { $0.kind == .authoredPullRequest }.map { $0.id.split(separator: ":")[1] }.map(String.init))
        return ScopedPollResult(viewer: viewer, items: InboxEngine.dedupe(Array(items.values)), issues: issues,
                                successfulSources: successes, hidden: hidden,
                                waitingOnOthers: waiting.subtracting(actionable).count)
    }
}

/// Account-bound repository polling. Callers can share one budget across bootstrap/refetch.
public protocol ScopedPolling: Sendable {
    func fetch(scope: MonitoringScope, expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult
    /// Viewer only (no search aliases): used while no valid saved selection is known.
    func fetchIdentity(expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult
}

public struct ScopedGhClient: ScopedPolling {
    public var locator: GhLocator
    public var runner: CommandRunner
    public var timeout: TimeInterval
    public init(locator: GhLocator = GhLocator(), runner: CommandRunner = ProcessCommandRunner(), timeout: TimeInterval = 20) {
        self.locator = locator; self.runner = runner; self.timeout = timeout
    }
    /// Scope, SAML/SSO and 403 wording from gh or GitHub. Checked after rate limits, which are 403s too.
    /// Multi-word phrases only: a target login can't contain a space, so a name such as
    /// "saml-team" in a "Could not resolve" message never reads as a denial.
    static func deniesAccess(_ text: String) -> Bool {
        let message = text.lowercased()
        return ["http 403", "saml enforcement", "saml sso", "saml single sign-on", "single sign-on (sso)",
                "required scopes", "insufficient_scopes", "not been granted"]
            .contains(where: message.contains)
    }
    private static func authFailure(_ result: CommandResult) -> Bool {
        let message = result.stderrText.lowercased()
        return GhClient.isAuthFailure(result) || message.contains("bad credentials") || message.contains("http 401")
    }
    public func fetch(scope: MonitoringScope = .everything, expectedAccount: ScopeAccount? = nil) -> ScopedPollResult {
        fetch(scope: scope, expectedAccount: expectedAccount, budget: CommandBudget(timeout: timeout))
    }
    public func fetch(scope: MonitoringScope, expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        guard let plan = try? ScopeQueryPlan(scope: scope, expectedAccount: expectedAccount) else {
            return .failure(.identityRequired)
        }
        return run(plan, budget: budget)
    }
    public func fetchIdentity(expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        run(ScopeQueryPlan(identityFor: expectedAccount), budget: budget)
    }
    private func run(_ plan: ScopeQueryPlan, budget: CommandBudget) -> ScopedPollResult {
        guard let gh = locator.locate() else { return .failure(.ghMissing) }
        do {
            let auth = try runner.run(executable: gh, arguments: GhClient.authStatusArguments, budget: budget)
            guard auth.outputComplete else { return .failure(.incompleteOutput) }
            if auth.exitCode != 0 && !auth.stderrText.lowercased().contains("unknown flag") {
                let message = auth.stderrText.lowercased()
                if message.contains("rate limit") { return .failure(.rateLimited) }
                if Self.deniesAccess(message) { return .failure(.accessDenied) }
                if ["network", "could not resolve", "connection", "timed out", "dial tcp"].contains(where: message.contains) {
                    return .failure(.transport)
                }
                return .failure(auth.exitCode == 1 || Self.authFailure(auth) ? .signedOut : .transport)
            }
            let result = try runner.run(executable: gh, arguments: plan.arguments, budget: budget)
            if Self.authFailure(result) { return .failure(.signedOut) }
            guard result.outputComplete else { return .failure(.incompleteOutput) }
            if result.exitCode != 0 && result.stderrText.lowercased().contains("rate limit") { return .failure(.rateLimited) }
            let parsed = ScopedResponseParser.parse(result.stdout, plan: plan)
            try budget.check()
            // Another account answered: identity takes precedence over any denial or exit status, so
            // the session restores that account's scope instead of reporting the wrong one (#60).
            if parsed.issues.contains(.identityMismatch) { return parsed }
            // One SAML-enforced or forbidden target still leaves the others' rows on stdout:
            // Partial with those rows. Fail the whole poll only when nothing usable came back.
            if result.exitCode != 0 && Self.deniesAccess(result.stderrText) {
                guard parsed.viewer != nil, parsed.successfulSources > 0 else { return .failure(.accessDenied) }
                let issues = parsed.issues.contains(.accessDenied) ? parsed.issues : parsed.issues + [.accessDenied]
                return ScopedPollResult(viewer: parsed.viewer, items: parsed.items, issues: issues,
                                        successfulSources: parsed.successfulSources)
            }
            if result.exitCode != 0 && parsed.viewer == nil && !parsed.issues.contains(.graphQLError)
                && !parsed.issues.contains(.rateLimited) && !parsed.issues.contains(.accessDenied) { return .failure(.transport) }
            // A failing gh process cannot turn a superficially valid empty JSON payload into success.
            if result.exitCode != 0 && parsed.issues.isEmpty {
                return ScopedPollResult(viewer: parsed.viewer, items: parsed.items, issues: [.transport],
                                        successfulSources: parsed.successfulSources)
            }
            return parsed
        } catch CommandError.outputLimitExceeded { return .failure(.outputLimit) }
        catch CommandError.timedOut { return .failure(.deadline) }
        catch CommandError.cancelled { return .failure(.cancelled) }
        catch { return .failure(.transport) }
    }
}
