import Foundation
import GitHubPetCore

/// State behind the Choose Repositories sheet (#137). Selection lives in the editor's draft;
/// this object only holds what GitHub listed, per owner, for the life of one sheet. Pages load
/// lazily (an owner's first page when it is opened, the top organizations prefetched), each with
/// its own budget, and every reply is checked against the account and sheet epoch it started
/// under. Nothing here caps the selection.
@MainActor
final class ScopeBrowser: ObservableObject, Identifiable {
    /// `browse`: no owner chosen yet (opening, account checks, gh problems).
    enum Pane: Hashable { case selected, browse, owner(String) }
    enum OwnersPhase: Equatable {
        case idle, checkingAccount, loading, loaded
        case failed(ScopeBrowseFailure)
    }

    struct OwnerState: Equatable {
        var repositories: [ScopeBrowseRepository] = []
        /// Server search results not already in `repositories`, labelled "From search".
        var searchResults: [ScopeBrowseRepository] = []
        var searchedTerm: String?
        var searchTotal: Int?
        var searchFailure: ScopeBrowseFailure?
        var total: Int?
        var cursor: String?
        var completion: ScopeDiscoveryCompletion?
        var failure: ScopeBrowseFailure?
        var loading = false
        var searching = false
        /// GitHub's complete answer: every repository of this owner is in `repositories`.
        var complete: Bool { completion == .exhausted && failure == nil }
    }

    /// How an owner's detail pane is presented; exactly one of these, never an ambiguous blank.
    enum Presentation: Equatable {
        case loading, rows, capped, partial, rateLimited, denied, signedOut, ghMissing, empty, failed, notLoaded
    }

    @Published private(set) var owners: [ScopeBrowseOwner] = []
    @Published private(set) var ownersPhase = OwnersPhase.idle
    @Published private(set) var moreOrganizations = false
    /// The owners list arrived with an error (missing or malformed organizations, another GraphQL
    /// error): what loaded is shown, flagged as possibly incomplete. Never "no organizations".
    @Published private(set) var ownersWarning: ScopeBrowseFailure?
    @Published private(set) var states: [String: OwnerState] = [:]
    @Published var pane = Pane.browse
    @Published var searchText = ""
    /// Search scope bar: false = current owner only.
    @Published var searchAllOwners = true
    @Published var hideArchived = true
    @Published var hideForks = false
    @Published var sort = ScopeBrowseSort.pushed { didSet { if sort != oldValue { resort() } } }
    @Published private(set) var rateLimitReset: Date?
    /// Shown above the panes after the account changed mid-browse.
    @Published private(set) var notice: String?
    /// The new account's login while reloading after a change, when known.
    @Published private(set) var reloadingFor: String?

    let editor: ScopeEditor
    private let sourceFor: @MainActor (ScopeIdentity) -> any ScopeBrowsing
    private var source: any ScopeBrowsing
    let now: () -> Date
    /// Called when the sheet needs the account identified (Account not verified).
    private let identify: () -> Void
    var budget: () -> CommandBudget = { CommandBudget(timeout: CommandBudget.maximumSeconds) }
    var announce: (String) -> Void = ScopeEditor.postAnnouncement
    /// The demo identity browses offline fixtures under this stand-in account.
    static let demoAccount = ScopeSimulation.accountA

    private var account: ScopeAccount?
    private var loadedIdentity: ScopeIdentity??
    /// Bumped whenever loaded data is discarded; late replies compare it.
    private var epoch = 0
    private(set) var inFlight = 0

    /// `source` picks the transport per identity: Demo browses fixtures, never gh.
    init(editor: ScopeEditor, now: @escaping () -> Date, identify: @escaping () -> Void = {},
         source: @escaping @MainActor (ScopeIdentity) -> any ScopeBrowsing) {
        self.editor = editor; self.now = now; self.identify = identify; self.sourceFor = source
        self.source = source(.demo)
    }

    var isIdle: Bool { inFlight == 0 }
    var isDemo: Bool { editor.isDemo }

    // MARK: Lifecycle

    /// Sheet open and every identity change: load for the current account, discarding anything
    /// loaded for another one. Never mixes accounts.
    func sync() {
        let identity = editor.identity
        guard loadedIdentity != .some(identity) else { return }
        let hadData = loadedIdentity != nil && !owners.isEmpty
        epoch += 1
        owners = []; states = [:]; moreOrganizations = false; rateLimitReset = nil; ownersWarning = nil
        if case .owner = pane { pane = .browse }
        loadedIdentity = .some(identity)
        switch identity {
        case .none:
            account = nil
            ownersPhase = .checkingAccount
            identify()
            return
        case .demo: account = Self.demoAccount; source = sourceFor(.demo)
        case .github(let value): account = value; source = sourceFor(.github(value))
        }
        if hadData || notice != nil {
            reloadingFor = editor.accountDescription
            notice = "The GitHub CLI account changed. Reloading for \(editor.accountDescription)."
            say(notice!)
        }
        loadOwners()
    }

    /// After an account change: load again for whatever account is current now.
    func reload() {
        loadedIdentity = nil
        sync()
    }

    func loadOwners() {
        guard let account else { return }
        ownersPhase = .loading
        ownersWarning = nil
        let plan = ScopeOwnersPlan(expectedAccount: account), source = source, epoch = epoch
        run({ budget in source.owners(plan, budget: budget) }) { [weak self] result in
            self?.receiveOwners(result, epoch: epoch)
        }
    }

    private func receiveOwners(_ result: ScopeOwnersResult, epoch expected: Int) {
        guard expected == epoch else { return }
        if let reset = result.rateLimitReset { rateLimitReset = reset }
        if result.failure == .identityMismatch { accountChanged(); return }
        if result.viewer == nil, let failure = result.failure {
            ownersPhase = .failed(failure)
            if case .rateLimited(let reset?) = failure { rateLimitReset = reset }
            say(failure.message)
            return
        }
        owners = result.owners; moreOrganizations = result.moreOrganizations
        ownersWarning = result.failure
        reloadingFor = nil
        ownersPhase = .loaded
        if pane == .browse, let first = owners.first(where: { $0.kind == .viewer }) ?? organizations.first { open(first) }
        if let warning = result.failure {
            say("\(warning.message) Your organizations may be incomplete.")
        } else {
            say("Loaded \(organizations.count) \(organizations.count == 1 ? "organization" : "organizations").")
        }
        // Your own repositories plus the three largest readable organizations, ahead of a click.
        if let viewer = owners.first(where: { $0.kind == .viewer }) { loadPage(viewer) }
        organizations.filter { !$0.denied }.sorted { ($0.repositoryCount ?? 0) > ($1.repositoryCount ?? 0) }
            .prefix(3).forEach { loadPage($0) }
    }

    private func accountChanged() {
        epoch += 1
        owners = []; states = [:]
        if case .owner = pane { pane = .browse }
        reloadingFor = nil
        notice = "The GitHub CLI account changed. Loaded repositories were discarded."
        say(notice!)
        loadedIdentity = nil
        ownersPhase = .checkingAccount
        identify()
    }

    // MARK: Owners and pages

    var organizations: [ScopeBrowseOwner] { owners.filter { $0.kind == .organization } }
    func owner(_ id: String) -> ScopeBrowseOwner? { owners.first { $0.id == id } }
    var currentOwner: ScopeBrowseOwner? { if case .owner(let id) = pane { return owner(id) }; return nil }
    func state(_ owner: ScopeBrowseOwner) -> OwnerState { states[owner.id] ?? OwnerState() }

    func open(_ owner: ScopeBrowseOwner) {
        pane = .owner(owner.id)
        if states[owner.id] == nil { loadPage(owner) }
    }

    /// First page, or the next page after `cursor` (Load 100 More), or a retry after a failure.
    func loadPage(_ owner: ScopeBrowseOwner, more: Bool = false) {
        guard let account else { return }
        var state = states[owner.id] ?? OwnerState()
        guard !state.loading else { return }
        if case .rateLimited = state.failure, retryBlocked { return }
        if !more { state = OwnerState() }
        let cursor = more ? state.cursor : nil
        if more && cursor == nil { return }
        state.loading = true
        states[owner.id] = state
        let plan = ScopeRepositoryPagePlan(owner: owner, cursor: cursor, sort: sort, expectedAccount: account)
        let source = source, epoch = epoch
        run({ budget in source.repositories(plan, budget: budget) }) { [weak self] page in
            self?.receivePage(page, owner: owner, epoch: epoch)
        }
    }

    private func receivePage(_ page: ScopeRepositoryPage, owner: ScopeBrowseOwner, epoch expected: Int) {
        guard expected == epoch else { return }
        if page.failure == .identityMismatch { accountChanged(); return }
        if let reset = page.rateLimitReset { rateLimitReset = reset }
        var state = states[owner.id] ?? OwnerState()
        state.loading = false
        let known = Set(state.repositories.map(\.id))
        state.repositories += page.repositories.filter { !known.contains($0.id) }
        state.searchResults.removeAll { row in state.repositories.contains { $0.id == row.id } }
        state.total = page.totalCount ?? state.total
        state.cursor = page.nextCursor
        state.failure = page.failure
        if case .rateLimited(let reset?) = page.failure { rateLimitReset = reset }
        // A failed later page keeps what earlier pages loaded: that is partial, never empty.
        state.completion = page.failure != nil && !state.repositories.isEmpty ? .partial : page.completion
        states[owner.id] = state
        say(pageAnnouncement(owner, state))
    }

    private func pageAnnouncement(_ owner: ScopeBrowseOwner, _ state: OwnerState) -> String {
        let name = displayName(owner)
        switch presentation(owner) {
        case .rows, .capped:
            return "Loaded \(state.repositories.count) of \(state.total ?? state.repositories.count) repositories for \(name)."
        case .partial: return "Incomplete list for \(name): \(state.repositories.count) loaded, then GitHub stopped answering."
        case .empty: return "No repositories you can read in \(name). GitHub returned a complete answer."
        default: return state.failure?.message ?? "Loading \(name)."
        }
    }

    // MARK: Server search

    /// The term actually sent (after stripping qualifiers), or nil when nothing searchable is left.
    var sanitizedSearch: String? { ScopeSearchTerm.sanitize(searchText) }

    func canSearchServer(_ owner: ScopeBrowseOwner) -> Bool {
        owner.kind != .shared && !owner.denied && sanitizedSearch != nil && !state(owner).complete && account != nil
            && !state(owner).searching
    }

    func searchServer(_ owner: ScopeBrowseOwner) {
        guard canSearchServer(owner), let account,
              let plan = ScopeRepositorySearchPlan(owner: owner, typed: searchText, expectedAccount: account) else { return }
        if retryBlocked { say(ScopeBrowseFailure.rateLimited(resetAt: rateLimitReset).message); return }
        var state = self.state(owner)
        state.searching = true; state.searchFailure = nil
        states[owner.id] = state
        let source = source, epoch = epoch
        say("Searching GitHub for \(plan.term) in \(displayName(owner))…")
        run({ budget in source.search(plan, budget: budget) }) { [weak self] page in
            self?.receiveSearch(page, owner: owner, term: plan.term, epoch: epoch)
        }
    }

    private func receiveSearch(_ page: ScopeRepositoryPage, owner: ScopeBrowseOwner, term: String, epoch expected: Int) {
        guard expected == epoch else { return }
        if page.failure == .identityMismatch { accountChanged(); return }
        if let reset = page.rateLimitReset { rateLimitReset = reset }
        var state = states[owner.id] ?? OwnerState()
        state.searching = false
        state.searchedTerm = term
        state.searchFailure = page.failure
        if case .rateLimited(let reset?) = page.failure { rateLimitReset = reset }
        state.searchTotal = page.totalCount
        let known = Set(state.repositories.map(\.id) + state.searchResults.map(\.id))
        state.searchResults += page.repositories.filter { !known.contains($0.id) }
        states[owner.id] = state
        if let failure = page.failure { say(failure.message) }
        else { say("GitHub found \(page.totalCount ?? page.repositories.count) matching repositories in \(displayName(owner)).") }
    }

    // MARK: Presentation

    var retryBlocked: Bool { rateLimitReset.map { $0 > now() } ?? false && anyRateLimited }
    private var anyRateLimited: Bool {
        states.values.contains { if case .rateLimited = $0.failure { return true }; return false }
            || { if case .failed(.rateLimited) = ownersPhase { return true }; return false }()
    }

    func presentation(_ owner: ScopeBrowseOwner) -> Presentation {
        let state = state(owner)
        if state.loading && state.repositories.isEmpty { return .loading }
        switch state.failure {
        case .signedOut?: return .signedOut
        case .ghMissing?: return .ghMissing
        case .accessDenied?: return state.repositories.isEmpty ? .denied : .partial
        case .rateLimited?: return .rateLimited
        case .some: return state.repositories.isEmpty ? .failed : .partial
        case nil: break
        }
        if owner.denied && state.completion == nil { return .denied }
        switch state.completion {
        case nil: return .notLoaded
        case .exhausted?: return state.repositories.isEmpty ? .empty : .rows
        case .capped?: return .capped
        case .partial?: return .partial
        case .failed?: return .failed
        }
    }

    func displayName(_ owner: ScopeBrowseOwner) -> String {
        switch owner.kind {
        case .viewer: return "\(owner.login) (you)"
        case .shared: return "Shared with you"
        case .organization: return owner.login
        }
    }

    /// Loaded rows (plus search results) after the archive/fork filters and the typed text.
    func visibleRows(_ owner: ScopeBrowseOwner) -> (rows: [ScopeBrowseRepository], fromSearch: [ScopeBrowseRepository], hiddenArchived: Int, hiddenForks: Int) {
        let state = state(owner)
        let words = searchWords
        func keep(_ row: ScopeBrowseRepository) -> Bool {
            (words.map { words in words.allSatisfy(row.nameWithOwner.lowercased().contains) } ?? true)
                && !(hideArchived && row.isArchived) && !(hideForks && row.isFork)
        }
        let archived = hideArchived ? state.repositories.filter(\.isArchived).count : 0
        let forks = hideForks ? state.repositories.filter { $0.isFork && !(hideArchived && $0.isArchived) }.count : 0
        return (state.repositories.filter(keep), state.searchResults.filter(keep), archived, forks)
    }

    /// Typed words after stripping qualifiers; nil when nothing is typed. Typing only qualifiers
    /// (say `is:pr`) matches nothing rather than everything.
    var searchWords: [String]? {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return sanitizedSearch?.lowercased().split(separator: " ").map(String.init) ?? ["\u{0}"]
    }

    /// Owners whose loaded rows match the typed text, current owner first, for the All owners scope.
    var searchOwners: [ScopeBrowseOwner] {
        let ordered = (currentOwner.map { [$0] } ?? []) + owners.filter { $0.id != currentOwner?.id }
        return searchAllOwners ? ordered : Array(ordered.prefix(1))
    }

    func sidebarMatches(_ owner: ScopeBrowseOwner) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return displayName(owner).lowercased().contains(needle) || !visibleRows(owner).rows.isEmpty
            || !visibleRows(owner).fromSearch.isEmpty
    }

    // MARK: Selection (the editor's draft)

    func isSelected(_ row: ScopeBrowseRepository) -> Bool { row.target.map(editor.isSelected) ?? false }
    /// Checked and disabled: the organization's All repositories entry covers it.
    func isCovered(_ row: ScopeBrowseRepository) -> Bool {
        guard let target = row.target, let organization = try? MonitoringTarget(organization: target.owner) else { return false }
        return editor.isSelected(organization)
    }
    func allSelected(_ owner: ScopeBrowseOwner) -> Bool { owner.organizationTarget.map(editor.isSelected) ?? false }

    func toggle(_ row: ScopeBrowseRepository, _ on: Bool) {
        guard let target = row.target, !isCovered(row) else { return }
        editor.setSelected(target, display: row.nameWithOwner, on)
    }

    func toggleAll(_ owner: ScopeBrowseOwner, _ on: Bool) {
        guard let target = owner.organizationTarget else { return }
        editor.setAllRepositories(target, on)
    }

    /// Repositories of this owner picked one by one (for the sidebar badge and the nudge).
    func selectedRepositoryCount(_ owner: ScopeBrowseOwner) -> Int {
        let targets = editor.selectedTargets.filter { $0.kind == .repository }
        switch owner.kind {
        case .organization, .viewer: return targets.filter { $0.owner == owner.login.lowercased() }.count
        case .shared:
            let ids = Set(state(owner).repositories.compactMap(\.target))
            return targets.filter(ids.contains).count
        }
    }

    /// Three or more repositories of one organization: suggest All repositories, never switch.
    func showsNudge(_ owner: ScopeBrowseOwner) -> Bool {
        owner.kind == .organization && !allSelected(owner) && selectedRepositoryCount(owner) >= 3
    }

    // MARK: Plumbing

    private func resort() {
        epoch += 1
        states = [:]
        if let owner = currentOwner { loadPage(owner) }
    }

    private func say(_ message: String) { announce(message) }

    /// gh blocks its thread for up to the budget: run on a Dispatch queue, deliver on the main actor.
    private func run<T: Sendable>(_ work: @escaping @Sendable (CommandBudget) -> T, receive: @escaping @MainActor (T) -> Void) {
        let budget = budget()
        inFlight += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work(budget)
            Task { @MainActor [weak self] in
                self?.inFlight -= 1
                receive(value)
            }
        }
    }

    /// Offscreen renders only: an owner's first page shown as in flight, without a request.
    func showLoadingForSnapshot(_ owner: ScopeBrowseOwner) {
        var state = OwnerState(); state.loading = true
        states[owner.id] = state
        pane = .owner(owner.id)
    }

    /// Wait for offscreen renders and tests: every started request has delivered. Renders keep the
    /// default bound; tests pass nil and wait on the state alone, so runner load never decides a result.
    func settle(timeout: Duration? = .seconds(10)) async {
        let end = timeout.map { ContinuousClock.now.advanced(by: $0) }
        while inFlight > 0 && end.map({ ContinuousClock.now < $0 }) != false { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}
