import AppKit
import Combine
import GitHubPetCore

/// Shared state behind the menu-bar inbox, the Inbox window, Settings and the mascot.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var items: [InboxItem] = []
    @Published private(set) var dataState: DataState = .loading
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var unseenIDs: Set<String> = []
    @Published private(set) var activeClip: EventClipQueue.Clip?
    @Published private(set) var blockedLinkNote: String?
    @Published private(set) var now = Date()
    @Published var settings: PetSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            if settings.dataSource != oldValue.dataSource { switchSource() }
            if settings.reducedMotion && !oldValue.reducedMotion {
                clips.clear()
                activeClip = nil
            }
        }
    }

    let pack: MascotPack?
    let packErrors: [MascotPackError]

    private let store: SettingsStore
    private let clockOffset: TimeInterval
    private let engine = InboxEngine()
    private let simulator = FixtureSimulator()
    private let ghClient = GhClient()
    private var clips = EventClipQueue()
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var fetchInFlight = false

    init(options: LaunchOptions) {
        store = SettingsStore(defaults: options.userDefaults)
        clockOffset = options.clockOffset
        if options.resetSettings { store.reset() }
        var loaded = store.load()
        switch options.forcedSource {
        case "fixtures": loaded.dataSource = .fixtures
        case "gh": loaded.dataSource = .githubCLI
        default: break
        }
        settings = loaded

        if let dir = options.packDirectory {
            switch MascotPack.load(from: dir) {
            case .success(let pack): self.pack = pack; packErrors = []
            case .failure(let failure): pack = nil; packErrors = failure.errors
            }
        } else {
            pack = nil
            packErrors = []
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
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

    var unseenCount: Int { items.filter { unseenIDs.contains($0.id) }.count }

    var mascotState: MascotState {
        MascotPolicy.state(dataState: dataState, items: items, unseenCount: unseenCount, alertsAllowed: alertsAllowed)
    }

    var badge: String? { MascotPolicy.badge(dataState: dataState, count: items.count) }

    var summaryLines: [String] {
        PrivacyText.summary(dataState: dataState, items: items, unseenCount: unseenCount,
                            privacy: settings.privacyMode)
    }

    var showsAlertIcon: Bool { alertsAllowed && (unseenCount > 0 || mascotState == .urgent) }

    // MARK: Polling

    private var pollInterval: TimeInterval { settings.dataSource == .fixtures ? 30 : 120 }

    private func switchSource() {
        engine.resetBaseline()
        unseenIDs.removeAll()
        clips.clear()
        activeClip = nil
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        switch settings.dataSource {
        case .fixtures:
            apply(simulator.poll())
        case .githubCLI:
            guard !fetchInFlight else { return }
            fetchInFlight = true
            let client = ghClient
            Task.detached {
                let outcome = client.fetch()
                await MainActor.run {
                    self.fetchInFlight = false
                    // Ignore results that arrive after switching back to fixtures.
                    if self.settings.dataSource == .githubCLI { self.apply(outcome) }
                }
            }
        }
    }

    private func apply(_ outcome: FetchOutcome) {
        let date = clock()
        let events = engine.apply(outcome, now: date)
        for event in events { unseenIDs.insert(event.item.id) }
        clips.enqueue(events, now: date, playable: !effectiveReducedMotion && settings.alertsAllowed(at: date))
        sync(now: date)
    }

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
        let present = Set(engine.items.map(\.id))
        if !unseenIDs.isSubset(of: present) { unseenIDs.formIntersection(present) }
        if activeClip != clips.active { activeClip = clips.active }
    }

    // MARK: Actions

    func markAllSeen() {
        unseenIDs.removeAll()
    }

    func isUnseen(_ item: InboxItem) -> Bool { unseenIDs.contains(item.id) }

    /// Opens only validated https://github.com links; anything else is reported, not opened.
    func open(_ item: InboxItem) {
        unseenIDs.remove(item.id)
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
        simulator.injectEntitlementEvent()
        refresh()
    }

    func replaySnapshot() {
        guard usingFixtures else { return }
        refresh()
    }

    func nextPollPartial() {
        guard usingFixtures else { return }
        simulator.nextPoll = .partial
        refresh()
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
        unseenIDs.removeAll()
        clips.clear()
        refresh()
    }

    var simulatorConnected: Bool { simulator.connected }
}
