import Foundation
import GitHubPetCore

/// Constructed only by --simulate-monitoring-scope: offline draft validation and discovery
/// for the Settings editor. Replies go through the production parsers; no gh, no network.
///
/// Invented-target rule: an owner starting with `demo-` is accessible unless the entry contains
/// `denied`; `demo-renamed` resolves to a different current name. Anything else is unavailable.
final class ScopeAccessSimulation: ScopeAccessChecking, @unchecked Sendable {
    enum DiscoveryMode: String, CaseIterable { case complete, capped, partial, denied, identityMismatch }
    enum ValidationMode: String, CaseIterable { case normal, networkFailure }

    fileprivate let lock = NSLock()
    fileprivate let account: @Sendable () -> ScopeAccount
    private var discoveryMode = DiscoveryMode.complete
    private var validationMode = ValidationMode.normal
    fileprivate var browseMode = ScopeBrowseFixture.Mode.complete
    private var holdNext = false
    private var held: [DispatchSemaphore] = []
    private var validations = 0, discoveryPages = 0

    private let holdLimit: Duration?
    /// `holdLimit` matches ScopeSimulation: nil only for tests with a frozen budget clock.
    init(holdLimit: Duration? = .seconds(20), account: @escaping @Sendable () -> ScopeAccount) {
        self.holdLimit = holdLimit; self.account = account
    }

    func setDiscovery(_ mode: DiscoveryMode) { lock.lock(); discoveryMode = mode; lock.unlock() }
    func setValidation(_ mode: ValidationMode) { lock.lock(); validationMode = mode; lock.unlock() }
    func holdNextValidation() { lock.lock(); holdNext = true; lock.unlock() }
    func releaseValidations() {
        lock.lock(); let gates = held; held = []; lock.unlock()
        gates.forEach { $0.signal() }
    }
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    var validationCount: Int { lock.lock(); defer { lock.unlock() }; return validations }
    var discoveryPageCount: Int { lock.lock(); defer { lock.unlock() }; return discoveryPages }
    var status: String {
        lock.lock(); defer { lock.unlock() }
        return "Simulated Settings checks · \(validations) validations · \(discoveryPages) discovery pages · \(held.count) held · discovery \(discoveryMode.rawValue) · validation \(validationMode.rawValue)"
    }

    private func viewerJSON(_ account: ScopeAccount) -> [String: Any] {
        ["id": account.viewerID, "login": account == ScopeSimulation.accountA ? "demo-a_sim" : "demo-b_sim"]
    }

    private static func accessible(_ target: MonitoringTarget) -> Bool {
        target.owner.hasPrefix("demo-") && !target.qualifier.contains("denied")
    }

    func validate(scope: MonitoringScope, expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeAccessOutcome {
        lock.lock()
        validations += 1
        let mode = validationMode
        let gate = holdNext ? DispatchSemaphore(value: 0) : nil
        if let gate { held.append(gate) }
        holdNext = false
        lock.unlock()
        if let gate {
            // Bounded hold (runs on a Dispatch thread, never the cooperative pool).
            let deadline = holdLimit.map { ContinuousClock.now.advanced(by: $0) }
            while gate.wait(timeout: .now() + 0.05) == .timedOut {
                if budget.remaining <= 0 || deadline.map({ ContinuousClock.now >= $0 }) == true {
                    lock.lock(); held.removeAll { $0 === gate }; lock.unlock()
                    return .failed(.deadline)
                }
            }
        }
        do { try budget.check() } catch { return .failed(ScopeAccessFailure(error)) }
        if mode == .networkFailure { return .failed(.transport) }
        // Viewer is read at reply time: switching simulated accounts during a hold yields a mismatch.
        let plan = ScopeAccessPlan(scope: scope, expectedAccount: expectedAccount)
        var data: [String: Any] = ["viewer": viewerJSON(account())]
        var errors: [[String: Any]] = []
        for (index, target) in scope.targets.enumerated() {
            let alias = "target\(index)"
            guard Self.accessible(target) else {
                data[alias] = NSNull()
                errors.append(["type": "NOT_FOUND", "path": [alias], "message": "Could not resolve"])
                continue
            }
            let renamed = target.owner == "demo-renamed" ? "-moved" : ""
            if let name = target.name {
                data[alias] = ["__typename": "Repository", "id": "R_sim_\(index)", "nameWithOwner": "\(target.owner)/\(name)\(renamed)"]
            } else {
                data[alias] = ["__typename": "Organization", "id": "O_sim_\(index)", "login": target.owner + renamed]
            }
        }
        var envelope: [String: Any] = ["data": data]
        if !errors.isEmpty { envelope["errors"] = errors }
        guard let bytes = try? JSONSerialization.data(withJSONObject: envelope), budget.reserve(bytes.count) else {
            return .failed(.outputLimit)
        }
        return ScopeAccessParser.parse(bytes, plan: plan)
    }

    static func organizations(_ mode: DiscoveryMode) -> [String] {
        [.capped, .partial, .identityMismatch].contains(mode) ? (0..<200).map { String(format: "demo-org-%03d", $0) } : ["demo-a", "demo-b", "demo-c"]
    }
    static let repositories = ["demo-a/pet", "demo-b/pet", "demo-c/tools"]

    func discover(expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeDiscoveryResult {
        lock.lock(); let mode = discoveryMode; lock.unlock()
        var pageNumber = 0
        return ScopeDiscovery.run(expectedAccount: expectedAccount, budget: budget) { plan in
            pageNumber += 1
            self.lock.lock(); self.discoveryPages += 1; self.lock.unlock()
            if mode == .denied {
                return CommandResult(exitCode: 4, stdout: Data(), stderr: Data("To get started with GitHub CLI, please run: gh auth login".utf8))
            }
            var viewer = self.viewerJSON(self.account())
            if mode == .identityMismatch && pageNumber == 2 {
                viewer = self.viewerJSON(self.account() == ScopeSimulation.accountA ? ScopeSimulation.accountB : ScopeSimulation.accountA)
            }
            func connection(_ values: [String], cursor: String??, key: String) -> [String: Any] {
                let start = cursor.flatMap { $0 }.flatMap { Int($0.dropFirst("cursor".count)) } ?? 0
                let slice = Array(values.dropFirst(start).prefix(ScopeDiscoveryPagePlan.pageSize))
                let end = start + slice.count
                return ["nodes": slice.map { [key: $0] },
                        "pageInfo": ["hasNextPage": end < values.count, "endCursor": "cursor\(end)"]]
            }
            if case .some = plan.organizationCursor {
                viewer["organizations"] = connection(Self.organizations(mode), cursor: plan.organizationCursor, key: "login")
            }
            if case .some = plan.repositoryCursor {
                viewer["repositories"] = connection(Self.repositories, cursor: plan.repositoryCursor, key: "nameWithOwner")
            }
            var envelope: [String: Any] = ["data": ["viewer": viewer]]
            if mode == .partial && pageNumber == 2 { envelope["errors"] = [["message": "Simulated partial page"]] }
            let bytes = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
            guard budget.reserve(bytes.count) else { throw CommandError.outputLimitExceeded }
            return CommandResult(exitCode: 0, stdout: bytes, stderr: Data())
        }
    }
}

// MARK: Scope browser (#137)

/// Offline browse answers for Demo, `--simulate-monitoring-scope` and the offscreen renders.
/// Invented `demo-` owners only; replies are JSON passed through the production parsers.
/// `demo-tidewater` is always withheld (as unauthorized SSO is), `demo-quiet-meadow` is truly
/// empty, and `demo-harbor` is larger than one page.
struct ScopeBrowseFixture: ScopeBrowsing {
    enum Mode: String, CaseIterable, Sendable {
        case complete, partial, rateLimited, denied, signedOut, ghMissing, empty, identityMismatch
    }
    let mode: Mode
    let account: ScopeAccount
    let login: String
    /// Pushed dates are relative to this instant (the app clock).
    let now: Date
    /// The account a reply names; differs from `account` only to simulate a switch.
    var replyAccount: ScopeAccount { mode == .identityMismatch ? ScopeSimulation.accountB : account }

    static let organizations: [(login: String, count: Int)] = [
        ("demo-example-org", 240), ("demo-lumen-labs", 38), ("demo-harbor", 6500),
        ("demo-tidewater", 0), ("demo-quiet-meadow", 0),
    ]
    static let words = ["lantern", "harbor", "beacon", "atlas", "comet", "delta", "ember", "fjord", "grove", "helix",
                        "iris", "juniper", "kelp", "lumen", "meadow", "nimbus", "orbit", "pebble", "quartz", "ripple"]
    static let suffixes = ["api", "web", "docs", "infra", "cli", "sdk", "tools", "site", "worker", "data", "ios", "android"]

    func count(_ owner: ScopeBrowseOwner) -> Int {
        if mode == .empty { return 0 }
        switch owner.kind {
        case .viewer: return 12
        case .shared: return 3
        case .organization: return Self.organizations.first { $0.login == owner.login }?.count ?? 0
        }
    }

    /// Deterministic rows, newest push first: every 7th archived, every 5th a fork, odd private.
    func all(_ owner: ScopeBrowseOwner, sort: ScopeBrowseSort) -> [[String: Any]] {
        let total = count(owner)
        let rows: [[String: Any]] = (0..<total).map { (index: Int) -> [String: Any] in
            // Shared row 2 belongs to a managed-user login ('_'): listed, but not a target.
            let ownerLogin = owner.kind == .viewer ? login : owner.kind == .shared ? (index == 2 ? "demo_managed" : "demo-partner") : owner.login
            let word: String = Self.words[index % Self.words.count]
            let suffix: String = Self.suffixes[(index / Self.words.count) % Self.suffixes.count]
            let unique: String = index >= Self.words.count * Self.suffixes.count ? "-\(index)" : ""
            let name = word + "-" + suffix + unique
            let step: Double = index < 10 ? 3_600 * 5 : 86_400 * 9
            let pushed = now.addingTimeInterval(-Double(index) * step)
            return ["nameWithOwner": "\(ownerLogin)/\(name)", "isPrivate": index % 2 == 1, "isArchived": index % 7 == 6,
                    "isFork": index % 5 == 4, "pushedAt": ScopeBrowseParser.dates.string(from: pushed)]
        }
        return sort == .pushed ? rows : rows.sorted { ($0["nameWithOwner"] as! String) < ($1["nameWithOwner"] as! String) }
    }

    private func viewer(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["id": replyAccount.viewerID, "login": login].merging(extra) { $1 }
    }
    private var rateLimit: [String: Any] {
        ["remaining": 4_900, "resetAt": ScopeBrowseParser.dates.string(from: now.addingTimeInterval(1_800))]
    }
    private func reply(_ envelope: [String: Any], exitCode: Int32 = 0) -> CommandResult {
        CommandResult(exitCode: exitCode, stdout: (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data())
    }
    /// Account-wide failures that stop every request before GitHub answers.
    private var blocked: CommandResult? {
        switch mode {
        case .signedOut: return CommandResult(exitCode: 4, stderr: Data("To get started with GitHub CLI, please run: gh auth login".utf8))
        default: return nil
        }
    }

    func owners(_ plan: ScopeOwnersPlan, budget: CommandBudget) -> ScopeOwnersResult {
        if mode == .ghMissing { return ScopeOwnersResult(failure: .ghMissing) }
        if let blocked { return ScopeBrowseParser.owners(blocked, plan: plan) }
        var errors: [[String: Any]] = []
        let nodes: [Any] = Self.organizations.enumerated().map { index, organization in
            if organization.login == "demo-tidewater" {
                errors.append(["type": "FORBIDDEN", "path": ["viewer", "organizations", "nodes", index, "repositories"],
                               "message": "Resource protected by organization SAML enforcement."])
                return ["login": organization.login, "repositories": NSNull()]
            }
            return ["login": organization.login, "repositories": ["totalCount": mode == .empty ? 0 : organization.count]]
        }
        // The owners list is answered by the expected account; mismatches surface on pages.
        var data: [String: Any] = ["viewer": ["id": account.viewerID, "login": login,
                                              "own": ["totalCount": mode == .empty ? 0 : 12],
                                              "shared": ["totalCount": mode == .empty ? 0 : 3],
                                              "organizations": ["totalCount": nodes.count, "pageInfo": ["hasNextPage": false], "nodes": nodes]],
                                   "rateLimit": rateLimit]
        return ScopeBrowseParser.owners(reply(["data": data, "errors": errors]), plan: plan)
    }

    private func pageFailure(_ owner: ScopeBrowseOwner) -> CommandResult? {
        if let blocked { return blocked }
        let deniedOwner = owner.login == "demo-tidewater" || (mode == .denied && owner.kind == .organization)
        if deniedOwner {
            return reply(["data": ["viewer": viewer(), "organization": NSNull()],
                          "errors": [["type": "FORBIDDEN", "path": ["organization"], "message": "Resource protected by organization SAML enforcement."]]],
                         exitCode: 1)
        }
        if mode == .rateLimited {
            return reply(["errors": [["type": "RATE_LIMITED", "message": "API rate limit exceeded"]]], exitCode: 1)
        }
        return nil
    }

    func repositories(_ plan: ScopeRepositoryPagePlan, budget: CommandBudget) -> ScopeRepositoryPage {
        if mode == .ghMissing { return .failed(.ghMissing) }
        if let failure = pageFailure(plan.owner) { return ScopeBrowseParser.repositories(failure, plan: plan) }
        let rows = all(plan.owner, sort: plan.sort)
        let start = plan.cursor.flatMap { Int($0.dropFirst("cursor".count)) } ?? 0
        let slice = Array(rows.dropFirst(start).prefix(mode == .partial ? 40 : ScopeRepositoryPagePlan.pageSize))
        let end = start + slice.count
        let connection: [String: Any] = ["totalCount": rows.count, "nodes": slice,
                                         "pageInfo": ["hasNextPage": end < rows.count, "endCursor": "cursor\(end)"]]
        var data: [String: Any] = ["rateLimit": rateLimit]
        if plan.owner.kind == .organization {
            data["viewer"] = viewer(); data["organization"] = ["page": connection]
        } else {
            data["viewer"] = viewer(["page": connection])
        }
        var envelope: [String: Any] = ["data": data]
        if mode == .partial { envelope["errors"] = [["message": "Simulated partial page"]] }
        return ScopeBrowseParser.repositories(reply(envelope), plan: plan)
    }

    func search(_ plan: ScopeRepositorySearchPlan, budget: CommandBudget) -> ScopeRepositoryPage {
        if mode == .ghMissing { return .failed(.ghMissing) }
        if let failure = pageFailure(plan.owner) { return ScopeBrowseParser.search(failure, plan: plan) }
        let words = plan.term.lowercased().split(separator: " ")
        let matches = all(plan.owner, sort: .pushed).filter { row in
            let name = (row["nameWithOwner"] as! String).lowercased()
            return words.allSatisfy { name.split(separator: "/").last?.contains($0) ?? false }
        }
        let data: [String: Any] = ["viewer": viewer(), "rateLimit": rateLimit,
                                   "search": ["repositoryCount": matches.count, "nodes": Array(matches.prefix(ScopeRepositorySearchPlan.resultLimit))]]
        return ScopeBrowseParser.search(reply(["data": data]), plan: plan)
    }
}

extension ScopeAccessSimulation: ScopeBrowsing {
    func setBrowse(_ mode: ScopeBrowseFixture.Mode) { lock.lock(); browseMode = mode; lock.unlock() }
    private var fixture: ScopeBrowseFixture {
        lock.lock(); let mode = browseMode; lock.unlock()
        let current = account()
        return ScopeBrowseFixture(mode: mode, account: current, login: current == ScopeSimulation.accountA ? "demo-a_sim" : "demo-b_sim",
                                  now: Date())
    }
    func owners(_ plan: ScopeOwnersPlan, budget: CommandBudget) -> ScopeOwnersResult { fixture.owners(plan, budget: budget) }
    func repositories(_ plan: ScopeRepositoryPagePlan, budget: CommandBudget) -> ScopeRepositoryPage { fixture.repositories(plan, budget: budget) }
    func search(_ plan: ScopeRepositorySearchPlan, budget: CommandBudget) -> ScopeRepositoryPage { fixture.search(plan, budget: budget) }
}
