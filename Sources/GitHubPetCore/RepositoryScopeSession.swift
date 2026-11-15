import Foundation

public struct ScopePollRequest: Equatable, Sendable {
    public let generation: Int
    public let serial: Int
    public let scope: MonitoringScope
    public let expectedAccount: ScopeAccount?
}

public enum ScopePollAction: Sendable {
    case discard
    case refetch
    case apply(FetchOutcome)
}

public struct ScopePollReception: Sendable {
    public let resetRepositories: Bool
    public let action: ScopePollAction
}

/// Main-actor-owned state machine; no network or engine side effects. Request-bound viewer
/// identity is resolved against persistence before any snapshot can reach the engine.
public final class RepositoryScopeSession {
    private let store: ScopeSelectionStore
    public private(set) var identity: ScopeIdentity?
    public private(set) var viewer: ScopeViewer?
    public private(set) var scope: MonitoringScope?
    public private(set) var configurationError = false
    public private(set) var issues: [ScopedFetchIssue] = []
    public private(set) var generation = 0
    private var serial = 0
    private var pending: ScopePollRequest?

    public init(store: ScopeSelectionStore) { self.store = store }

    public func invalidate() {
        generation += 1
        pending = nil
    }

    public func startLive() {
        invalidate()
        viewer = nil; identity = nil; scope = nil; issues = []; configurationError = false
        if let account = store.lastKnownAccount() {
            identity = .github(account)
            restore(.github(account))
        }
    }

    public func startDemo() {
        invalidate()
        viewer = nil; identity = .demo; issues = []
        restore(.demo)
    }

    private func restore(_ identity: ScopeIdentity) {
        switch store.load(for: identity) {
        case .scope(let saved): scope = saved; configurationError = false
        case .corruptConfiguration: scope = nil; configurationError = true
        }
    }

    public func beginPoll() -> ScopePollRequest? {
        guard identity != .demo, pending == nil else { return nil }
        serial += 1
        let account: ScopeAccount?
        if case .github(let current) = identity { account = current } else { account = nil }
        // A corrupt record may learn a switched account, but its bootstrap rows cannot apply.
        let request = ScopePollRequest(generation: generation, serial: serial,
                                       scope: scope ?? .everything, expectedAccount: account)
        pending = request
        return request
    }

    public func isCurrent(_ request: ScopePollRequest) -> Bool {
        request.generation == generation && pending == request
    }

    public func receive(_ result: ScopedPollResult, for request: ScopePollRequest) -> ScopePollReception {
        guard isCurrent(request) else { return .init(resetRepositories: false, action: .discard) }
        pending = nil
        issues = result.issues
        guard let responseViewer = result.viewer else {
            return .init(resetRepositories: false, action: .apply(result.outcome))
        }
        let responseIdentity = ScopeIdentity.github(responseViewer.account)
        let changed = identity != responseIdentity
        if changed {
            invalidate()
            identity = responseIdentity
            restore(responseIdentity)
        }
        viewer = responseViewer
        store.rememberAccount(responseViewer.account)
        if configurationError {
            return .init(resetRepositories: changed, action: .apply(configurationFailure))
        }
        guard let scope else { return .init(resetRepositories: changed, action: .apply(configurationFailure)) }
        // A mismatch response has no usable rows. Unknown Everything can apply only after
        // resolving a saved Everything; saved Selected always requires a bound refetch.
        if result.issues.contains(.identityMismatch) || request.scope != scope
            || (scope.mode == .selected && request.expectedAccount != responseViewer.account) {
            issues = []
            return .init(resetRepositories: true, action: .refetch)
        }
        return .init(resetRepositories: changed, action: .apply(result.outcome))
    }

    /// Called only after draft access validation (or explicit offline scenario validation).
    /// A late validation cannot persist or mutate a newer source/account/scope session.
    @discardableResult
    public func apply(_ scope: MonitoringScope, for expectedIdentity: ScopeIdentity, generation expected: Int) throws -> Bool {
        guard generation == expected, identity == expectedIdentity else { return false }
        try store.save(scope, for: expectedIdentity)
        invalidate()
        self.scope = scope; configurationError = false; issues = []
        return true
    }

    public func failCycle(_ issue: ScopedFetchIssue) -> FetchOutcome {
        pending = nil; issues = [issue]
        return .failure(.failed(issue == .deadline ? "Monitoring scope request budget exhausted" : "Monitoring scope could not be verified"))
    }

    /// Explicit configuration error: never empty, never Everything. Settings › Monitoring scope
    /// opens it as an empty Selected draft for correction.
    public var configurationFailure: FetchOutcome { .failure(.failed("Saved monitoring scope is invalid; monitoring is paused and has not broadened. Correct it in Settings › Monitoring scope")) }

    public var summary: String {
        if configurationError { return "Monitoring scope · configuration error" }
        guard let scope else { return "Monitoring scope · resolving account" }
        let prefix = identity == .demo ? "Demo scope" : "Monitoring scope"
        if scope.mode == .everything { return "\(prefix) · Everything" }
        let orgs = scope.targets.filter { $0.kind == .organization }.count
        func count(_ n: Int, _ noun: String, _ plural: String) -> String { "\(n) \(n == 1 ? noun : plural)" }
        return "\(prefix) · Selected · \(count(orgs, "organization", "organizations")), "
            + count(scope.targets.count - orgs, "repository", "repositories")
    }

    /// Intentionally contains no account/target names, query text or raw transport diagnostics.
    public var qualitySummary: String? {
        if configurationError { return "Saved selection needs correction in Settings › Monitoring scope; monitoring has not broadened." }
        guard !issues.isEmpty else { return nil }
        if issues.contains(.identityMismatch) { return "Account changed; restoring its monitoring scope." }
        if issues.contains(.signedOut) { return "Sign in with GitHub CLI to verify this scope." }
        if issues.contains(.ghMissing) { return "GitHub CLI is unavailable." }
        if issues.contains(.rateLimited) { return "GitHub rate limit; scope results are incomplete." }
        if issues.contains(.deadline) { return "Scope request time limit reached; results are unverified." }
        if issues.contains(.outputLimit) { return "Scope output limit reached; results are unverified." }
        if issues.contains(where: { if case .targetUnavailable = $0 { return true }; if case .malformedTarget = $0 { return true }; return false }) {
            return "A selected target could not be verified; results are incomplete."
        }
        if issues.contains(where: { if case .capped = $0 { return true }; return false }) { return "Scope result limit reached; counts are incomplete." }
        return "Monitoring scope could not be fully verified; retained rows may be incomplete."
    }
}
