import Foundation
import GitHubPetCore

/// Constructed only by --simulate-monitoring-scope. Never locates gh or opens a network.
/// Captured, held replies deliberately ignore cancellation to exercise generation guards.
final class ScopeSimulation: ScopedPolling, @unchecked Sendable {
    static let accountA = try! ScopeAccount(viewerID: "U_scope_demo_A")
    static let accountB = try! ScopeAccount(viewerID: "U_scope_demo_B")
    static let selectedA = try! MonitoringScope(selected: [MonitoringTarget(organization: "demo-a")])
    static let selectedB = try! MonitoringScope(selected: [MonitoringTarget(repository: "demo-b/pet")])
    private let lock = NSLock()
    private var account = accountA
    private var sequence: [ScopeAccount: Int] = [:]
    private var partial = false
    private var holdNext = false
    private var held: [DispatchSemaphore] = []
    struct Request: Equatable { let scope: MonitoringScope; let expected: ScopeAccount? }
    private var history: [Request] = []
    private var calls = 0
    var requestHistory: [Request] { lock.lock(); defer { lock.unlock() }; return history }

    func switchAccount(_ account: ScopeAccount) { lock.lock(); self.account = account; lock.unlock() }
    func inject() { lock.lock(); sequence[account] = min(31, sequence[account, default: 0] + 1); lock.unlock() }
    func setPartial(_ on: Bool) { lock.lock(); partial = on; lock.unlock() }
    func holdNextReply() { lock.lock(); holdNext = true; lock.unlock() }
    func releaseReplies() {
        lock.lock(); let replies = held; held = []; lock.unlock()
        for reply in replies { reply.signal() }
    }
    var status: String {
        lock.lock(); defer { lock.unlock() }
        let last = history.last.map { " · requested \($0.scope.mode == .selected ? "Selected" : "Everything") · expected \($0.expected == nil ? "unknown" : $0.expected == Self.accountA ? "A" : "B")" } ?? ""
        return "Simulated account \(account == Self.accountA ? "A" : "B") · \(calls) requests · \(held.count) held · \(partial ? "partial" : "complete") replies" + last
    }
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    static func seed(_ defaults: UserDefaults) throws {
        let store = ScopeSelectionStore(defaults: defaults)
        try store.save(selectedA, for: .github(accountA))
        try store.save(selectedB, for: .github(accountB))
        store.rememberAccount(accountA)
    }
    static func corruptA(_ defaults: UserDefaults) {
        // Deliberately malformed fixture record, only in the launch's throwaway domain.
        defaults.set(Data(#"{"mode":"selected","targets":[]}"#.utf8),
                     forKey: "GitHubPet.monitoring-scope.v1.github.com." + accountA.viewerID)
    }

    func fetch(scope: MonitoringScope, expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        do { try budget.check() }
        catch CommandError.timedOut { return .failure(.deadline) }
        catch CommandError.outputLimitExceeded { return .failure(.outputLimit) }
        catch { return .failure(.cancelled) }
        lock.lock()
        let account = self.account, count = sequence[account, default: 0], partial = self.partial
        let gate = holdNext ? DispatchSemaphore(value: 0) : nil
        if let gate { held.append(gate) }
        holdNext = false; calls += 1
        history.append(Request(scope: scope, expected: expectedAccount))
        if history.count > 32 { history.removeFirst(history.count - 32) }
        lock.unlock()
        guard let plan = try? ScopeQueryPlan(scope: scope, expectedAccount: expectedAccount) else { return .failure(.identityRequired) }
        var body: [String: Any] = ["viewer": ["id": account.viewerID, "login": account == Self.accountA ? "demo-a_sim" : "demo-b_sim"]]
        for (index, target) in scope.targets.enumerated() {
            if target.kind == .organization {
                body["target\(index)"] = ["__typename": "Organization", "id": "O_demo_\(index)", "login": target.owner]
            } else {
                body["target\(index)"] = ["__typename": "Repository", "id": "R_demo_\(index)", "nameWithOwner": "\(target.owner)/\(target.name!)"]
            }
        }
        let owner = account == Self.accountA ? "demo-a" : "demo-b"
        for search in plan.searches {
            var nodes: [[String: Any]] = []
            if search.kind == .reviewRequest {
                for index in Array(0...count) + [1000] {
                    let repo = index == 1000 ? "demo-outside/pet" : index == 0 ? "\(owner)/pet" : "\(owner)/new-pet"
                    if let target = search.targetIndex, !scope.targets[target].includes(repo) { continue }
                    nodes.append(["__typename": "PullRequest", "id": "PR_\(account.viewerID)_\(index)", "number": index + 1,
                                  "title": "Simulated review \(index)", "url": "https://github.com/\(repo)/pull/\(index + 1)",
                                  "updatedAt": "2026-11-15T12:00:00Z", "repository": ["nameWithOwner": repo]])
                }
            }
            body[search.alias] = ["issueCount": nodes.count, "nodes": nodes, "pageInfo": ["hasNextPage": false]]
        }
        var envelope: [String: Any] = ["data": body]
        if partial { envelope["errors"] = [] }
        guard let bytes = try? JSONSerialization.data(withJSONObject: envelope), budget.reserve(bytes.count) else { return .failure(.outputLimit) }
        if let gate {
            // Independently real-time bounded even with a frozen unit-fixture budget clock.
            let holdDeadline = ContinuousClock.now.advanced(by: .seconds(20))
            // Bounded, deterministic late-reply seam; no sleeps, child process or network.
            while gate.wait(timeout: .now() + 0.05) == .timedOut {
                if budget.remaining <= 0 || ContinuousClock.now >= holdDeadline { return .failure(.deadline) }
            }
            if budget.remaining <= 0 { return .failure(.deadline) }
        } else {
            do { try budget.check() }
            catch CommandError.timedOut { return .failure(.deadline) }
            catch CommandError.outputLimitExceeded { return .failure(.outputLimit) }
            catch { return .failure(.cancelled) }
        }
        let parsed = ScopedResponseParser.parse(bytes, plan: plan)
        return ScopedPollResult(viewer: parsed.viewer, items: parsed.items.map {
            var item = $0; item.isDemo = true; return item
        }, issues: parsed.issues, successfulSources: parsed.successfulSources)
    }
}
