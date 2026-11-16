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

    private let lock = NSLock()
    private let account: @Sendable () -> ScopeAccount
    private var discoveryMode = DiscoveryMode.complete
    private var validationMode = ValidationMode.normal
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
