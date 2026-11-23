import Foundation
import CoreFoundation

/// One operation, one request-bound viewer. Target qualifiers are batched into a bounded number
/// of searches per category (#137); every search string is built here and sent as one variable.
public struct ScopeQueryPlan: Sendable {
    public static let rowsPerCategory = 30
    /// GitHub rejects searches over 256 characters "not including operators or qualifiers" (REST
    /// search docs) and with more than five AND/OR/NOT operators. Several `org:`/`repo:` qualifiers
    /// in one search are ORed with no operator. Checked against github.com (#137): the issueCount
    /// of a 100-qualifier search equalled the sum of its 100 single-repository counts, and a
    /// 5,536-character, 200-qualifier search was accepted. Both bounds below stay inside that, and
    /// a batch never holds more targets than one request looks up.
    public static let maximumQualifiersPerSearch = maximumTargetsPerRequest
    public static let maximumSearchLength = 4096
    /// Category text without qualifiers, which GitHub limits to 256 characters.
    static let maximumUnqualifiedLength = 256
    /// One search per category and batch. Additive: a new category is one more entry here
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
        // #9: your open PRs; only those needing your action become rows (see AuthoredAttention),
        // approved and ready to merge included (#153); the rest are listed as waiting (#148).
        Category(kind: .authoredPullRequest, aliasPrefix: "authored", query: "is:pr is:open author:@me archived:false",
                 type: "PullRequest",
                 fields: " isDraft reviewDecision mergeable commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }"
                    + " reviews(last: 1, states: [CHANGES_REQUESTED]) { nodes { id submittedAt } }"),
    ]
    static let directReviewQuery = "is:pr is:open user-review-requested:@me"
    /// The longest category query: batches are shared by every category, so each one fits.
    static let longestCategoryQuery = (categories.map(\.query) + [directReviewQuery]).map(\.utf8.count).max()!
    /// Changes whenever the category set changes, so a persisted baseline from an older set
    /// re-baselines silently instead of announcing a new category's existing items (#12).
    /// 4: authored changes-requested reasons use a stable key with chronological review evidence.
    /// 5: approved and ready to merge needs you (#153), so already-approved PRs never announce on upgrade.
    public static let categoriesVersion = 5
    public struct Search: Sendable {
        public let alias: String
        public let kind: ItemKind
        /// Targets whose qualifiers this search ORs; empty for Everything.
        public let targetIndices: [Int]
        public let query: String
    }
    /// Metadata lookups per request. GitHub's per-query resource limit (RESOURCE_LIMITS_EXCEEDED)
    /// behaves like a server-time budget (#137): 190 lookups alone failed, and one set of 100 public
    /// repositories took 5.5 s to look up and failed with its 3 searches on every attempt, while
    /// 50 of them with the same searches took 4.9 s. 50 keeps each request well inside it and
    /// GitHub's 10 s request timeout.
    public static let maximumTargetsPerRequest = 50
    public let scope: MonitoringScope
    public let expectedAccount: ScopeAccount?
    /// Indices of the targets whose metadata this request looks up (all of them unless chunked).
    public let lookups: [Int]
    public let searches: [Search]
    public let arguments: [String]
    /// Viewer only: no search aliases and no target lookups, so no rows and no search cost.
    public let identityOnly: Bool

    /// Identity-only request: resolves (or verifies) the viewer while no valid selection is known.
    public init(identityFor expectedAccount: ScopeAccount?) {
        scope = .everything; self.expectedAccount = expectedAccount; lookups = []; searches = []; identityOnly = true
        arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=query {\nviewer { id login }\n}"]
    }

    /// Target indices per search, in scope order. A repository whose owner is also a selected
    /// organization is left out: the organization's searches already cover it, which keeps the
    /// batches disjoint so per-search hidden counts add up without double counting.
    /// Its metadata is still verified.
    static func batches(_ targets: [MonitoringTarget]) -> [[Int]] {
        let organizations = Set(targets.filter { $0.kind == .organization }.map(\.owner))
        return batches(targets, of: targets.indices.filter {
            !(targets[$0].kind == .repository && organizations.contains(targets[$0].owner))
        })
    }

    /// Packs `indices`, in order, into searches within the qualifier and length limits.
    private static func batches(_ targets: [MonitoringTarget], of indices: [Int]) -> [[Int]] {
        var batches: [[Int]] = [], current: [Int] = [], length = longestCategoryQuery
        for index in indices {
            let added = 1 + targets[index].qualifier.utf8.count
            if !current.isEmpty && (length + added > maximumSearchLength || current.count == maximumQualifiersPerSearch) {
                batches.append(current); current = []; length = longestCategoryQuery
            }
            current.append(index); length += added
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// One request for the whole scope. Polls use `requests`, which splits a large scope.
    public init(scope: MonitoringScope = .everything, expectedAccount: ScopeAccount? = nil,
                assignmentMode: AssignmentMode = .all) throws {
        guard scope.mode == .everything || expectedAccount != nil else { throw ScopeValidationError.invalidIdentity }
        let batches = scope.mode == .everything ? [[]] : Self.batches(scope.targets)
        self.init(scope: scope, expectedAccount: expectedAccount, assignmentMode: assignmentMode,
                  lookups: Array(scope.targets.indices), batches: Array(batches.enumerated()))
    }

    /// The poll's requests, run one after another: each looks up at most
    /// `maximumTargetsPerRequest` targets and carries the searches of those targets' batches.
    /// Batch numbers stay global, so every alias is unique across the poll. Repositories covered
    /// by a selected organization have no batch; their lookups fill the remaining room.
    public static func requests(scope: MonitoringScope, expectedAccount: ScopeAccount?,
                                assignmentMode: AssignmentMode = .all) throws -> [ScopeQueryPlan] {
        guard scope.mode == .selected, scope.targets.count > maximumTargetsPerRequest else {
            return [try ScopeQueryPlan(scope: scope, expectedAccount: expectedAccount, assignmentMode: assignmentMode)]
        }
        guard expectedAccount != nil else { throw ScopeValidationError.invalidIdentity }
        var chunks: [(lookups: [Int], batches: [(offset: Int, element: [Int])])] = []
        for batch in batches(scope.targets).enumerated() {
            if chunks.isEmpty || chunks[chunks.count - 1].lookups.count + batch.element.count > maximumTargetsPerRequest {
                chunks.append(([], []))
            }
            chunks[chunks.count - 1].lookups += batch.element; chunks[chunks.count - 1].batches.append(batch)
        }
        let searched = Set(chunks.flatMap(\.lookups))
        for index in scope.targets.indices where !searched.contains(index) {
            if let open = chunks.firstIndex(where: { $0.lookups.count < maximumTargetsPerRequest }) {
                chunks[open].lookups.append(index)
            } else { chunks.append(([index], [])) }
        }
        return chunks.map { chunk in
            ScopeQueryPlan(scope: scope, expectedAccount: expectedAccount, assignmentMode: assignmentMode,
                           lookups: chunk.lookups.sorted(), batches: chunk.batches)
        }
    }

    /// #142: a covered repository has no search of its own, so an organization whose lookup failed
    /// (SSO, lost access, renamed, or a user login saved as an organization) would hide its rows.
    /// These requests search the covered repositories of every such organization with `repo:`
    /// qualifiers, under the same batch and request limits. Each request looks its repositories up
    /// again, so a row still needs metadata verified in the same response. A repository whose own
    /// lookup already failed is left out, and batch numbers continue after the poll's, so every
    /// alias stays unique. Empty when no organization failed: a readable one is never searched twice.
    public static func fallbackRequests(scope: MonitoringScope, expectedAccount: ScopeAccount?,
                                        assignmentMode: AssignmentMode = .all,
                                        issues: [ScopedFetchIssue]) -> [ScopeQueryPlan] {
        guard scope.mode == .selected, expectedAccount != nil else { return [] }
        var failed = Set<Int>()
        for issue in issues {
            switch issue {
            case .targetUnavailable(let index), .malformedTarget(let index):
                if scope.targets.indices.contains(index) { failed.insert(index) }
            default: break
            }
        }
        let unreadable = Set(failed.filter { scope.targets[$0].kind == .organization }.map { scope.targets[$0].owner })
        let covered = scope.targets.indices.filter {
            scope.targets[$0].kind == .repository && unreadable.contains(scope.targets[$0].owner) && !failed.contains($0)
        }
        // Every lookup here is also searched, so fill each request with 50 lookups first, then batch
        // them: at most 10 requests for the 500-target ceiling, however long the names.
        var number = batches(scope.targets).count
        return stride(from: 0, to: covered.count, by: maximumTargetsPerRequest).map { start in
            let lookups = Array(covered[start..<min(start + maximumTargetsPerRequest, covered.count)])
            let numbered = batches(scope.targets, of: lookups).map { batch in
                defer { number += 1 }; return (offset: number, element: batch)
            }
            return ScopeQueryPlan(scope: scope, expectedAccount: expectedAccount, assignmentMode: assignmentMode,
                                  lookups: lookups, batches: numbered)
        }
    }

    private init(scope: MonitoringScope, expectedAccount: ScopeAccount?, assignmentMode: AssignmentMode,
                 lookups: [Int], batches: [(offset: Int, element: [Int])]) {
        self.scope = scope; self.expectedAccount = expectedAccount; self.lookups = lookups
        var definitions: [String] = [], variables: [(String, String)] = [], fields = ["viewer { id login }"]
        var searches: [Search] = []
        func variable(_ key: String, _ value: String) {
            definitions.append("$\(key): String!"); variables.append((key, value))
        }
        // Keep these lookups on every poll. A search silently drops a qualifier it can't use: on
        // github.com (#137) `repo:` with a renamed repository's old name, and with a repository that
        // doesn't exist, each gave issueCount 0 with no error, alone or among other qualifiers
        // (GitHub shows a repository you can't read as not existing). Only this metadata turns such a
        // target into Partial instead of an empty, complete-looking result, so it can't be cached
        // between polls. Re-checking cached node IDs with nodes(ids:) was no faster.
        for index in lookups {
            let target = scope.targets[index]
            variable("owner\(index)", target.owner)
            if let name = target.name {
                variable("name\(index)", name)
                fields.append("target\(index): repository(owner: $owner\(index), name: $name\(index)) { __typename id nameWithOwner }")
            } else {
                fields.append("target\(index): organization(login: $owner\(index)) { __typename id login }")
            }
        }
        for (index, batch) in batches {
            let qualifiers = batch.map { " " + scope.targets[$0].qualifier }.joined()
            for category in Self.categories {
                let alias = category.aliasPrefix + String(index)
                let searchQuery = (category.kind == .reviewRequest && assignmentMode == .direct
                    ? Self.directReviewQuery : category.query) + qualifiers
                variable(alias, searchQuery)
                fields.append("""
                    \(alias): search(query: $\(alias), type: ISSUE, first: \(Self.rowsPerCategory)) {
                      issueCount pageInfo { hasNextPage }
                      nodes { __typename ... on \(category.type) { id number title url updatedAt repository { nameWithOwner }\(category.fields) } }
                    }
                    """)
                searches.append(Search(alias: alias, kind: category.kind, targetIndices: batch, query: searchQuery))
            }
        }
        self.searches = searches
        identityOnly = false
        let query = "query(\(definitions.joined(separator: ", "))) {\n\(fields.joined(separator: "\n"))\n}"
        self.arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=\(query)"]
            + variables.flatMap { ["-f", "\($0.0)=\($0.1)"] }
    }

    /// Whether `repository` belongs to one of the search's targets (always, for Everything).
    public func includes(_ search: Search, repository: String) -> Bool {
        search.targetIndices.isEmpty || search.targetIndices.contains { scope.targets[$0].includes(repository) }
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
    /// still computing (#9), and deployments waiting on other reviewers (#10). Listed under
    /// Waiting on others (#148), with why in `attention`: never Needs you rows, badges, events or
    /// alerts. Never an ID that is also in `items`.
    public let waiting: [InboxItem]
    public var waitingOnOthers: Int { waiting.count }
    public init(viewer: ScopeViewer?, items: [InboxItem], issues: [ScopedFetchIssue], successfulSources: Int, hidden: Int = 0,
                waiting: [InboxItem] = []) {
        self.viewer = viewer; self.items = items; self.issues = issues; self.successfulSources = successfulSources
        self.hidden = hidden
        let actionable = Set(items.map(\.id))
        self.waiting = InboxEngine.dedupe(waiting.filter { !actionable.contains($0.id) })
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
        for index in plan.lookups {
            let target = plan.scope.targets[index]
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
            if matches { verified.insert(index) } else { issues.append(.malformedTarget(index)) }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var items: [String: InboxItem] = [:], successes = 0
        var waiting: [String: InboxItem] = [:]
        var authoredStates: [String: AuthoredAttention] = [:]
        var hiddenByAlias: [String: Int] = [:]
        for search in plan.searches {
            // A batch runs once any of its targets is verified. Rows of its unverified targets are
            // dropped below, and that target's own issue already keeps the poll Partial.
            let verifiedTargets = search.targetIndices.filter(verified.contains)
            if !search.targetIndices.isEmpty && verifiedTargets.isEmpty { continue }
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
                      plan.includes(search, repository: row.repository.nameWithOwner) else {
                    issues.append(.malformedRow(search.alias)); continue
                }
                if !search.targetIndices.isEmpty
                    && !verifiedTargets.contains(where: { plan.scope.targets[$0].includes(row.repository.nameWithOwner) }) { continue }
                let key = "\(search.kind.rawValue):\(row.id)"
                guard sourceIDs.insert(key).inserted else { issues.append(.malformedRow(search.alias)); continue }
                var attention: String?, attentionKeys: [String] = []
                var authoredReview: AuthoredAttention.Review?
                if search.kind == .authoredPullRequest {
                    guard let state = AuthoredAttention(node) else { issues.append(.malformedRow(search.alias)); continue }
                    // One PR seen through overlapping inclusions must agree, or the poll is Partial.
                    if let seen = authoredStates.updateValue(state, forKey: row.id), seen != state {
                        issues.append(.inconsistentDuplicate)
                    }
                    if case .waiting(let waits) = state {
                        // #148: listed under Waiting on others with why (the first reason on the row,
                        // all of them in help and VoiceOver); no attention keys, so never an event.
                        let item = InboxItem(id: key, kind: .authoredPullRequest, repository: row.repository.nameWithOwner,
                                             title: row.title, url: url, updatedAt: row.updatedAt,
                                             attention: waits.first?.text,
                                             detail: waits.count > 1 ? AuthoredAttention.WaitReason.summary(waits) : nil)
                        if waiting[key].map({ $0.updatedAt > item.updatedAt }) != true { waiting[key] = item }
                        continue
                    }
                    guard case .needsAction(let reasons) = state else { continue }
                    // One row per PR (stable ID). Each reason is its own event key, so only a gained
                    // reason, or checks failing on a new head commit, announces (#9 MED-1).
                    attention = reasons.map(\.text).joined(separator: ", ")
                    attentionKeys = reasons.map { key + "#" + $0.idComponent }
                    authoredReview = reasons.compactMap(\.review).first
                }
                var item = InboxItem(id: key, kind: search.kind, repository: row.repository.nameWithOwner,
                                     title: row.title, url: url, updatedAt: row.updatedAt, attention: attention,
                                     attentionKeys: attentionKeys)
                item.authoredReview = authoredReview
                if let old = items[key], old != item { issues.append(.inconsistentDuplicate) }
                if items[key].map({ $0.updatedAt > item.updatedAt }) != true { items[key] = item }
            }
        }
        // Hidden counts are trusted only in a clean response. With any error, malformed or missing
        // source/row, those aliases stay capped (Partial) exactly as before: when in doubt, Partial.
        // A category's batches never overlap (a repository under a selected organization is left to
        // that organization's search), so their hidden counts add up without double counting.
        var hidden = 0
        if issues.isEmpty {
            hidden = hiddenByAlias.values.reduce(0, +)
        } else {
            let capped = Set(issues.compactMap { issue -> String? in if case .capped(let alias) = issue { return alias }; return nil })
            issues += hiddenByAlias.keys.sorted().filter { !capped.contains($0) }.map { ScopedFetchIssue.capped($0) }
        }
        // A PR needing action in one inclusion is never also listed as waiting (the init drops it).
        return ScopedPollResult(viewer: viewer, items: InboxEngine.dedupe(Array(items.values)), issues: issues,
                                successfulSources: successes, hidden: hidden, waiting: Array(waiting.values))
    }
}

/// Account-bound repository polling. Callers can share one budget across bootstrap/refetch.
public protocol ScopedPolling: Sendable {
    func fetch(scope: MonitoringScope, expectedAccount: ScopeAccount?, assignmentMode: AssignmentMode,
               budget: CommandBudget) -> ScopedPollResult
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
    static func deniesAccess(_ text: String) -> Bool { GhFailure.deniesAccess(text) }
    private static func authFailure(_ result: CommandResult) -> Bool { GhFailure.isSignedOut(result) }
    public func fetch(scope: MonitoringScope = .everything, expectedAccount: ScopeAccount? = nil,
                      assignmentMode: AssignmentMode = .all) -> ScopedPollResult {
        fetch(scope: scope, expectedAccount: expectedAccount, assignmentMode: assignmentMode,
              budget: CommandBudget(timeout: timeout))
    }
    /// A large scope is several requests, one after another (#137). The first uses `budget` (the
    /// cycle's, shared with the preflight); each later one gets a renewed budget of its own, which
    /// still stops when `budget` is cancelled. Results merge into one poll; any request's issue
    /// keeps the whole poll Partial, and a different account answering ends the poll at once.
    public func fetch(scope: MonitoringScope, expectedAccount: ScopeAccount?, assignmentMode: AssignmentMode = .all,
                      budget: CommandBudget) -> ScopedPollResult {
        guard let plans = try? ScopeQueryPlan.requests(scope: scope, expectedAccount: expectedAccount, assignmentMode: assignmentMode) else {
            return .failure(.identityRequired)
        }
        guard let gh = locator.locate() else { return .failure(.ghMissing) }
        if let failure = preflight(gh, budget: budget) { return failure }
        var merged = run(plans[0], gh: gh, budget: budget)
        func runEach(_ plans: some Sequence<ScopeQueryPlan>) -> ScopedPollResult? {
            for plan in plans {
                guard merged.viewer != nil, !merged.issues.contains(.identityMismatch), !budget.isCancelled else { break }
                let next = run(plan, gh: gh, budget: budget.renewed())
                if next.issues.contains(.identityMismatch) { return next }
                merged = Self.merge(merged, next)
            }
            return nil
        }
        if let switched = runEach(plans.dropFirst()) { return switched }
        // #142: covered repositories of an organization that failed its lookup, in the same cycle.
        // Each is one more renewed-budget request, like a chunk, and only after every chunk ran.
        // The organization's own issue stays, so the poll stays Partial. Not after a rate limit or
        // sign-out, which another request can't fix.
        guard !merged.issues.contains(.rateLimited), !merged.issues.contains(.signedOut) else { return merged }
        let fallback = ScopeQueryPlan.fallbackRequests(scope: scope, expectedAccount: expectedAccount,
                                                       assignmentMode: assignmentMode, issues: merged.issues)
        return runEach(fallback) ?? merged
    }
    public func fetchIdentity(expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        guard let gh = locator.locate() else { return .failure(.ghMissing) }
        if let failure = preflight(gh, budget: budget) { return failure }
        return run(ScopeQueryPlan(identityFor: expectedAccount), gh: gh, budget: budget)
    }
    /// Requests cover disjoint searches, so rows, sources and waiting rows add up (a #142 fallback
    /// request looks up targets again, but only after their organization failed, which is Partial).
    /// Hidden counts are trusted only when every request was clean.
    static func merge(_ first: ScopedPollResult, _ next: ScopedPollResult) -> ScopedPollResult {
        let issues = first.issues + next.issues
        return ScopedPollResult(viewer: first.viewer, items: InboxEngine.dedupe(first.items + next.items), issues: issues,
                                successfulSources: first.successfulSources + next.successfulSources,
                                hidden: issues.isEmpty ? first.hidden + next.hidden : 0,
                                waiting: first.waiting + next.waiting)
    }
    private func preflight(_ gh: URL, budget: CommandBudget) -> ScopedPollResult? {
        do {
            let auth = try runner.run(executable: gh, arguments: GhFailure.authStatusArguments, budget: budget)
            guard auth.outputComplete else { return .failure(.incompleteOutput) }
            if auth.exitCode != 0 && !auth.stderrText.lowercased().contains("unknown flag") {
                switch GhFailure.classifyPreflight(auth) {
                case .rateLimited: return .failure(.rateLimited)
                case .accessDenied: return .failure(.accessDenied)
                case .signedOut: return .failure(.signedOut)
                case .transport, .ghMissing: return .failure(.transport)
                }
            }
            return nil
        } catch { return Self.failure(error) }
    }
    private static func failure(_ error: Error) -> ScopedPollResult {
        switch error {
        case CommandError.outputLimitExceeded: return .failure(.outputLimit)
        case CommandError.timedOut: return .failure(.deadline)
        case CommandError.cancelled: return .failure(.cancelled)
        default: return .failure(.transport)
        }
    }
    private func run(_ plan: ScopeQueryPlan, gh: URL, budget: CommandBudget) -> ScopedPollResult {
        do {
            let result = try runner.run(executable: gh, arguments: plan.arguments, budget: budget)
            if Self.authFailure(result) { return .failure(.signedOut) }
            guard result.outputComplete else { return .failure(.incompleteOutput) }
            if result.exitCode != 0 && GhFailure.isRateLimited(result.stderrText) { return .failure(.rateLimited) }
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
                                        successfulSources: parsed.successfulSources, waiting: parsed.waiting)
            }
            if result.exitCode != 0 && parsed.viewer == nil && !parsed.issues.contains(.graphQLError)
                && !parsed.issues.contains(.rateLimited) && !parsed.issues.contains(.accessDenied) { return .failure(.transport) }
            // A failing gh process cannot turn a superficially valid empty JSON payload into success.
            if result.exitCode != 0 && parsed.issues.isEmpty {
                return ScopedPollResult(viewer: parsed.viewer, items: parsed.items, issues: [.transport],
                                        successfulSources: parsed.successfulSources, waiting: parsed.waiting)
            }
            return parsed
        } catch { return Self.failure(error) }
    }
}
