import AppKit
import Combine
import GitHubPetCore

/// Shared state behind the menu-bar inbox, the Inbox window, Settings and the mascot.
@MainActor
final class AppModel: ObservableObject {
    /// App-domain time and system motion are runtime inputs, not source state. Tests supply
    /// controlled inputs without touching the user's clock or accessibility preferences.
    struct Runtime {
        var now: () -> Date = Date.init
        var systemReducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        var schedulesTimers = true
        var repositoryBudget: () -> CommandBudget = { CommandBudget(timeout: 20) }
        /// --simulate-monitoring-scope only; unit fixtures pass nil to drop the real-time hold bound.
        var scopeSimulationHoldLimit: Duration? = .seconds(20)
        /// Source of system wake notifications; tests post to a private centre.
        var wakeCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
        /// Wakes within this delay collapse into one refresh, which also gives the network time to return.
        var wakeRefreshDelay: Duration = .seconds(5)
        /// Open at login (#15). nil: the system's SMAppService for a normal launch only, none for
        /// simulated, snapshot, QA or custom-defaults launches. Tests inject a fake.
        var loginItemBackend: (any LoginItemBackend)?
        /// #10 Actions failures. nil: the real gh client for live launches and none for simulated
        /// ones; tests inject a fake (which a simulated launch then uses too).
        var actionsClient: (any ActionsPolling)?
        /// #10 deployment approvals, the same way: real gh client for live launches only.
        var deploymentsClient: (any DeploymentPolling)?
        /// Its own 20 s / 2 MiB budget, separate from the inbox searches; it starts when the
        /// Actions query starts, so slow searches never shorten it.
        var actionsBudget: @Sendable () -> CommandBudget = { CommandBudget(timeout: 20) }
        var mascotPackDirectory: (MascotSkin) -> URL? = { LaunchOptions.builtInPackDirectory(for: $0) }
    }
    private let runtime: Runtime
    @Published private(set) var items: [InboxItem] = []
    @Published private(set) var dismissedInboxRows: [DismissedInboxRow] = []
    @Published private(set) var inboxDismissalContext: InboxDismissalContext?
    @Published private(set) var inboxDismissalNotice: String?
    @Published private(set) var allCurrentInboxItemsDismissed = false
    @Published private(set) var dataState: DataState = .loading
    @Published private(set) var scopeSummary = "Monitoring scope · resolving account"
    @Published private(set) var scopeQuality: String?
    @Published private(set) var scopeSimulationStatus = ""
    @Published private(set) var discardedScopeReplies = 0
    @Published private(set) var receivedScopeReplies = 0
    @Published private(set) var lastSuccess: Date?
    /// Matches GitHub counted but the viewer can't see, from the last complete snapshot (#35).
    @Published private(set) var hiddenResultCount = 0
    /// #10: why workflow failures aren't fully known right now (their own line; never the inbox's).
    @Published private(set) var actionsQuality: String?
    /// #10: deployments in watched repositories waiting for other reviewers or a wait timer. A count, never rows.
    @Published private(set) var deploymentsWaitingCount = 0
    var deploymentsWaitingNote: String? {
        DeploymentApprovals.waitingNote(deploymentsWaitingCount, complete: actionsQuality == nil)
    }
    @Published private(set) var unseen = UnseenItems()
    /// "Show details" in the Inbox: names and titles for this app session only, never saved.
    /// Hover, mascot and menu-bar text stay generic while privacy mode is on.
    @Published var detailsRevealed = false
    @Published private(set) var activeClip: EventClipQueue.Clip?
    @Published private(set) var blockedLinkNote: String?
    @Published private(set) var now = Date()
    @Published private(set) var serviceState: ServiceStatusState = .loading
    @Published private(set) var serviceIncidents: [ServiceIncident] = []
    @Published private(set) var serviceLastSuccess: Date?
    /// Incident IDs announced as new and not yet seen (separate from inbox markers, which are
    /// pruned against inbox snapshots).
    @Published private(set) var unseenIncidents: Set<String> = []
    /// The incident marker's ~6 s burst (#37): set by an incident event that may animate, cleared
    /// when snooze, quiet hours or Reduce Motion stop gestures.
    @Published private(set) var markerBurst: IncidentMarker.Burst?
    @Published var settings: PetSettings {
        didSet {
            guard settings != oldValue else { return }
            let assignmentChanged = settings.assignmentMode != oldValue.assignmentMode
            if assignmentChanged && settings.dataSource == oldValue.dataSource {
                prepareAssignmentModeChange(from: oldValue.assignmentMode)
            }
            store.save(settings)
            if settings.mascotSkin != oldValue.mascotSkin && !mascotArtwork.locksPicker {
                let next = mascotArtworkLoader.resolve(settings.mascotSkin)
                if next.source != mascotArtwork.source { layouts.removeAll() }
                mascotArtwork = next
            }
            if settings.dataSource != oldValue.dataSource { switchSource() }
            else if assignmentChanged { switchAssignmentMode() }
            if settings.privacyMode && !oldValue.privacyMode { detailsRevealed = false }
            // Reclassify rows now; IDs don't change, so nothing looks new (#8).
            if settings.entitlementRepositories != oldValue.entitlementRepositories { sync(now: clock()) }
            if !assignmentChanged && settings.dataSource == oldValue.dataSource
                && (settings.watchWorkflowFailures != oldValue.watchWorkflowFailures
                    || settings.watchDeploymentApprovals != oldValue.watchDeploymentApprovals) { requestRefresh() }
            // Snooze, quiet hours or Reduce Motion turned on: stop a playing gesture now, not at
            // the next tick. Nothing is re-queued, so turning them off later replays nothing.
            if GestureCancellation.shouldCancel(from: oldValue, to: settings, at: clock()) { cancelGesture() }
        }
    }

    @Published private(set) var mascotArtwork: MascotArtwork
    var pack: MascotPack? { mascotArtwork.pack }
    private var mascotArtworkLoader: MascotArtworkLoader

    private let store: SettingsStore
    let clockOffset: TimeInterval
    private let pollsPeriodically: Bool
    /// Software updates (#90): its own state, never part of the inbox, its badge or the mascot.
    let updates: UpdateModel
    /// Only a normal launch may reach GitHub for update checks; QA, snapshot and simulated launches use fixtures.
    let checksUpdatesLive: Bool
    // Snapshot-only CLI transport (#52): selecting the real CLI UI must never launch gh.
    private let snapshotMode: Bool
    private var snapshotCLIFailure: FetchFailure = .ghMissing
    private let engine = InboxEngine()
    private var dismissals: InboxDismissalState
    /// #10: workflow failures have their own engine and baseline, so an unreadable watched
    /// repository never stops the inbox from announcing, and a coverage change seeds silently.
    private let actionsEngine = InboxEngine()
    private var actionsCoverageKey: String?
    /// Seen-item digests and source quality across relaunches (#12), in the launch's own domain.
    private let baselineStore: EventBaselineStore
    /// The source/account/scope session the engine's baseline belongs to; nil until the first apply.
    private var baselineKey: BaselineKey?
    private let simulator = FixtureSimulator()
    private let scopedClient: any ScopedPolling
    private let scopeStore: ScopeSelectionStore
    private let scopeSession: RepositoryScopeSession
    private let scopeSimulation: ScopeSimulation?
    /// Settings draft validation/discovery: gh normally, offline only in the simulated launch.
    private let scopeAccess: any ScopeAccessChecking
    let scopeAccessSimulation: ScopeAccessSimulation?
    /// Settings › Open at login (#15).
    let loginItem: LoginItemSettings
    /// Settings › Monitoring scope draft controller (PR B).
    lazy var scopeEditor = ScopeEditor(model: self, access: scopeAccess)
    private let scopeDefaults: UserDefaults
    private let simulationDefaultsSuite: String?
    private var repositoryTask: Task<Void, Never>? {
        didSet { if refreshing != (repositoryTask != nil) { refreshing = repositoryTask != nil } }
    }
    /// A repository poll is in flight: the Refresh control says so (#60).
    @Published private(set) var refreshing = false
    /// A Refresh requested during an in-flight poll, for the scope generation it was asked in.
    /// At most one; it runs once after the current reply lands, and is dropped if the source,
    /// account or scope changed meanwhile (that change already started its own poll).
    private var queuedRefreshGeneration: Int?
    private var wakeObserver: SystemNotificationObserver?
    private var wakeTask: Task<Void, Never>?
    private var replyWaiters: [(count: Int, resume: CheckedContinuation<Void, Never>)] = []
    /// Simulation only: every launched repository request (scope, expected account, generation).
    private(set) var simulatedPollLog: [ScopePollRequest] = []
    private var launchedScopePolls = 0
    private var clips = EventClipQueue()
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    // GitHub Status (#11): fixtures by default; githubstatus.com only with the live source.
    private let serviceMonitor = ServiceStatusMonitor()
    private let serviceSimulator = ServiceStatusSimulator()
    private let serviceClient: ServiceStatusClient
    private var serviceGenerations = SourceGenerations()

    init(options supplied: LaunchOptions, runtime: Runtime = Runtime()) {
        self.runtime = runtime
        var options = supplied
        // Defense at construction too: programmatic test callers cannot enable simulation
        // while retaining the real defaults domain or selecting a live transport.
        if options.simulatesMonitoringScope {
            options.forcedSource = "gh"; options.resetSettings = true; options.userDefaultsOverride = nil
        }
        if options.simulatesMonitoringScope && options.defaultsSuite?.hasPrefix("dev.github-pet.scope-simulation.") != true {
            options.defaultsSuite = "dev.github-pet.scope-simulation.\(UUID().uuidString)"
        }
        let normalLaunch = !options.simulatesMonitoringScope && options.snapshotDirectory == nil
            && options.qaScenario == nil && options.defaultsSuite == nil
        loginItem = LoginItemSettings(backend: runtime.loginItemBackend ?? (normalLaunch ? SystemLoginItemBackend() : nil))
        store = SettingsStore(defaults: options.userDefaults)
        dismissals = InboxDismissalState(defaults: options.userDefaults)
        baselineStore = EventBaselineStore(defaults: options.userDefaults)
        simulationDefaultsSuite = options.simulatesMonitoringScope ? options.defaultsSuite : nil
        scopeDefaults = options.userDefaults
        scopeStore = ScopeSelectionStore(defaults: options.userDefaults)
        scopeSession = RepositoryScopeSession(store: scopeStore)
        if options.simulatesMonitoringScope {
            try? ScopeSimulation.seed(options.userDefaults)
            let simulation = ScopeSimulation(holdLimit: runtime.scopeSimulationHoldLimit)
            scopeSimulation = simulation
            scopedClient = simulation
            let access = ScopeAccessSimulation(holdLimit: runtime.scopeSimulationHoldLimit) { simulation.account }
            scopeAccessSimulation = access
            scopeAccess = access
        } else {
            scopeSimulation = nil
            scopedClient = ScopedGhClient()
            scopeAccessSimulation = nil
            scopeAccess = ScopeGhAccess()
        }
        clockOffset = options.clockOffset
        checksUpdatesLive = normalLaunch
        updates = normalLaunch
            ? UpdateModel(installed: InstalledBuild(infoDictionary: Bundle.main.infoDictionary),
                          defaults: options.userDefaults, checker: UpdateChecker())
            : UpdateModel(installed: UpdateFixture.installedBuild, defaults: options.userDefaults,
                          checker: UpdateModel.fixtureChecker(.offline), now: runtime.now, opener: { _ in })
        // The snapshot scenario drives every refresh itself; a periodic poll firing mid-scenario
        // would refresh a step it just made stale (flaky render-check).
        pollsPeriodically = options.snapshotDirectory == nil && !options.simulatesMonitoringScope
        snapshotMode = options.snapshotDirectory != nil && !options.simulatesMonitoringScope
        if options.resetSettings { store.reset(); baselineStore.reset() }
        var loaded = store.load()
        switch options.forcedSource {
        case "fixtures": loaded.dataSource = .fixtures
        case "gh": loaded.dataSource = .githubCLI
        default: break
        }
        settings = loaded
        // Snapshot evidence must be deterministic and never contain live data: with the live
        // source selected there, GitHub Status fails at once instead of reaching the network.
        serviceClient = options.snapshotDirectory == nil && !options.simulatesMonitoringScope
            ? ServiceStatusClient() : ServiceStatusClient(transport: OfflineStatusTransport())

        var artworkLoader = MascotArtworkLoader(options: options, builtInDirectory: runtime.mascotPackDirectory)
        mascotArtwork = artworkLoader.resolve(loaded.mascotSkin)
        mascotArtworkLoader = artworkLoader
        // One launch line on stderr so QA can confirm which mascot is in use.
        FileHandle.standardError.write(Data("GitHubPet: \(mascotArtwork.logDescription)\n".utf8))

        if runtime.schedulesTimers {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        reduceMotionObserver = SystemNotificationObserver(
            center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        ) { [weak self] in
            Task { @MainActor in
                if self?.runtime.systemReducedMotion() == true { self?.cancelGesture() }
            }
        }
        // Wake refresh is for normal launches only: snapshot and simulated launches drive every
        // poll themselves.
        if pollsPeriodically {
            wakeObserver = SystemNotificationObserver(center: runtime.wakeCenter,
                                                      name: NSWorkspace.didWakeNotification) { [weak self] in
                Task { @MainActor in self?.handleWake() }
            }
        }
        switchSource()
        if let delay = options.injectEventAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.injectEntitlementEvent() }
        }
    }

    // MARK: Derived state

    /// App clock: wall clock plus the QA offset from launch options.
    func clock() -> Date { runtime.now().addingTimeInterval(clockOffset) }

    var effectiveReducedMotion: Bool {
        settings.reducedMotion || runtime.systemReducedMotion()
    }

    var alertsAllowed: Bool { settings.alertsAllowed(at: now) }

    var unseenCount: Int { items.filter { unseen.contains($0.id) }.count }

    /// Privacy for the Inbox rows: the setting, unless details were revealed this session.
    var inboxPrivacy: Bool { settings.privacyMode && !detailsRevealed }

    var mascotState: MascotState {
        let base = MascotPolicy.state(dataState: dataState, items: items, unseenCount: unseenCount,
                                      alertsAllowed: alertsAllowed)
        return ServiceStatusPolicy.mood(base: base, monitor: serviceMonitor, unseenIncidents: unseenIncidents.count,
                                        alertsAllowed: alertsAllowed)
    }

    var badge: String? { MascotPolicy.badge(dataState: dataState, count: items.count) }

    var inboxCountDescription: String {
        dismissedInboxMessage ?? MascotPolicy.countDescription(dataState: dataState, count: items.count)
    }

    var dismissedInboxMessage: String? {
        allCurrentInboxItemsDismissed ? "All current Inbox items are dismissed." : nil
    }

    /// What the mascot's badge shows (capped at "99+"); `badge` and accessibility keep the full count.
    var mascotBadge: String? { MascotPolicy.mascotBadge(dataState: dataState, count: items.count) }

    /// Fixture data is always identified as Demo, in every surface and in privacy mode.
    /// Informational note beside visible rows; never a Partial badge, warning or mood change.
    /// A dismissal can hide the last local row while these GitHub-side matches still exist.
    var hiddenResultsNote: String? {
        displayedState == .ready && hiddenResultCount > 0 ? HiddenResults.notVisible(hiddenResultCount) : nil
    }

    /// Your open PRs that need nothing from you (#9): one informational line, never rows,
    /// counts, badges, mood or attention.
    @Published private(set) var authoredWaitingCount = 0
    var authoredWaitingNote: String? { AuthoredWaiting.note(authoredWaitingCount, dataState: dataState) }

    var isDemo: Bool { usingFixtures }

    var summaryLines: [String] {
        PrivacyText.summary(dataState: dataState, items: items, unseenCount: unseenCount,
                            privacy: settings.privacyMode, demo: isDemo, demoSource: demoSource,
                            emptyInboxMessage: dismissedInboxMessage)
    }

    /// Where Demo data comes from: the --simulate-monitoring-scope launch is not fixtures.
    var demoSource: String { simulatesScope ? "simulated scope" : "fixtures" }

    /// The Inbox's Demo notice (also recorded by the QA runner); nil for real data.
    var demoNotice: String? {
        if simulatesScope { return "Simulated scope (demo): invented accounts and items, offline, temporary settings. Not from GitHub." }
        return isDemo ? "Demo data (fixtures): invented items, not from GitHub." : nil
    }

    /// Panel geometry for an art size with the loaded pack's label floor (no pack: labels stay
    /// above the art canvas, since the placeholder's hop isn't bounded).
    func layout(_ size: Double) -> MascotLayout {
        if let cached = layouts[size] { return cached }
        let layout = MascotLayout(artSide: CGFloat(size), contours: pack?.allContours ?? [])
        layouts[size] = layout
        return layout
    }
    private var layouts: [Double: MascotLayout] = [:]

    /// Top contour of the pose being drawn (nil for the placeholder, whose labels stay above it).
    func contour(for pose: MascotPose) -> [Int?]? { pack?.contour(for: pose) }

    /// Mascots below this size get the compact two-line hover summary (#27).
    static let compactHoverBelow: Double = 80

    var hoverIsCompact: Bool { settings.mascotSize < Self.compactHoverBelow }

    /// What the hover summary shows: the full summary, or two lines (small mascot, or when the
    /// full summary can't be placed within #27's limits).
    func hoverLines(compact: Bool) -> [String] {
        compact
            ? IncidentMarker.compactHoverLines(dataState: dataState, items: items, unseenCount: unseenCount,
                                               demo: isDemo, demoSource: demoSource, marker: incidentMarker,
                                               emptyInboxMessage: allCurrentInboxItemsDismissed ? "Current items dismissed" : nil)
            : IncidentMarker.hoverLines(fullHoverSummary, marker: incidentMarker)
    }

    /// The hover keeps its height with an incident line on top: it previews one item fewer
    /// (the Inbox lists them all), so placement beside the character is unchanged (#27).
    private var fullHoverSummary: [String] {
        PrivacyText.summary(dataState: dataState, items: items, unseenCount: unseenCount, privacy: settings.privacyMode,
                            demo: isDemo, demoSource: demoSource, maxLines: incidentMarker == nil ? 3 : 2,
                            emptyInboxMessage: dismissedInboxMessage)
    }

    /// Count of actionable items plus, separately, active incidents (#37); the badge stays items only.
    var statusAccessibilityLabel: String {
        IncidentMarker.statusLabel(dataState: dataState, count: items.count, demo: isDemo,
                                   needsAttention: showsAlertIcon, marker: incidentMarker,
                                   countDescription: dismissedInboxMessage)
    }

    /// Shown only for a fresh, confirmed unresolved incident (#37).
    var incidentMarker: IncidentMarker? { IncidentMarker.current(state: serviceState, incidents: serviceIncidents) }

    /// Seconds into the marker burst at `date`, or nil for the static frame.
    /// What the marker draws at `date`: static, or a point in its burst.
    func markerPhase(at date: Date, reduced: Bool) -> IncidentMarker.Phase {
        incidentMarker?.phase(now: date, burst: markerBurst, reducedMotion: reduced,
                              alertsAllowed: settings.alertsAllowed(at: date)) ?? .still
    }

    var showsAlertIcon: Bool {
        alertsAllowed && (unseenCount > 0 || !unseenIncidents.isEmpty || mascotState == .urgent)
    }

    // MARK: Polling

    private var pollInterval: TimeInterval { settings.dataSource == .fixtures ? 30 : 120 }

    /// A new source starts empty and Loading: rows, counts and baseline from the previous
    /// source (e.g. Demo fixtures or another account) are never shown as this source's data.
    private func switchSource() {
        serviceGenerations.switchSource()
        repositoryTask?.cancel(); repositoryTask = nil
        if settings.dataSource == .fixtures { scopeSession.startDemo() } else { scopeSession.startLive() }
        resetSession()
        resetServiceStatus()
        pollTimer?.invalidate()
        if pollsPeriodically && runtime.schedulesTimers {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        sync(now: clock())
        refresh()
    }

    private func resetSession() {
        engine.reset()
        baselineKey = nil
        unseen.removeAll()
        clips.clear()
        activeClip = nil
    }

    /// Public GitHub Status doesn't depend on the gh account, so only a data-source switch (or a
    /// snapshot reset) clears it, never a `gh auth switch`.
    private func resetServiceStatus() {
        serviceMonitor.reset()
        unseenIncidents.removeAll()
        markerBurst = nil
    }

    func refresh() {
        refreshServiceStatus()
        refreshRepositoriesOnly()
    }

    /// The Refresh control (and wake). A request during an in-flight repository poll is
    /// remembered once and runs after that reply lands, instead of being silently dropped.
    func requestRefresh() {
        guard repositoryTask != nil else { refresh(); return }
        refreshServiceStatus()
        queuedRefreshGeneration = scopeSession.generation
    }

    private func runQueuedRefresh() {
        guard let queued = queuedRefreshGeneration, repositoryTask == nil else { return }
        queuedRefreshGeneration = nil
        guard queued == scopeSession.generation else { return }
        refreshRepositoriesOnly()
    }

    /// One refresh after the Mac wakes, live source only; wakes during the delay collapse into it.
    func handleWake() {
        guard settings.dataSource == .githubCLI, !snapshotMode, wakeTask == nil else { return }
        let delay = runtime.wakeRefreshDelay
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.wakeTask = nil
            guard !Task.isCancelled, self.settings.dataSource == .githubCLI else { return }
            self.requestRefresh()
        }
    }

    private func resetRepositories() {
        engine.reset()
        resetActions()
        baselineKey = nil
        unseen.removeAll()
        clips.clear(origin: .repository)
        activeClip = clips.active
        detailsRevealed = false
        blockedLinkNote = nil
    }

    private func prepareAssignmentModeChange(from previousMode: AssignmentMode) {
        _ = engine.refreshFreshness(now: clock())
        engine.beginReviewReachChange()
        let reviewPrefix = "\(ItemKind.reviewRequest.rawValue):"
        for id in unseen.ids where id.hasPrefix(reviewPrefix) { unseen.remove(id) }
        // Entitlement reviews have the same review ID after display-time reclassification.
        clips.clear(origin: .repository, matching: { $0.item.id.hasPrefix(reviewPrefix) })

        guard let oldKey = makeBaselineKey(assignmentMode: previousMode), let newKey = currentBaselineKey else { return }
        if baselineKey == oldKey {
            baselineKey = newKey
            persistBaseline()
        } else if baselineKey == nil, var saved = baselineStore.load(for: oldKey) {
            // Settings can be changed before the first reply has restored a saved baseline.
            saved.key = newKey.value
            saved.reviewReachPending = true
            baselineStore.save(saved)
        }
    }

    private func switchAssignmentMode() {
        scopeSession.changeAssignmentMode()
        queuedRefreshGeneration = nil
        repositoryTask?.cancel()
        repositoryTask = nil

        if settings.dataSource == .githubCLI { sync(now: clock()) }
        refreshRepositoriesOnly()
    }

    private func launchRepositoryPoll(_ request: ScopePollRequest, budget: CommandBudget, refetches: Int) {
        let client = scopedClient
        if scopeSimulation != nil {
            launchedScopePolls += 1
            simulatedPollLog.append(request)
            if simulatedPollLog.count > 64 { simulatedPollLog.removeFirst(simulatedPollLog.count - 64) }
        }
        let simulated = scopeSimulation != nil
        let actions = actionsJob(for: request)
        repositoryTask = Task.detached { [weak self] in
            let result = await withTaskCancellationHandler {
                if !simulated { return Self.poll(client, request, budget, actions: actions) }
                // Simulated replies can be held indefinitely by design. Keep that blocking wait on
                // GCD, which adds threads, not on the small cooperative pool: held replies there
                // starved every other task (CI 43776871945 hung with all pool threads blocked).
                return await withCheckedContinuation { done in
                    DispatchQueue.global(qos: .userInitiated).async {
                        done.resume(returning: Self.poll(client, request, budget, actions: actions))
                    }
                }
            } onCancel: {
                if !simulated { budget.cancel() }
            }
            await self?.receiveRepositoryPoll(result, request: request, budget: budget, refetches: refetches)
        }
    }

    nonisolated private static func poll(_ client: any ScopedPolling, _ request: ScopePollRequest,
                                         _ budget: CommandBudget) -> ScopedPollResult {
        request.identityOnly ? client.fetchIdentity(expectedAccount: request.expectedAccount, budget: budget)
            : client.fetch(scope: request.scope, expectedAccount: request.expectedAccount,
                           assignmentMode: request.assignmentMode, budget: budget)
    }

    /// #10: the watched repositories' Actions query, run after the inbox searches with its own budget.
    struct ActionsJob: Sendable {
        /// Workflow failures; nil when only deployment approvals are watched.
        let client: (any ActionsPolling)?
        let repositories: [MonitoringTarget]
        let makeBudget: @Sendable () -> CommandBudget
        /// Deployment approvals; nil when not watched. Its own budget and last-known rows.
        var deployments: (any DeploymentPolling)? = nil
        /// Which parts are watched; part of the Actions baseline key.
        var sources: String { (client == nil ? "" : "failures") + (deployments == nil ? "" : "+deployments") }
    }

    /// The Actions side of one poll, kept apart from the inbox result.
    enum ActionsReply: Sendable {
        /// Not watched (off, no selected repository, not the live CLI source).
        case off
        /// Watched, but the inbox reply wasn't usable, so Actions weren't queried this time.
        case notChecked
        case result(failures: ScopedPollResult?, deployments: ScopedPollResult?, repositories: [MonitoringTarget],
                    viewer: ScopeViewer, account: ScopeAccount, sources: String)
    }
    struct RepositoryReply: Sendable {
        let inbox: ScopedPollResult
        let actions: ActionsReply
    }

    private let actionsLastKnown = ActionsLastKnown()
    private let deploymentsLastKnown = ActionsLastKnown()
    private var actionsClient: (any ActionsPolling)? {
        runtime.actionsClient ?? (scopeSimulation == nil ? ActionsGhClient() : nil)
    }
    private var deploymentsClient: (any DeploymentPolling)? {
        runtime.deploymentsClient ?? (scopeSimulation == nil ? DeploymentGhClient() : nil)
    }

    /// Only for a live GitHub CLI poll of a real selection with the opt-in on.
    private func actionsJob(for request: ScopePollRequest) -> ActionsJob? {
        let failures = settings.watchWorkflowFailures ? actionsClient : nil
        let deployments = settings.watchDeploymentApprovals ? deploymentsClient : nil
        guard settings.dataSource == .githubCLI, !request.identityOnly, failures != nil || deployments != nil,
              case .repositories(let repositories, _) = ActionsWatch.coverage(enabled: true, scope: request.scope) else { return nil }
        return ActionsJob(client: failures, repositories: repositories, makeBudget: runtime.actionsBudget,
                          deployments: deployments)
    }

    /// The inbox poll, plus Actions failures when watched. Actions run only after a usable inbox
    /// reply, bound to the same expected account, and come back separately: they never change
    /// the inbox's completeness or announcements.
    nonisolated static func poll(_ client: any ScopedPolling, _ request: ScopePollRequest, _ budget: CommandBudget,
                                 actions: ActionsJob?) -> RepositoryReply {
        let inbox = poll(client, request, budget)
        guard let actions else { return RepositoryReply(inbox: inbox, actions: .off) }
        guard let viewer = inbox.viewer, inbox.successfulSources > 0, !Task.isCancelled else {
            return RepositoryReply(inbox: inbox, actions: .notChecked)
        }
        let expected = request.expectedAccount ?? viewer.account
        // Each part gets its own budget when it starts. Only an accepted reply can update last-known rows.
        let failures = actions.client.map {
            $0.fetch(repositories: actions.repositories, expectedAccount: expected, budget: actions.makeBudget())
        }
        guard !Task.isCancelled else { return RepositoryReply(inbox: inbox, actions: .notChecked) }
        let deployments = actions.deployments.map {
            $0.fetch(repositories: actions.repositories, expectedAccount: expected, budget: actions.makeBudget())
        }
        return RepositoryReply(inbox: inbox, actions: .result(failures: failures, deployments: deployments,
                                                              repositories: actions.repositories, viewer: viewer,
                                                              account: expected, sources: actions.sources))
    }

    /// Applies the Actions side after the inbox snapshot: its own baseline (a new account or
    /// watched set seeds silently), its own announcements, and its own quality line.
    private func applyActions(_ reply: ActionsReply) {
        switch reply {
        case .off:
            if actionsCoverageKey != nil || !actionsEngine.items.isEmpty { resetActions() }
        case .notChecked:
            if actionsCoverageKey != nil { actionsQuality = ActionsWatch.notCheckedLine }
        case .result(let failures, let deployments, let repositories, let viewer, let account, let sources):
            let knownFailures = failures.map { actionsLastKnown.apply($0, repositories: repositories, account: account) }
            let knownDeployments = deployments.map {
                deploymentsLastKnown.apply($0, repositories: repositories, account: account, alias: DeploymentApprovals.alias)
            }
            let result = ScopedPollResult.combiningActions(failures: knownFailures, deployments: knownDeployments,
                                                           fallbackViewer: viewer)
            let key = account.viewerID + "\n" + sources + "\n" + repositories.map(\.qualifier).sorted().joined(separator: ",")
            if key != actionsCoverageKey { resetActions(); actionsCoverageKey = key }
            let date = clock()
            let outcome = FetchOutcome.snapshot(items: result.items, complete: result.complete, hidden: 0)
            let events = actionsEngine.apply(outcome, now: date)
            unseen.record(events)
            unseen.reconcile(after: outcome, items: actionsEngine.items + engine.items)
            let shown = events.map { event in
                var event = event; event.item = classified(event.item); return event
            }
            clips.enqueue(shown, now: date, playable: !effectiveReducedMotion && settings.alertsAllowed(at: date))
            actionsQuality = result.complete ? nil : ActionsWatch.qualityLine(for: result.issues, watched: repositories.count)
            deploymentsWaitingCount = result.waitingOnOthers
        }
    }

    private func resetActions() {
        for item in actionsEngine.items { unseen.remove(item.id) }
        actionsEngine.reset()
        actionsCoverageKey = nil
        actionsQuality = nil
        deploymentsWaitingCount = 0
    }

    /// Settings › GitHub Actions: what is (and isn't) watched right now.
    var workflowWatchNote: String? {
        guard settings.watchWorkflowFailures || settings.watchDeploymentApprovals else { return nil }
        guard settings.dataSource == .githubCLI else {
            return settings.watchWorkflowFailures ? "Workflow failures are watched with the GitHub CLI source."
                : "Deployment approvals are watched with the GitHub CLI source."
        }
        switch ActionsWatch.coverage(enabled: true, scope: activeMonitoringScope) {
        case .off: return nil
        case .repositories(let repositories, let note):
            let count = repositories.count
            return "Watching \(count) \(count == 1 ? "repository" : "repositories")." + (note.map { " " + $0 } ?? "")
        case .needsRepositories(let note): return note
        }
    }

    private func receiveRepositoryPoll(_ reply: RepositoryReply, request: ScopePollRequest,
                                       budget: CommandBudget, refetches: Int) {
        let result = reply.inbox
        if scopeSimulation != nil {
            receivedScopeReplies += 1
            let ready = replyWaiters.filter { $0.count <= receivedScopeReplies }
            replyWaiters.removeAll { $0.count <= receivedScopeReplies }
            ready.forEach { $0.resume.resume() }
        }
        guard scopeSession.isCurrent(request) else {
            if scopeSimulation != nil { discardedScopeReplies += 1 }
            return
        }
        repositoryTask = nil
        defer { runQueuedRefresh() }
        let reception = scopeSession.receive(result, for: request)
        if reception.resetRepositories { resetRepositories() }
        switch reception.action {
        case .discard: break
        case .apply(let outcome): apply(outcome); applyActions(reply.actions)
        case .refetch:
            guard refetches > 0 else {
                apply(scopeSession.failCycle(.identityMismatch)); return
            }
            guard budget.remaining > 0 else {
                apply(scopeSession.failCycle(.deadline)); return
            }
            sync(now: clock())
            guard let next = scopeSession.beginPoll(assignmentMode: request.assignmentMode) else { return }
            launchRepositoryPoll(next, budget: budget, refetches: refetches - 1)
        }
        sync(now: clock())
    }

    /// Repository-only commit seam for the later validated Settings draft controller.
    @discardableResult
    func applyRepositoryScope(_ scope: MonitoringScope, identity: ScopeIdentity, generation: Int) -> Bool {
        do {
            guard try scopeSession.apply(scope, for: identity, generation: generation) else { return false }
            repositoryTask?.cancel()
            repositoryTask = nil
            resetRepositories()
            sync(now: clock())
            refreshRepositoriesOnly()
            return true
        } catch { return false }
    }

    private func refreshRepositoriesOnly() {
        // Snapshot renders show the actual CLI source with an injected failure, never a gh call
        // or a scoped request (#52).
        if snapshotMode && settings.dataSource == .githubCLI {
            apply(.failure(snapshotCLIFailure)); return
        }
        if settings.dataSource == .fixtures {
            guard let scope = scopeSession.scope else { apply(scopeSession.configurationFailure); return }
            let outcome = simulator.poll(assignmentMode: settings.assignmentMode)
            if case .snapshot(let items, let complete, let hidden) = outcome {
                apply(.snapshot(items: items.filter { scope.includes(repository: $0.repository) }, complete: complete, hidden: hidden))
            } else { apply(outcome) }
        } else if let request = scopeSession.beginPoll(assignmentMode: settings.assignmentMode) {
            launchRepositoryPoll(request, budget: runtime.repositoryBudget(), refetches: 1)
        }
    }

    private func apply(_ outcome: FetchOutcome) {
        let date = clock()
        let key = currentBaselineKey
        if key != baselineKey {
            // Never carry one source/account/scope session's baseline or rows into another.
            if baselineKey != nil { resetRepositories() }
            if let key, let saved = baselineStore.load(for: key) { engine.restore(saved) }
            baselineKey = key
        }
        let sourceEvents = engine.apply(outcome, now: date)
        persistBaseline()
        dismissals.update(identity: verifiedDismissalIdentity, items: engine.items)
        let events = sourceEvents.filter { !dismissals.hiddenIDs.contains($0.item.id) }
        unseen.record(events)
        unseen.reconcile(after: outcome, items: engine.items + actionsEngine.items)
        let shown = events.map { event in
            var event = event; event.item = classified(event.item); return event
        }
        clips.enqueue(shown, now: date, playable: !effectiveReducedMotion && settings.alertsAllowed(at: date))
        sync(now: date)
    }

    private var currentBaselineKey: BaselineKey? {
        makeBaselineKey(assignmentMode: settings.assignmentMode)
    }

    private func makeBaselineKey(assignmentMode: AssignmentMode) -> BaselineKey? {
        guard let identity = scopeSession.identity, let scope = scopeSession.scope else { return nil }
        return BaselineKey(source: settings.dataSource, identity: identity, scope: scope,
                           assignmentMode: assignmentMode)
    }

    private func persistBaseline() {
        guard let baselineKey else { return }
        baselineStore.save(engine.baseline(key: baselineKey))
    }

    private func refreshServiceStatus() {
        if scopeSimulation != nil { applyServiceStatus(serviceSimulator.poll()); return }
        switch settings.dataSource {
        case .fixtures:
            applyServiceStatus(serviceSimulator.poll())
        case .githubCLI:
            guard let generation = serviceGenerations.beginFetch() else { return }
            let client = serviceClient
            Task.detached {
                let outcome = await client.fetch()
                await MainActor.run {
                    guard self.serviceGenerations.finishFetch(generation) else { return }
                    self.applyServiceStatus(outcome)
                }
            }
        }
    }

    private func applyServiceStatus(_ outcome: ServiceStatusOutcome) {
        let date = clock()
        let shownBefore = incidentMarker?.tier
        let events = serviceMonitor.apply(outcome, now: date)
        unseenIncidents.formUnion(events.map { $0.item.id })
        // Resolved incidents leave quietly, taking their markers with them.
        if case .incidents = outcome {
            unseenIncidents.formIntersection(serviceMonitor.incidents.map(\.inboxItem.id))
        }
        let playable = !effectiveReducedMotion && settings.alertsAllowed(at: date)
        clips.enqueue(events, now: date, playable: playable, origin: .serviceIncident)
        // New incident or a higher tier (#37): one burst; baseline and reconnect produce no events.
        if playable && !events.isEmpty { markerBurst = IncidentMarker.Burst(start: date, fromTier: shownBefore) }
        sync(now: date)
    }

    private func cancelGesture() {
        clips.clear()
        activeClip = nil
        markerBurst = nil
    }

    /// System Reduce Motion: stop a playing gesture the moment it is switched on.
    private var reduceMotionObserver: SystemNotificationObserver?

    func tick() {
        let date = clock()
        if engine.refreshFreshness(now: date) { persistBaseline() }
        serviceMonitor.refreshFreshness(now: date)
        if effectiveReducedMotion || !settings.alertsAllowed(at: date) {
            clips.clear()
            markerBurst = nil
        }
        clips.tick(now: date)
        sync(now: date)
    }

    /// #8: display-time only. The engine, its IDs and unseen state keep the source's kind.
    private func classified(_ item: InboxItem) -> InboxItem {
        EntitlementRepositories.classify(item, repositories: Set(settings.entitlementRepositories))
    }

    /// Settings › Entitlement approvals. Returns the problem to show, or nil once added.
    func addEntitlementRepository(_ text: String) -> EntitlementRepositories.Problem? {
        switch EntitlementRepositories.add(text, to: settings.entitlementRepositories) {
        case .success(let list): settings.entitlementRepositories = list; return nil
        case .failure(let problem): return problem
        }
    }
    func removeEntitlementRepository(_ repository: String) {
        settings.entitlementRepositories.removeAll { $0 == repository }
    }

    /// The inbox's own state, except where workflow failures (#10) change what's visible: an
    /// empty inbox is never "All clear" while they are incomplete, and neither an empty nor a
    /// hidden-only inbox claims "nothing visible" while failure rows are shown.
    private var displayedState: DataState {
        if engine.reviewReachPending && engine.state.countIsKnown { return .loading }
        switch engine.state {
        case .empty:
            if actionsQuality != nil { return .partial }
            return actionsEngine.items.isEmpty ? .empty : .ready
        case .hiddenOnly:
            // "No visible items" can't sit beside failure rows: with rows, count them like any
            // other visible items (the hidden-matches note still shows beside them).
            guard !actionsEngine.items.isEmpty else { return engine.state }
            return actionsQuality != nil ? .partial : .ready
        default:
            return engine.state
        }
    }

    private func sync(now date: Date) {
        now = date
        scopeSummary = scopeSession.summary
        scopeQuality = scopeSession.qualitySummary
        scopeSimulationStatus = scopeSimulation?.status ?? ""
        dismissals.update(identity: verifiedDismissalIdentity, items: engine.items)
        let primary = engine.items.filter { !dismissals.hiddenIDs.contains($0.id) }
        let shown = InboxEngine.dedupe(primary + actionsEngine.items).map(classified)
        if items != shown { items = shown }
        let onlyDismissed = shown.isEmpty && !dismissals.hiddenIDs.isEmpty
        let sourceState = displayedState
        let state: DataState = onlyDismissed && sourceState == .ready && actionsQuality != nil ? .partial : sourceState
        if dataState != state { dataState = state }
        let showsDismissedMessage = onlyDismissed && state == .ready
        if allCurrentInboxItemsDismissed != showsDismissedMessage { allCurrentInboxItemsDismissed = showsDismissedMessage }
        syncDismissedInbox()
        if lastSuccess != engine.lastSuccess { lastSuccess = engine.lastSuccess }
        if hiddenResultCount != engine.hiddenCount { hiddenResultCount = engine.hiddenCount }
        if authoredWaitingCount != scopeSession.waitingOnOthers { authoredWaitingCount = scopeSession.waitingOnOthers }
        if serviceState != serviceMonitor.state { serviceState = serviceMonitor.state }
        if serviceIncidents != serviceMonitor.incidents { serviceIncidents = serviceMonitor.incidents }
        if serviceLastSuccess != serviceMonitor.lastSuccess { serviceLastSuccess = serviceMonitor.lastSuccess }
        let burst = IncidentMarker.retained(markerBurst, marker: incidentMarker)
        if burst != markerBurst { markerBurst = burst }
        if activeClip != clips.active { activeClip = clips.active }
        scopeEditor.observeActive()
    }

    // MARK: Actions

    /// The last saved scope identity can exist before the CLI has returned a viewer.
    private var verifiedDismissalIdentity: ScopeIdentity? {
        switch scopeSession.identity {
        case .demo: return .demo
        case .github(let account) where scopeSession.viewer?.account == account: return .github(account)
        default: return nil
        }
    }

    private func syncDismissedInbox() {
        // Keep filtering any retained rows during auth/setup failures. Management waits for
        // an account we can edit, and failure states keep their ordinary quality message.
        let identity = engine.state == .unauthenticated || engine.state == .ghMissing ? nil : verifiedDismissalIdentity
        let context = identity.map { InboxDismissalContext(identity: $0, generation: scopeSession.generation) }
        if inboxDismissalContext != context { inboxDismissalContext = context }
        let rows = context == nil ? [] : dismissals.rows(showCurrentItems: engine.state == .ready || engine.state == .partial,
                                                        classify: classified)
        if dismissedInboxRows != rows { dismissedInboxRows = rows }
        let notice = context == nil ? nil : dismissals.notice
        if inboxDismissalNotice != notice { inboxDismissalNotice = notice }
    }

    func canDismissInboxItem(_ item: InboxItem) -> Bool {
        inboxDismissalContext != nil && dismissals.canEdit && DismissedInboxItem.supports(item.kind)
    }

    func dismissInboxItem(_ id: String, in context: InboxDismissalContext) {
        guard context == inboxDismissalContext, context.generation == scopeSession.generation,
              let item = engine.items.first(where: { $0.id == id }), canDismissInboxItem(item) else { return }
        let date = clock()
        if dismissals.dismiss(classified(item), at: date) {
            // Drop only this row's pending attention. The raw snapshot and event ledger
            // still observe it, so a Restore cannot replay that attention.
            unseen.remove(id)
            clips.clear(origin: .repository, matching: { $0.item.id == id })
        }
        sync(now: date)
    }

    func restoreInboxItem(_ id: String, in context: InboxDismissalContext) {
        guard context == inboxDismissalContext, context.generation == scopeSession.generation else { return }
        dismissals.restore(id)
        sync(now: clock())
    }

    func markAllSeen() {
        unseen.removeAll()
        unseenIncidents.removeAll()
    }

    func isUnseen(_ incident: ServiceIncident) -> Bool { unseenIncidents.contains(incident.inboxItem.id) }

    /// Opens only https://www.githubstatus.com/incidents/<id>; anything else is reported, not opened.
    func open(_ incident: ServiceIncident) {
        unseenIncidents.remove(incident.inboxItem.id)
        if incident.isDemo {
            blockedLinkNote = "Demo incident: no status page."
            return
        }
        guard let url = ServiceStatusLink.validated(incident.url) else {
            blockedLinkNote = "Link blocked: only githubstatus.com incident links can be opened."
            return
        }
        blockedLinkNote = nil
        NSWorkspace.shared.open(url)
    }

    func isUnseen(_ item: InboxItem) -> Bool { unseen.contains(item.id) }

    /// Opens only validated https://github.com links; anything else is reported, not opened.
    func open(_ item: InboxItem) {
        unseen.remove(item.id)
        guard let url = SafeLink.validated(item.url) else {
            blockedLinkNote = "Link blocked: only https://github.com links can be opened."
            return
        }
        blockedLinkNote = nil
        NSWorkspace.shared.open(url)
    }

    func snooze(_ option: SnoozeOption) {
        settings.snoozeUntil = option.until(from: clock())
    }

    func cancelSnooze() {
        settings.snoozeUntil = nil
    }

    // MARK: Fixture simulator hooks

    var usingFixtures: Bool { settings.dataSource == .fixtures || scopeSimulation != nil }
    /// Window frames autosave to the real standard defaults, so only normal launches keep them.
    var persistsWindowFrames: Bool { scopeSimulation == nil && !snapshotMode }
    var simulatesScope: Bool { scopeSimulation != nil }
    var repositoryFetchInFlight: Bool { repositoryTask != nil }
    var refreshQueued: Bool { queuedRefreshGeneration != nil }
    var observesWake: Bool { wakeObserver?.isObserving == true }
    /// Awaits a scheduled wake refresh, if any.
    func wakeRefreshSettled() async { await wakeTask?.value }
    var simulatedHeldReplies: Int { scopeSimulation?.heldCount ?? 0 }

    // Explicit handshakes for the simulated scope (no wall-clock polling).
    /// Awaits the current repository poll, including any refetch it chains, until none is current.
    func repositoryPollSettled() async {
        while let task = repositoryTask {
            await task.value
            if repositoryTask == task { return }
        }
    }
    func scopeRepliesReceived(_ count: Int) async {
        guard scopeSimulation != nil, receivedScopeReplies < count else { return }
        await withCheckedContinuation { replyWaiters.append((count, $0)) }
    }
    func scopeRepliesHeld(_ count: Int) async { await scopeSimulation?.waitUntilHeld(count) }
    /// Every launched simulated request has been received by the model or is held.
    var simulatedScopeQuiescent: Bool {
        guard let progress = scopeSimulation?.progress else { return true }
        return progress.entered == launchedScopePolls && progress.finished == receivedScopeReplies
            && progress.entered - progress.finished == progress.held
            // Settings checks: every launched validation/discovery was received or is held.
            && scopeEditor.launchedChecks - scopeEditor.receivedChecks == (scopeAccessSimulation?.heldCount ?? 0)
    }
    var simulationDomain: String? { simulationDefaultsSuite }
    /// Keys left in the simulated launch's in-memory domain (0 after cleanup).
    var simulationDomainKeyCount: Int {
        simulationDefaultsSuite.map { scopeDefaults.persistentDomain(forName: $0)?.count ?? 0 } ?? 0
    }
    var simulatedAccountName: String? {
        scopeSimulation.map { $0.account == ScopeSimulation.accountA ? "A" : "B" }
    }
    var simulatedRequests: [ScopeSimulation.Request] { scopeSimulation?.requestHistory ?? [] }
    var monitoringScopeIdentity: ScopeIdentity? { scopeSession.identity }
    var monitoringScopeGeneration: Int { scopeSession.generation }
    var activeMonitoringScope: MonitoringScope? { scopeSession.scope }
    var monitoringScopeConfigurationError: Bool { scopeSession.configurationError }
    /// Display only, shown in explicit Settings; persistence is keyed by node ID.
    var monitoringScopeViewerLogin: String? { scopeSession.viewer?.login }

    func cleanupScopeSimulation() {
        guard let suite = simulationDefaultsSuite, suite.hasPrefix("dev.github-pet.scope-simulation.") else { return }
        scopeSession.invalidate()
        repositoryTask?.cancel(); repositoryTask = nil
        wakeTask?.cancel(); wakeTask = nil
        scopeSimulation?.releaseReplies()
        scopeAccessSimulation?.releaseValidations()
        pollTimer?.invalidate(); tickTimer?.invalidate()
        // The domain is in-memory (EphemeralDefaults), so this clears everything; nothing was on disk.
        scopeDefaults.removePersistentDomain(forName: suite)
        EphemeralDefaults.release(suite)
    }

    // Explicit offline launch only; these controls never exist in a normal session.
    func simulateAssignmentMode(_ mode: AssignmentMode) {
        guard scopeSimulation != nil else { return }
        settings.assignmentMode = mode
    }

    func simulateAssignedIssue() {
        guard settings.dataSource == .githubCLI, let simulation = scopeSimulation else { return }
        simulation.injectAssignedIssue()
        refreshRepositoriesOnly()
    }

    func simulateScopeAccount(_ isB: Bool) {
        guard settings.dataSource == .githubCLI, let simulation = scopeSimulation else { return }
        simulation.switchAccount(isB ? ScopeSimulation.accountB : ScopeSimulation.accountA)
        repositoryTask?.cancel(); scopeSession.invalidate()
        refreshRepositoriesOnly()
    }
    func simulateScopeApply(_ selected: Bool) {
        guard settings.dataSource == .githubCLI, scopeSimulation != nil, let identity = scopeSession.identity else { return }
        let scope = identity == .github(ScopeSimulation.accountB) ? ScopeSimulation.selectedB : ScopeSimulation.selectedA
        _ = applyRepositoryScope(selected ? scope : .everything, identity: identity, generation: scopeSession.generation)
    }
    func simulateScopeHold(_ count: Int = 1, refresh: Bool = true) {
        guard settings.dataSource == .githubCLI, let simulation = scopeSimulation else { return }
        simulation.holdNextReply(count)
        if refresh { refreshRepositoriesOnly() }
    }
    func simulateScopeDeliver() { scopeSimulation?.releaseReplies(); scopeAccessSimulation?.releaseValidations() }
    func simulateScopeDeliverOne(newest: Bool) { scopeSimulation?.releaseReply(newest: newest) }
    func simulateScopeDiscovery(_ mode: ScopeAccessSimulation.DiscoveryMode) { scopeAccessSimulation?.setDiscovery(mode); objectWillChange.send() }
    func simulateScopeValidation(_ mode: ScopeAccessSimulation.ValidationMode) { scopeAccessSimulation?.setValidation(mode); objectWillChange.send() }
    func simulateScopeHoldValidation() { scopeAccessSimulation?.holdNextValidation(); objectWillChange.send() }
    func simulateScopeInject() {
        guard settings.dataSource == .githubCLI, let simulation = scopeSimulation else { return }
        simulation.inject(); refreshRepositoriesOnly()
    }
    func simulateScopePartial(_ on: Bool) {
        guard settings.dataSource == .githubCLI, let simulation = scopeSimulation else { return }
        simulation.setPartial(on); refreshRepositoriesOnly()
    }
    /// #9 fixtures: authored PRs (one per mode needing action, plus waiting/draft/still-checking ones).
    func simulateScopeAuthored(_ mode: ScopeSimulation.Authored) {
        guard settings.dataSource == .githubCLI, let simulation = scopeSimulation else { return }
        simulation.setAuthored(mode); refreshRepositoriesOnly()
    }
    /// #35 fixtures: matches hidden from the viewer, hidden-only, or capped review searches.
    func simulateScopeVisibility(_ mode: ScopeSimulation.Visibility) {
        guard settings.dataSource == .githubCLI, let simulation = scopeSimulation else { return }
        simulation.setVisibility(mode); refreshRepositoriesOnly()
    }
    var simulatedVisibility: ScopeSimulation.Visibility? { scopeSimulation?.currentVisibility }
    func simulateScopeReload(corrupt: Bool = false, forgetViewer: Bool = false,
                             account: ScopeAccount = ScopeSimulation.accountA) {
        guard settings.dataSource == .githubCLI, let simulation = scopeSimulation else { return }
        if corrupt { ScopeSimulation.corruptA(scopeDefaults) }
        if forgetViewer { scopeStore.rememberAccount(nil) }
        simulation.switchAccount(account)
        repositoryTask?.cancel(); scopeSession.startLive(); resetRepositories()
        sync(now: clock()); refreshRepositoriesOnly()
    }
    /// Corrupts one saved record without reloading (the next restore of that account sees it).
    func simulateScopeCorrupt(_ account: ScopeAccount) {
        guard settings.dataSource == .githubCLI, scopeSimulation != nil else { return }
        ScopeSimulation.corrupt(scopeDefaults, account: account)
    }
    /// Re-seeds both saved selections and the remembered viewer without reloading.
    func simulateScopeSeed() {
        guard settings.dataSource == .githubCLI, scopeSimulation != nil else { return }
        try? ScopeSimulation.seed(scopeDefaults)
    }
    func simulateScopeRepair() {
        guard settings.dataSource == .githubCLI, scopeSimulation != nil else { return }
        try? ScopeSimulation.seed(scopeDefaults)
        simulateScopeReload()
    }

    func injectEntitlementEvent() {
        guard usingFixtures else { return }
        // App clock, like workflow injections, so QA clock hooks order fixture items consistently.
        simulator.injectEntitlementEvent(now: clock())
        refresh()
    }

    func injectWorkflowFailure() {
        guard usingFixtures else { return }
        simulator.injectWorkflowFailure(now: clock())
        refresh()
    }

    func replaySnapshot() {
        guard usingFixtures else { return }
        refresh()
    }

    var partialPolls: Bool { simulator.partialPolls }

    /// Sticky: stays partial across the periodic fixture poll until turned off.
    func setPartialPolls(_ on: Bool) {
        guard usingFixtures else { return }
        simulator.partialPolls = on
        refresh()
        objectWillChange.send()
    }

    func injectServiceIncident(_ impact: IncidentImpact) {
        guard usingFixtures else { return }
        serviceSimulator.injectIncident(impact: impact, now: clock())
        refreshServiceStatus()
    }

    func escalateServiceIncidents() {
        guard usingFixtures else { return }
        serviceSimulator.escalateAll(now: clock())
        refreshServiceStatus()
    }

    func resolveServiceIncidents() {
        guard usingFixtures else { return }
        serviceSimulator.resolveAll(now: clock())
        refreshServiceStatus()
    }

    /// Every open fixture incident one tier up (minor → major → critical): one burst per tier reached.
    func escalateServiceIncidentsOneLevel() {
        guard usingFixtures else { return }
        serviceSimulator.escalateOneLevel(now: clock())
        refreshServiceStatus()
    }

    /// One tier down: silent.
    func deescalateServiceIncidentsOneLevel() {
        guard usingFixtures else { return }
        serviceSimulator.deescalateOneLevel(now: clock())
        refreshServiceStatus()
    }

    /// Reopen the last resolved fixture incident under its old ID: silent.
    func reopenLastResolvedIncident() {
        guard usingFixtures else { return }
        serviceSimulator.reopenLastResolved(now: clock())
        refreshServiceStatus()
    }

    var canReopenServiceIncident: Bool { serviceSimulator.canReopen }

    /// Scheduled maintenance: never an incident, never the marker.
    func injectScheduledMaintenance() {
        guard usingFixtures else { return }
        serviceSimulator.injectMaintenance(now: clock())
        refreshServiceStatus()
    }

    var serviceFetchFails: Bool { serviceSimulator.fetchFails }

    /// Service status only: the fetch fails (last-known incidents dimmed, never "no incidents") or recovers.
    func setServiceFetchFails(_ fails: Bool) {
        guard usingFixtures else { return }
        serviceSimulator.fetchFails = fails
        refreshServiceStatus()
        objectWillChange.send()
    }

    /// Service status only: stale until the next poll.
    func markServiceStale() {
        guard usingFixtures else { return }
        serviceMonitor.markStale()
        sync(now: clock())
    }

    func simulateDisconnect() {
        guard usingFixtures else { return }
        simulator.disconnect()
        serviceSimulator.connected = false
        refresh()
    }

    func simulateReconnect() {
        guard usingFixtures else { return }
        simulator.reconnect()
        serviceSimulator.connected = true
        refresh()
    }

    func markStale() {
        guard usingFixtures else { return }
        engine.markStale()
        persistBaseline()
        serviceMonitor.markStale()
        sync(now: clock())
    }

    func resetBaseline() {
        engine.resetBaseline()
        baselineStore.reset()
        serviceMonitor.resetBaseline()
        unseen.removeAll()
        unseenIncidents.removeAll()
        clips.clear()
        // The re-seeded baseline is static: no burst carries over.
        markerBurst = nil
        refresh()
    }

    var simulatorConnected: Bool { simulator.connected }

    /// Render hook only: show a gh setup failure through the real engine, without polling.
    func showSourceFailureForSnapshot(_ failure: FetchFailure) {
        guard snapshotMode else { return }
        snapshotCLIFailure = failure
        if settings.dataSource != .githubCLI {
            settings.dataSource = .githubCLI
            return // switchSource resets both baselines and refreshes the injected source.
        }
        resetSession()
        refresh()
    }

    /// Render hook only: show the Loading state of a fresh source without polling.
    func showLoadingForSnapshot() {
        resetSession()
        resetServiceStatus()
        sync(now: clock())
    }
}

/// GitHub Status transport for snapshot renders: fails immediately, never touches the network.
private struct OfflineStatusTransport: StatusTransport {
    func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        throw StatusFetchError.transport("live status disabled in snapshot mode")
    }
}
