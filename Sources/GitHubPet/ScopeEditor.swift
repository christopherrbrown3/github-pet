import AppKit
import GitHubPetCore

/// Settings draft controller for the monitoring scope. Edits stay in `draft` until Apply, which
/// validates every target's metadata for the expected viewer and then commits through
/// `AppModel.applyRepositoryScope` (generation-guarded; never the full data-source switch).
/// Every action is a plain method and `snapshot` mirrors what Settings shows, so a QA scenario
/// runner can drive exactly the paths a click does.
@MainActor
final class ScopeEditor: ObservableObject {
    enum Phase: Equatable { case idle, validating }
    enum Discovery: Equatable {
        case idle, loading
        case finished(ScopeDiscoveryResult)
    }

    @Published private(set) var draft = ScopeDraft(scope: .everything)
    @Published var organizationInput = "" { didSet { organizationInputProblem = nil } }
    @Published var repositoryInput = "" { didSet { repositoryInputProblem = nil } }
    @Published private(set) var organizationInputProblem: ScopeRowProblem?
    @Published private(set) var repositoryInputProblem: ScopeRowProblem?
    @Published private(set) var phase = Phase.idle
    /// Latest validation/Apply/discovery result, also announced to VoiceOver.
    @Published private(set) var status: String?
    @Published private(set) var discovery = Discovery.idle
    /// Validation/discovery replies rejected by the revision/identity/generation guards.
    @Published private(set) var discardedReplies = 0
    /// Every validation/discovery started vs. returned (applied or discarded): a handshake for
    /// tests and the QA runner, independent of timing.
    private(set) var launchedChecks = 0
    private(set) var receivedChecks = 0

    private weak var model: AppModel?
    private let access: any ScopeAccessChecking
    /// One shared 20 s / 2 MiB budget per validation or discovery run; tests inject a fixed clock.
    var budget: () -> CommandBudget = { CommandBudget(timeout: CommandBudget.maximumSeconds) }
    var announce: (String) -> Void = ScopeEditor.postAnnouncement

    private var baseIdentity: ScopeIdentity?
    private var baseGeneration = -1
    private var baseScope: MonitoringScope?
    private var committing = false
    /// Bumped on every draft edit, Cancel and identity/source change; late replies compare it.
    private var revision = 0
    private var validationTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    /// A cancelled origin never owns a later discovery, even if account/source round-trip.
    private var discoveryEpoch = 0

    init(model: AppModel, access: any ScopeAccessChecking) {
        self.model = model; self.access = access
    }

    // MARK: Derived state

    var identity: ScopeIdentity? { model?.monitoringScopeIdentity }
    var isDemo: Bool { identity == .demo }
    var activeScope: MonitoringScope? { model?.activeMonitoringScope }
    var configurationError: Bool { model?.monitoringScopeConfigurationError ?? false }
    var validationInFlight: Bool { validationTask != nil }
    var discoveryInFlight: Bool { discoveryTask != nil }

    var accountDescription: String {
        guard let model else { return "Unknown" }
        if isDemo { return "Demo (offline fixtures)" }
        if let login = model.monitoringScopeViewerLogin { return model.simulatesScope ? "\(login) (Simulated)" : login }
        return identity == nil ? "Not verified yet. Refresh the Inbox to identify the GitHub CLI account."
            : "Last known account (verifying)"
    }

    var hasChanges: Bool {
        if configurationError { return true }
        guard let active = activeScope else { return false }
        return draft.candidate != active || (draft.mode == .selected && draft.candidate == nil)
    }

    var applyBlockedReason: String? {
        if phase == .validating { return "Checking access…" }
        if identity == nil { return "Account not verified yet. Refresh the Inbox, then try again." }
        return draft.blockingMessage
    }

    var canApply: Bool { phase == .idle && identity != nil && hasChanges && draft.blockingMessage == nil }
    var canLoadSuggestions: Bool { !isDemo && discoveryTask == nil && { if case .github = identity { return true }; return false }() }

    func problem(_ row: ScopeDraftRow) -> ScopeRowProblem? { draft.problems[row.id] }

    // MARK: Active-state observation (called from AppModel.sync)

    func observeActive() {
        guard !committing, let model else { return }
        let identity = model.monitoringScopeIdentity, generation = model.monitoringScopeGeneration
        let scope = model.activeMonitoringScope
        guard identity != baseIdentity || generation != baseGeneration || scope != baseScope else { return }
        let identityChanged = identity != baseIdentity, wasDirty = baseGeneration >= 0 && hasChangesComparedTo(baseScope)
        let interruptedValidation = validationTask != nil
        baseIdentity = identity; baseGeneration = generation; baseScope = scope
        cancelValidation()
        if identityChanged {
            // Suggestions/validation belong to one account and source; a draft never moves across.
            cancelDiscovery(); discovery = .idle
            resetDraft()
            if wasDirty || interruptedValidation { report("Account or data source changed. The draft was discarded; nothing was applied.") }
        } else if !wasDirty {
            resetDraft()
        } else if interruptedValidation {
            report("Monitoring changed during the check. Nothing was applied; review and Apply again.")
        }
    }

    private func hasChangesComparedTo(_ scope: MonitoringScope?) -> Bool {
        guard let scope else { return draft.mode == .selected && !draft.rows.isEmpty }
        return draft.candidate != scope || (draft.mode == .selected && draft.candidate == nil)
    }

    private func resetDraft() {
        revision += 1
        draft = ScopeDraft(scope: activeScope)
        organizationInput = ""; repositoryInput = ""
        organizationInputProblem = nil; repositoryInputProblem = nil
    }

    // MARK: Draft actions

    private func edited() {
        revision += 1
        if validationTask != nil { cancelValidation(); report("Draft changed; the access check was cancelled.") }
    }

    func setMode(_ mode: MonitoringScope.Mode) {
        guard draft.mode != mode else { return }
        draft.mode = mode; edited()
    }

    func addOrganization() { add(.organization) }
    func addRepository() { add(.repository) }

    private func add(_ kind: MonitoringTarget.Kind) {
        let text = kind == .organization ? organizationInput : repositoryInput
        if let problem = draft.add(text, kind: kind) {
            if kind == .organization { organizationInputProblem = problem } else { repositoryInputProblem = problem }
            report(problem.message(for: kind))
            return
        }
        edited()
        if kind == .organization { organizationInput = "" } else { repositoryInput = "" }
        report(kind == .organization ? "Organization added to the draft." : "Repository added to the draft.")
    }

    /// Suggestions only fill the typed field: Add still validates, and Apply still checks access.
    func useSuggestion(_ value: String, kind: MonitoringTarget.Kind) {
        if kind == .organization { organizationInput = value; addOrganization() } else { repositoryInput = value; addRepository() }
    }

    func update(_ id: Int, text: String) {
        guard draft.rows.first(where: { $0.id == id })?.text != text else { return }
        draft.update(id, text: text); edited()
    }

    func remove(_ id: Int) {
        guard let row = draft.rows.first(where: { $0.id == id }) else { return }
        draft.remove(id); edited()
        report(row.kind == .organization ? "Organization removed from the draft." : "Repository removed from the draft.")
    }

    func cancel() {
        cancelValidation()
        resetDraft()
        report("Changes discarded. The active monitoring scope is unchanged.")
    }

    // MARK: Apply

    func apply() {
        guard let model, phase == .idle else { return }
        guard let identity = model.monitoringScopeIdentity else {
            report("Account not verified yet. Refresh the Inbox, then try again."); return
        }
        guard let scope = draft.candidate else { report(draft.blockingMessage ?? "Nothing to apply."); return }
        let generation = model.monitoringScopeGeneration
        // Everything has no target to verify; Demo validates offline only and never goes live.
        guard scope.mode == .selected, case .github(let account) = identity else {
            commit(scope, identity: identity, generation: generation); return
        }
        phase = .validating
        let expectedRevision = revision, access = access, budget = budget()
        report("Checking access to \(Self.counts(scope))…")
        launchedChecks += 1
        validationTask = Task { [weak self] in
            let outcome = await Self.offPool { access.validate(scope: scope, expectedAccount: account, budget: budget) }
            self?.receiveValidation(outcome, scope: scope, identity: identity, generation: generation, revision: expectedRevision)
        }
    }

    private func receiveValidation(_ outcome: ScopeAccessOutcome, scope: MonitoringScope, identity: ScopeIdentity,
                                   generation: Int, revision expected: Int) {
        receivedChecks += 1
        // Draft edits, Cancel, account/source changes and Apply elsewhere all invalidate the reply.
        guard validationTask != nil, revision == expected, let model,
              model.monitoringScopeIdentity == identity, model.monitoringScopeGeneration == generation else {
            discardedReplies += 1; return
        }
        validationTask = nil; phase = .idle
        switch outcome {
        case .verified(let viewer):
            guard ScopeIdentity.github(viewer.account) == identity else {
                report(ScopeAccessFailure.identityMismatch.message); return
            }
            draft.recordAccessProblems([:])
            commit(scope, identity: identity, generation: generation)
        case .rejected(_, let problems):
            draft.recordAccessProblems(problems)
            let count = problems.count
            report("\(count) \(count == 1 ? "entry" : "entries") could not be verified. Nothing was applied; the active scope is unchanged.")
        case .failed(let failure):
            report(failure.message)
        }
    }

    private func commit(_ scope: MonitoringScope, identity: ScopeIdentity, generation: Int) {
        guard let model else { return }
        committing = true
        let applied = model.applyRepositoryScope(scope, identity: identity, generation: generation)
        committing = false
        baseIdentity = model.monitoringScopeIdentity; baseGeneration = model.monitoringScopeGeneration
        baseScope = model.activeMonitoringScope
        if applied {
            resetDraft()
            report("Monitoring scope applied: \(Self.counts(scope))\(identity == .demo ? " (Demo)" : "").")
        } else {
            report("Monitoring changed before Apply finished. Nothing was applied; review and Apply again.")
        }
    }

    private func cancelValidation() {
        validationTask?.cancel(); validationTask = nil
        phase = .idle
    }

    // MARK: Discovery

    func loadSuggestions() {
        guard canLoadSuggestions, case .github(let account) = identity else { return }
        let access = access, budget = budget(), expectedIdentity = identity
        discoveryEpoch += 1
        let expectedEpoch = discoveryEpoch
        discovery = .loading
        report("Loading suggestions…")
        launchedChecks += 1
        discoveryTask = Task { [weak self] in
            let result = await Self.offPool { access.discover(expectedAccount: account, budget: budget) }
            self?.receiveDiscovery(result, identity: expectedIdentity, epoch: expectedEpoch)
        }
    }

    private func receiveDiscovery(_ result: ScopeDiscoveryResult, identity expected: ScopeIdentity?, epoch: Int) {
        // Draft edits don't invalidate hints; account/source changes do (they cancel the task).
        // Check the originating task and epoch before touching the current handle or UI state.
        guard !Task.isCancelled, discoveryEpoch == epoch, discoveryTask != nil, identity == expected else {
            receivedChecks += 1; discardedReplies += 1; return
        }
        receivedChecks += 1
        discoveryTask = nil
        discovery = .finished(result)
        report(Self.discoverySummary(result))
    }

    private func cancelDiscovery() {
        discoveryEpoch += 1
        discoveryTask?.cancel(); discoveryTask = nil
    }

    static func completionText(_ completion: ScopeDiscoveryCompletion, count: Int) -> String {
        switch completion {
        case .exhausted: return "\(count) found (end of this list)"
        case .capped: return "first \(count) shown (limit reached; more exist)"
        case .partial: return "\(count) found (incomplete)"
        case .failed: return "unavailable"
        }
    }

    static func discoverySummary(_ result: ScopeDiscoveryResult) -> String {
        if result.failure == .identityMismatch { return "Suggestions discarded: the GitHub CLI account changed. Typed entries can still be added." }
        var text = "Suggestions: organizations \(completionText(result.organizations.completion, count: result.organizations.suggestions.count)); repositories \(completionText(result.repositories.completion, count: result.repositories.suggestions.count))."
        if let failure = result.failure { text += " " + failure.message.replacingOccurrences(of: " Nothing was applied.", with: "") }
        return text + " Suggestions are hints, not every repository you can read; you can type any owner/name."
    }

    /// gh calls (and held simulated replies) block their thread for up to the 20 s budget. Run
    /// them on a Dispatch queue so they can never saturate Swift's cooperative pool; a reply
    /// that outlives Cancel or an account/source change is rejected by the guards above.
    nonisolated private static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Announcements

    private func report(_ message: String) {
        status = message
        announce(message)
    }

    static func counts(_ scope: MonitoringScope) -> String {
        guard scope.mode == .selected else { return "Everything" }
        let organizations = scope.targets.filter { $0.kind == .organization }.count
        let repositories = scope.targets.count - organizations
        return "Selected · \(organizations) \(organizations == 1 ? "organization" : "organizations"), \(repositories) \(repositories == 1 ? "repository" : "repositories")"
    }

    nonisolated static func postAnnouncement(_ message: String) {
        DispatchQueue.main.async {
            guard let app = NSApp else { return }
            NSAccessibility.post(element: app, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    // MARK: Scenario/QA snapshot

    /// What the Settings section shows. Names appear here only because Settings is explicit.
    struct Snapshot: Equatable, Codable {
        var account: String
        var activeSummary: String
        var mode: String
        var organizations: [Row]
        var repositories: [Row]
        var organizationInput: String
        var organizationInputError: String?
        var repositoryInput: String
        var repositoryInputError: String?
        var applyEnabled: Bool
        var applyBlockedReason: String?
        var validating: Bool
        var status: String?
        var discovery: String
        var discardedReplies: Int
        var organizationSuggestions: [String]
        var repositorySuggestions: [String]
        struct Row: Equatable, Codable { var text: String; var error: String? }
    }

    var discoveryText: String {
        switch discovery {
        case .idle: return isDemo ? "Suggestions need the GitHub CLI source." : "Suggestions not loaded."
        case .loading: return "Loading suggestions…"
        case .finished(let result): return Self.discoverySummary(result)
        }
    }

    var suggestions: (organizations: [String], repositories: [String]) {
        guard case .finished(let result) = discovery else { return ([], []) }
        return (result.organizations.suggestions, result.repositories.suggestions)
    }

    var snapshot: Snapshot {
        func rows(_ kind: MonitoringTarget.Kind) -> [Snapshot.Row] {
            draft.rows(kind).map { Snapshot.Row(text: $0.text, error: problem($0)?.message(for: kind)) }
        }
        return Snapshot(account: accountDescription, activeSummary: model?.scopeSummary ?? "",
                        mode: draft.mode.rawValue, organizations: rows(.organization), repositories: rows(.repository),
                        organizationInput: organizationInput,
                        organizationInputError: organizationInputProblem?.message(for: .organization),
                        repositoryInput: repositoryInput,
                        repositoryInputError: repositoryInputProblem?.message(for: .repository),
                        applyEnabled: canApply, applyBlockedReason: applyBlockedReason, validating: phase == .validating,
                        status: status, discovery: discoveryText, discardedReplies: discardedReplies,
                        organizationSuggestions: suggestions.organizations, repositorySuggestions: suggestions.repositories)
    }
}
