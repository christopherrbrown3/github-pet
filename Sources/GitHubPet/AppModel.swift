import AppKit
import Combine
import GitHubPetCore

/// Shared state behind the menu-bar inbox, the Inbox window, Settings and the mascot.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var items: [InboxItem] = []
    @Published private(set) var dataState: DataState = .loading
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var unseen = UnseenItems()
    /// "Show details" in the Inbox: names and titles for this app session only, never saved.
    /// Hover, mascot and menu-bar text stay generic while privacy mode is on.
    @Published var detailsRevealed = false
    @Published private(set) var activeClip: EventClipQueue.Clip?
    @Published private(set) var blockedLinkNote: String?
    @Published private(set) var now = Date()
    @Published var settings: PetSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            if settings.dataSource != oldValue.dataSource { switchSource() }
            if settings.privacyMode && !oldValue.privacyMode { detailsRevealed = false }
            // Snooze, quiet hours or Reduce Motion turned on: stop a playing gesture now, not at
            // the next tick. Nothing is re-queued, so turning them off later replays nothing.
            if GestureCancellation.shouldCancel(from: oldValue, to: settings, at: clock()) { cancelGesture() }
        }
    }

    let pack: MascotPack?
    let packErrors: [MascotPackError]

    private let store: SettingsStore
    let clockOffset: TimeInterval
    private let pollsPeriodically: Bool
    private let engine = InboxEngine()
    private let simulator = FixtureSimulator()
    private let ghClient = GhClient()
    private var clips = EventClipQueue()
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var generations = SourceGenerations()
    private var accounts = AccountWatch()

    init(options: LaunchOptions) {
        store = SettingsStore(defaults: options.userDefaults)
        clockOffset = options.clockOffset
        // The snapshot scenario drives every refresh itself; a periodic poll firing mid-scenario
        // would refresh a step it just made stale (flaky render-check).
        pollsPeriodically = options.snapshotDirectory == nil
        if options.resetSettings { store.reset() }
        var loaded = store.load()
        switch options.forcedSource {
        case "fixtures": loaded.dataSource = .fixtures
        case "gh": loaded.dataSource = .githubCLI
        default: break
        }
        settings = loaded

        if let dir = options.resolvedPackDirectory() {
            switch MascotPack.load(from: dir) {
            case .success(let pack): self.pack = pack; packErrors = []
            case .failure(let failure): pack = nil; packErrors = failure.errors
            }
        } else {
            pack = nil
            packErrors = []
        }
        // One launch line on stderr so QA can confirm which mascot is in use.
        let packStatus = pack.map { "mascot pack \($0.manifest.id) loaded from \($0.directory.path)" }
            ?? (packErrors.isEmpty ? "mascot placeholder (no pack)"
                : "mascot placeholder (pack rejected: \(packErrors.map(\.description).joined(separator: "; ")))")
        FileHandle.standardError.write(Data("GitHubPet: \(packStatus)\n".utf8))

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        reduceMotionObserver = SystemNotificationObserver(
            center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        ) { [weak self] in
            Task { @MainActor in
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self?.cancelGesture() }
            }
        }
        switchSource()
        if let delay = options.injectEventAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.injectEntitlementEvent() }
        }
    }

    // MARK: Derived state

    /// App clock: wall clock plus the QA offset from launch options.
    func clock() -> Date { Date().addingTimeInterval(clockOffset) }

    var effectiveReducedMotion: Bool {
        settings.reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var alertsAllowed: Bool { settings.alertsAllowed(at: now) }

    var unseenCount: Int { items.filter { unseen.contains($0.id) }.count }

    /// Privacy for the Inbox rows: the setting, unless details were revealed this session.
    var inboxPrivacy: Bool { settings.privacyMode && !detailsRevealed }

    var mascotState: MascotState {
        MascotPolicy.state(dataState: dataState, items: items, unseenCount: unseenCount, alertsAllowed: alertsAllowed)
    }

    var badge: String? { MascotPolicy.badge(dataState: dataState, count: items.count) }

    /// What the mascot's badge shows (capped at "99+"); `badge` and accessibility keep the full count.
    var mascotBadge: String? { MascotPolicy.mascotBadge(dataState: dataState, count: items.count) }

    /// Fixture data is always identified as Demo, in every surface and in privacy mode.
    var isDemo: Bool { usingFixtures }

    var summaryLines: [String] {
        PrivacyText.summary(dataState: dataState, items: items, unseenCount: unseenCount,
                            privacy: settings.privacyMode, demo: isDemo)
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
            ? PrivacyText.compactSummary(dataState: dataState, items: items, unseenCount: unseenCount, demo: isDemo)
            : summaryLines
    }

    var statusAccessibilityLabel: String {
        AccessibilityText.statusLabel(dataState: dataState, count: items.count, demo: isDemo,
                                      needsAttention: showsAlertIcon)
    }

    var showsAlertIcon: Bool { alertsAllowed && (unseenCount > 0 || mascotState == .urgent) }

    // MARK: Polling

    private var pollInterval: TimeInterval { settings.dataSource == .fixtures ? 30 : 120 }

    /// A new source starts empty and Loading: rows, counts and baseline from the previous
    /// source (e.g. Demo fixtures or another account) are never shown as this source's data.
    private func switchSource() {
        generations.switchSource()
        accounts.reset()
        resetSession()
        pollTimer?.invalidate()
        if pollsPeriodically {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        sync(now: clock())
        refresh()
    }

    private func resetSession() {
        engine.reset()
        unseen.removeAll()
        clips.clear()
        activeClip = nil
    }

    func refresh() {
        switch settings.dataSource {
        case .fixtures:
            apply(simulator.poll())
        case .githubCLI:
            guard let generation = generations.beginFetch() else { return }
            let client = ghClient
            Task.detached {
                let fetch = client.fetchWithAccount()
                await MainActor.run {
                    // Results from a session that has since been switched away are dropped.
                    guard self.generations.finishFetch(generation) else { return }
                    // `gh auth switch` keeps the mode but changes whose data this is: start a
                    // fresh baseline so the new account's existing items are not announced.
                    if self.accounts.observe(fetch.account) { self.resetSession() }
                    self.apply(fetch.outcome)
                }
            }
        }
    }

    private func apply(_ outcome: FetchOutcome) {
        let date = clock()
        let events = engine.apply(outcome, now: date)
        unseen.record(events)
        unseen.reconcile(after: outcome, items: engine.items)
        clips.enqueue(events, now: date, playable: !effectiveReducedMotion && settings.alertsAllowed(at: date))
        sync(now: date)
    }

    private func cancelGesture() {
        clips.clear()
        activeClip = nil
    }

    /// System Reduce Motion: stop a playing gesture the moment it is switched on.
    private var reduceMotionObserver: SystemNotificationObserver?

    private func tick() {
        let date = clock()
        engine.refreshFreshness(now: date)
        if effectiveReducedMotion || !settings.alertsAllowed(at: date) { clips.clear() }
        clips.tick(now: date)
        sync(now: date)
    }

    private func sync(now date: Date) {
        now = date
        if items != engine.items { items = engine.items }
        if dataState != engine.state { dataState = engine.state }
        if lastSuccess != engine.lastSuccess { lastSuccess = engine.lastSuccess }
        if activeClip != clips.active { activeClip = clips.active }
    }

    // MARK: Actions

    func markAllSeen() {
        unseen.removeAll()
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

    var usingFixtures: Bool { settings.dataSource == .fixtures }

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

    func simulateDisconnect() {
        guard usingFixtures else { return }
        simulator.disconnect()
        refresh()
    }

    func simulateReconnect() {
        guard usingFixtures else { return }
        simulator.reconnect()
        refresh()
    }

    func markStale() {
        guard usingFixtures else { return }
        engine.markStale()
        sync(now: clock())
    }

    func resetBaseline() {
        engine.resetBaseline()
        unseen.removeAll()
        clips.clear()
        refresh()
    }

    var simulatorConnected: Bool { simulator.connected }

    /// Render hook only: show the Loading state of a fresh source without polling.
    func showLoadingForSnapshot() {
        resetSession()
        sync(now: clock())
    }
}
