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
    private var currentAccount = accountA
    private var sequence: [ScopeAccount: Int] = [:]
    private var partial = false
    /// #35 fixtures, per review search: `hidden` adds 3 matches the viewer can't see, `hiddenOnly`
    /// returns no nodes with 3 hidden matches, `capped` reports more matches plus hasNextPage.
    enum Visibility: String, CaseIterable { case complete, hidden, hiddenOnly = "hidden-only", capped }
    private var visibility = Visibility.complete
    private var holdNext = 0
    private var entered = 0, finished = 0
    private var held: [DispatchSemaphore] = []
    private var heldWaiters: [(count: Int, resume: CheckedContinuation<Void, Never>)] = []
    /// Real-time bound on a held reply. nil (unit fixtures only) leaves it bounded by the
    /// budget and explicit release/teardown, so passing never depends on runner speed.
    private let holdLimit: Duration?
    init(holdLimit: Duration? = .seconds(20)) { self.holdLimit = holdLimit }
    struct Request: Equatable {
        let scope: MonitoringScope; let expected: ScopeAccount?
        var identityOnly = false
        /// The search aliases this request asked GitHub for (none for identity-only).
        var searchAliases: [String] = []
    }
    private var history: [Request] = []
    private var calls = 0
    var requestHistory: [Request] { lock.lock(); defer { lock.unlock() }; return history }

    func switchAccount(_ account: ScopeAccount) { lock.lock(); currentAccount = account; lock.unlock() }
    func inject() { lock.lock(); sequence[currentAccount] = min(31, sequence[currentAccount, default: 0] + 1); lock.unlock() }
    func setPartial(_ on: Bool) { lock.lock(); partial = on; lock.unlock() }
    func setVisibility(_ mode: Visibility) { lock.lock(); visibility = mode; lock.unlock() }
    var currentVisibility: Visibility { lock.lock(); defer { lock.unlock() }; return visibility }
    func holdNextReply(_ count: Int = 1) { lock.lock(); holdNext += max(0, count); lock.unlock() }
    func releaseReplies() {
        lock.lock(); let replies = held; held = []; lock.unlock()
        for reply in replies { reply.signal() }
    }
    /// Releases one held reply in arrival order (oldest) or reverse order (newest).
    @discardableResult
    func releaseReply(newest: Bool) -> Bool {
        lock.lock(); let reply = held.isEmpty ? nil : newest ? held.removeLast() : held.removeFirst(); lock.unlock()
        reply?.signal()
        return reply != nil
    }
    var account: ScopeAccount { lock.lock(); defer { lock.unlock() }; return currentAccount }
    /// Every fetch that entered has returned or is held: (entered, returned, held).
    var progress: (entered: Int, finished: Int, held: Int) {
        lock.lock(); defer { lock.unlock() }; return (entered, finished, held.count)
    }
    /// Explicit handshake: resumes once `count` replies are held, however slowly the fetch is scheduled.
    func waitUntilHeld(_ count: Int) async {
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard held.count < count else { lock.unlock(); resume.resume(); return }
            heldWaiters.append((count, resume)); lock.unlock()
        }
    }
    var status: String {
        lock.lock(); defer { lock.unlock() }
        let last = history.last.map { " · requested \($0.identityOnly ? "identity only" : $0.scope.mode == .selected ? "Selected" : "Everything") · expected \($0.expected == nil ? "unknown" : $0.expected == Self.accountA ? "A" : "B")" } ?? ""
        return "Simulated account \(currentAccount == Self.accountA ? "A" : "B") · \(calls) requests · \(held.count) held · \(partial ? "partial" : "complete") replies" + last
    }
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    static func seed(_ defaults: UserDefaults) throws {
        let store = ScopeSelectionStore(defaults: defaults)
        try store.save(selectedA, for: .github(accountA))
        try store.save(selectedB, for: .github(accountB))
        store.rememberAccount(accountA)
    }
    static func corruptA(_ defaults: UserDefaults) { corrupt(defaults, account: accountA) }
    static func corrupt(_ defaults: UserDefaults, account: ScopeAccount) {
        // Deliberately malformed fixture record, only in the launch's throwaway domain.
        defaults.set(Data(#"{"mode":"selected","targets":[]}"#.utf8),
                     forKey: "GitHubPet.monitoring-scope.v1.github.com." + account.viewerID)
    }

    func fetch(scope: MonitoringScope, expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        respond(scope: scope, expectedAccount: expectedAccount, identityOnly: false, budget: budget)
    }
    func fetchIdentity(expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        respond(scope: .everything, expectedAccount: expectedAccount, identityOnly: true, budget: budget)
    }
    private func respond(scope: MonitoringScope, expectedAccount: ScopeAccount?, identityOnly: Bool,
                         budget: CommandBudget) -> ScopedPollResult {
        lock.lock(); entered += 1; lock.unlock()
        defer { lock.lock(); finished += 1; lock.unlock() }
        do { try budget.check() }
        catch CommandError.timedOut { return .failure(.deadline) }
        catch CommandError.outputLimitExceeded { return .failure(.outputLimit) }
        catch { return .failure(.cancelled) }
        lock.lock()
        let account = currentAccount, count = sequence[account, default: 0], partial = self.partial, visibility = self.visibility
        let gate = holdNext > 0 ? DispatchSemaphore(value: 0) : nil
        var ready: [CheckedContinuation<Void, Never>] = []
        if let gate {
            held.append(gate)
            ready = heldWaiters.filter { $0.count <= held.count }.map(\.resume)
            heldWaiters.removeAll { $0.count <= held.count }
        }
        holdNext = max(0, holdNext - 1); calls += 1
        let plan = identityOnly ? ScopeQueryPlan(identityFor: expectedAccount)
            : try? ScopeQueryPlan(scope: scope, expectedAccount: expectedAccount)
        history.append(Request(scope: scope, expected: expectedAccount, identityOnly: identityOnly,
                               searchAliases: plan?.searches.map(\.alias) ?? []))
        if history.count > 32 { history.removeFirst(history.count - 32) }
        lock.unlock()
        for waiter in ready { waiter.resume() }
        guard let plan else { return .failure(.identityRequired) }
        var body: [String: Any] = ["viewer": ["id": account.viewerID, "login": account == Self.accountA ? "demo-a_sim" : "demo-b_sim"]]
        for (index, target) in plan.scope.targets.enumerated() {
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
            var total = nodes.count, more = false
            if search.kind == .reviewRequest {
                switch visibility {
                case .complete: break
                case .hidden: total += 3
                case .hiddenOnly: nodes = []; total = 3
                case .capped: total += 15; more = true
                }
            }
            body[search.alias] = ["issueCount": total, "nodes": nodes, "pageInfo": ["hasNextPage": more]]
        }
        var envelope: [String: Any] = ["data": body]
        if partial { envelope["errors"] = [] }
        guard let bytes = try? JSONSerialization.data(withJSONObject: envelope), budget.reserve(bytes.count) else { return .failure(.outputLimit) }
        if let gate {
            // Independently real-time bounded even with a frozen unit-fixture budget clock.
            let holdDeadline = holdLimit.map { ContinuousClock.now.advanced(by: $0) }
            // Bounded, deterministic late-reply seam; no sleeps, child process or network.
            while gate.wait(timeout: .now() + 0.05) == .timedOut {
                if budget.remaining <= 0 || holdDeadline.map({ ContinuousClock.now >= $0 }) == true {
                    // A reply that times out on its own is no longer held.
                    lock.lock(); held.removeAll { $0 === gate }; lock.unlock()
                    return .failure(.deadline)
                }
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
        }, issues: parsed.issues, successfulSources: parsed.successfulSources, hidden: parsed.hidden)
    }
}
