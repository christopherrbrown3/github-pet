import AppKit
import Combine
import GitHubPetCore
import Sparkle
import SwiftUI

/// The slice of Sparkle's `SPUUpdater` the app uses, so tests drive a fake and never start an
/// updater or reach the network.
@MainActor
protocol UpdaterBackend: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    var updateCheckInterval: TimeInterval { get }
    func checkForUpdates()
    /// A check that shows no window: what it finds goes through the gentle-reminder path.
    func checkForUpdatesInBackground()
}

/// Update state for the menu, the Inbox banner, the menu-bar dot and Settings. Sparkle owns checking,
/// downloading, verification and installation, and shows its own windows only when the user asks;
/// nothing here touches the inbox, its count badge or the mascot.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    let installed: InstalledBuild
    let configuration: UpdateConfiguration
    private let preferences: UpdatePreferences
    private var backend: (any UpdaterBackend)?
    private var observers: [AnyCancellable] = []
    private let now: () -> Date
    /// Posts a VoiceOver announcement; tests capture it.
    var announce: (String) -> Void = { message in
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private var wakeObserver: SystemNotificationObserver?
    private var proactiveCheck: Task<Void, Never>?
    private var laterExpiry: Task<Void, Never>?

    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticInstall = false
    @Published private(set) var lastCheck: Date?
    /// Set by a scheduled check that found an update while the user wasn't asking: shown quietly in
    /// the menu instead of Sparkle opening a window on top of their work.
    @Published private(set) var pendingVersion: String? { didSet { updateIndicator() } }
    /// #149: the version the menu-bar dot and the Inbox banner show: `pendingVersion` unless the user
    /// said "Later" to it within the last day.
    @Published private(set) var indicatorVersion: String?
    /// A verified update that Sparkle will install when GitHub Pet quits (silent install is on).
    @Published private(set) var readyVersion: String?
    @Published var betaOptIn: Bool { didSet { if betaOptIn != oldValue { preferences.betaOptIn = betaOptIn } } }

    /// `backend` is nil when the build isn't configured or must not start an updater.
    init(installed: InstalledBuild, configuration: UpdateConfiguration, defaults: UserDefaults,
         backend: (any UpdaterBackend)?, now: @escaping () -> Date = Date.init) {
        self.installed = installed
        self.now = now
        self.configuration = configuration
        preferences = UpdatePreferences(defaults: defaults)
        betaOptIn = preferences.betaOptIn
        self.backend = configuration.state.isConfigured ? backend : nil
        super.init()
        refresh()
    }

    var state: UpdateConfiguration.State { backend == nil && configuration.state.isConfigured
        ? .notConfigured("Update checks are off in this launch mode.") : configuration.state }
    var isAvailable: Bool { backend != nil }
    /// A prerelease build always follows the beta channel; everyone else chooses.
    var betaForced: Bool { installed.isPrerelease }
    var allowedChannels: Set<String> {
        UpdateChannelPolicy.allowedChannels(installed: installed, optedInToBeta: betaOptIn)
    }

    func refresh() {
        guard let backend else { canCheck = false; automaticChecks = false; automaticInstall = false; lastCheck = nil; return }
        // Install is user-confirmed by default. Silent install counts only when the user turned it on
        // in Settings, so a default keystroke in Sparkle's first-run prompt can never enable it.
        if backend.automaticallyDownloadsUpdates && !preferences.silentInstallOptIn {
            backend.automaticallyDownloadsUpdates = false
        }
        canCheck = backend.canCheckForUpdates
        automaticChecks = backend.automaticallyChecksForUpdates
        automaticInstall = backend.automaticallyDownloadsUpdates
        lastCheck = backend.lastUpdateCheckDate
    }

    func setAutomaticChecks(_ on: Bool) { backend?.automaticallyChecksForUpdates = on; refresh() }
    func setAutomaticInstall(_ on: Bool) {
        guard configuration.allowsAutomaticInstall else { return }
        preferences.silentInstallOptIn = on
        backend?.automaticallyDownloadsUpdates = on; refresh()
    }

    /// The app is an accessory (LSUIElement) app with no Dock icon, so bring it forward first or
    /// Sparkle's window opens behind whatever the user is working in.
    func checkForUpdates() {
        guard let backend, backend.canCheckForUpdates else { return }
        NSApp?.activate(ignoringOtherApps: true)
        backend.checkForUpdates()
        pendingVersion = nil
        refresh()
    }

    /// Wires Sparkle's KVO state into `refresh()`. Called once by the live backend.
    func observe(_ publishers: [AnyPublisher<Void, Never>]) {
        observers = publishers.map { $0.receive(on: DispatchQueue.main).sink { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        } }
    }

    func found(_ version: String?) { pendingVersion = version }
    func ready(_ version: String?) { readyVersion = version }

    // MARK: Indicator (#149)

    /// "Later": hides the dot and banner for this version until a newer one is found or a day passes.
    func dismissIndicator() {
        guard let version = indicatorVersion else { return }
        preferences.indicatorLater = (version, now())
        updateIndicator()
    }

    /// Re-evaluates the indicator, e.g. when a "Later" runs out.
    func updateIndicator() {
        let later = preferences.indicatorLater
        let shown = UpdateIndicatorPolicy.shows(version: pendingVersion, dismissedVersion: later?.version,
                                                dismissedAt: later?.date, now: now()) ? pendingVersion : nil
        if shown != indicatorVersion {
            indicatorVersion = shown
            if let shown { announce("Update available: version \(shown)") }
        }
        laterExpiry?.cancel()
        laterExpiry = nil
        if let end = UpdateIndicatorPolicy.expiry(version: pendingVersion, dismissedVersion: later?.version,
                                                  dismissedAt: later?.date, now: now()) {
            let wait = max(end.timeIntervalSince(now()), 1)
            laterExpiry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.updateIndicator()
            }
        }
    }

    /// Read after the inbox's own status in the menu-bar item's label.
    var indicatorAccessibilityText: String? { indicatorVersion.map { "update available: version \($0)" } }

    // MARK: Proactive checks (#149)

    /// Shortly after launch and after each wake, a background check when Sparkle's interval has
    /// passed. A background check never opens a window; what it finds shows as the indicator.
    func scheduleProactiveChecks(wakeCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
                                 launchDelay: Duration = .seconds(UpdateCheckSchedule.launchDelay),
                                 wakeDelay: Duration = .seconds(UpdateCheckSchedule.wakeDelay)) {
        guard backend != nil else { return }
        checkWhenOverdue(after: launchDelay)
        wakeObserver = SystemNotificationObserver(center: wakeCenter, name: NSWorkspace.didWakeNotification) { [weak self] in
            Task { @MainActor in self?.checkWhenOverdue(after: wakeDelay) }
        }
    }

    /// Repeated wakes collapse into one pending check.
    private func checkWhenOverdue(after delay: Duration) {
        proactiveCheck?.cancel()
        proactiveCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.checkInBackgroundIfOverdue()
        }
    }

    /// Only with automatic checks on (the user's choice), while Sparkle can check, and when overdue.
    @discardableResult
    func checkInBackgroundIfOverdue() -> Bool {
        guard let backend else { return false }
        refresh()
        guard automaticChecks, canCheck,
              UpdateCheckSchedule.isOverdue(lastCheck: lastCheck, interval: backend.updateCheckInterval, now: now()) else { return false }
        backend.checkForUpdatesInBackground()
        return true
    }
}

// MARK: Sparkle

/// The live backend: a standard updater controller. It is created only for a normal launch of a
/// configured app bundle (see `UpdateController.live`).
@MainActor
final class SparkleBackend: NSObject, UpdaterBackend, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    private weak var model: UpdateController?
    private var channels: () -> Set<String> = { [] }

    override init() {
        super.init()
        // startingUpdater: false so a failure to start (bad key) is reported, not thrown away.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    var updater: SPUUpdater { controller.updater }

    func start() -> Error? {
        do { try controller.updater.start() ; return nil } catch { return error }
    }

    func attach(_ model: UpdateController) {
        self.model = model
        channels = { [weak model] in model?.allowedChannels ?? [] }
        let u = controller.updater
        model.observe([
            u.publisher(for: \.canCheckForUpdates).map { _ in }.eraseToAnyPublisher(),
            u.publisher(for: \.automaticallyChecksForUpdates).map { _ in }.eraseToAnyPublisher(),
            u.publisher(for: \.automaticallyDownloadsUpdates).map { _ in }.eraseToAnyPublisher(),
            u.publisher(for: \.lastUpdateCheckDate).map { _ in }.eraseToAnyPublisher(),
        ])
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }
    var updateCheckInterval: TimeInterval { controller.updater.updateCheckInterval }
    func checkForUpdates() { controller.updater.checkForUpdates() }
    func checkForUpdatesInBackground() { controller.updater.checkForUpdatesInBackground() }

    // SPUUpdaterDelegate: beta only for a prerelease build or an opted-in user; stable users are never moved.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { channels() }
    }

    // SPUStandardUserDriverDelegate: a scheduled (background) check never pops a window over the
    // user's work, not even right after launch (#149). Sparkle waits; we show the menu-bar dot, the
    // Inbox banner and a quiet menu line, and "Update…" or "Check for Updates…" opens Sparkle's window.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { model?.found(version) }
    }

    // Silent install: Sparkle has verified and staged the update and installs it on quit. Say so
    // quietly in the UI; returning false leaves the install to Sparkle.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated { model?.ready(version) }
        return false
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { model?.found(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { model?.found(nil) }
    }
}

extension UpdateController {
    /// A normal launch of an app bundle with a valid feed and key starts Sparkle. Anything else
    /// (tests, `swift run`, QA, snapshots, simulated or custom-defaults launches) gets no updater.
    static func make(infoDictionary: [String: Any]?, bundleURL: URL, normalLaunch: Bool, defaults: UserDefaults,
                     backend injected: (any UpdaterBackend)? = nil) -> UpdateController {
        let installed = InstalledBuild(infoDictionary: infoDictionary)
        let configuration = UpdateConfiguration(infoDictionary: infoDictionary)
        if let injected {
            return UpdateController(installed: installed, configuration: configuration, defaults: defaults, backend: injected)
        }
        guard normalLaunch, bundleURL.pathExtension == "app", configuration.state.isConfigured else {
            return UpdateController(installed: installed, configuration: configuration, defaults: defaults, backend: nil)
        }
        let backend = SparkleBackend()
        let controller = UpdateController(installed: installed, configuration: configuration, defaults: defaults, backend: backend)
        backend.attach(controller)
        if let error = backend.start() {
            FileHandle.standardError.write(Data("GitHubPet: updater did not start: \(error.localizedDescription)\n".utf8))
        }
        controller.refresh()
        controller.scheduleProactiveChecks()
        return controller
    }
}

// MARK: Views

struct UpdateStatusSection: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Section("Software updates") {
            LabeledContent("Installed", value: updates.installed.displayVersion)
            if updates.isAvailable {
                LabeledContent("Last checked", value: updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                HStack {
                    Text(updates.readyVersion.map { "Version \($0) is ready and installs when GitHub Pet quits." }
                         ?? updates.pendingVersion.map { "Version \($0) is available." } ?? "Updates are checked by Sparkle.")
                        .accessibilityIdentifier("settings.updateStatus")
                    Spacer()
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheck)
                        .accessibilityHint(updates.canCheck ? "" : "Unavailable while an update check or install is in progress.")
                        .accessibilityIdentifier("settings.updateCheck")
                }
                Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticChecks }, set: updates.setAutomaticChecks))
                    .accessibilityIdentifier("settings.updateAutoCheck")
                Toggle("Install updates automatically, without asking", isOn: Binding(get: { updates.automaticInstall }, set: updates.setAutomaticInstall))
                    .disabled(!updates.configuration.allowsAutomaticInstall || !updates.automaticChecks)
                    .accessibilityHint(!updates.configuration.allowsAutomaticInstall ? "This build doesn't allow automatic install."
                                       : !updates.automaticChecks ? "Turn on automatic checks first." : "")
                    .accessibilityIdentifier("settings.updateAutoInstall")
            } else if case .notConfigured(let reason) = updates.state {
                Text("Updates not configured. \(reason)")
                    .foregroundStyle(Color.orange)
                    .accessibilityIdentifier("settings.updateStatus")
            }
            Toggle("Include beta releases", isOn: Binding(get: { updates.betaOptIn || updates.betaForced }, set: { updates.betaOptIn = $0 }))
                .disabled(updates.betaForced)
                .accessibilityHint(updates.betaForced ? "This is a beta build, so it always follows beta releases." : "")
                .accessibilityIdentifier("settings.updateBeta")
            if updates.betaForced {
                Text("This is a beta build, so it always follows beta releases.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Updates are checked and installed by Sparkle and verified with GitHub Pet's update signing key. A check only downloads the public update list from GitHub Pet's repository: no sign-in, token or system information is sent. Builds are ad-hoc signed and not notarized, so the first install still needs Open Anyway in System Settings. Nothing is installed without your OK unless you turn automatic install on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The menu-bar menu's update entry: a quiet one-liner, never a badge or alert.
struct UpdateMenuRow: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        HStack(spacing: 6) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheck)
                .accessibilityHint(updates.canCheck ? ""
                                   : updates.isAvailable ? "Unavailable while an update check or install is in progress." : "Updates are not configured in this build.")
                .accessibilityIdentifier("menu.checkForUpdates")
            Spacer()
            if let version = updates.readyVersion {
                Text("Version \(version) installs on quit").foregroundStyle(.secondary)
            } else if let version = updates.pendingVersion, updates.indicatorVersion == nil {
                // While the Inbox banner shows, it says this; after "Later" this quiet line remains.
                Text("Version \(version) available").foregroundStyle(.secondary)
            } else if !updates.isAvailable {
                Text("Updates not configured").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}

/// #149: "Update available" in the Inbox header. "Update…" starts Sparkle's normal flow, which still
/// asks before installing; "Later" hides it for this version for a day. Never part of the count badge.
struct UpdateAvailableBanner: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        if let version = updates.indicatorVersion {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                // A version never wraps at its hyphen: title and version each stay on one line.
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.callout).lineLimit(1)
                    Text(version).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                Button("Later") { updates.dismissIndicator() }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Hides this until a newer version is found or for 24 hours.")
                    .accessibilityIdentifier("inbox.updateLater")
                Button("Update…") { updates.checkForUpdates() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updates.canCheck)
                    .accessibilityLabel("Update to version \(version)")
                    .accessibilityHint(updates.canCheck ? "Opens the updater, which asks before installing."
                                       : "Unavailable while an update check or install is in progress.")
                    .accessibilityIdentifier("inbox.updateInstall")
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Update available: Version \(version)")
            .accessibilityIdentifier("inbox.update")
        }
    }
}

/// #149: the menu-bar symbol, with a small dot at its top-right corner while an update is available.
/// #159: while the desktop pet is hidden, the pet's badge text follows the symbol. A template image, so
/// the menu bar tints symbol, dot and count together in light and dark. With a count the canvas has a
/// slot as wide as "99+", so the item keeps its width and baseline when the dot appears or the count
/// changes; with no count there is no slot, so the width changes only between none and some.
enum MenuBarIcon {
    static let countGap: CGFloat = 3

    private static func countAttributes(_ count: String) -> [NSAttributedString.Key: Any] {
        // The digits' weight on "?", whose glyph reads lighter at the same weight.
        let weight: NSFont.Weight = count == "?" ? .bold : .semibold
        return [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: weight), .foregroundColor: NSColor.black]
    }

    /// `count` is the pet's badge text (nil: no slot). `fitsCount` sizes the slot to the text instead of
    /// "99+", for the Demo item whose "DEMO" follows the image and would otherwise sit after a hole.
    static func image(symbol: String, dot: Bool, count: String? = nil, fitsCount: Bool = false) -> NSImage {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)) ?? NSImage()
        let diameter: CGFloat = 4.5, gap: CGFloat = 0.75
        let text = count.map { NSAttributedString(string: $0, attributes: countAttributes($0)) }
        let slotText = fitsCount ? text : text.map { _ in NSAttributedString(string: "99+", attributes: countAttributes("9")) }
        let slot = slotText.map { ceil($0.size().width) + countGap } ?? 0
        let size = NSSize(width: base.size.width + slot, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: CGRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
            if let text {
                // Centered in the item; in the Demo text run the image sits on the baseline, so the count
                // does too, level with "DEMO".
                let y = fitsCount ? (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).map(\.descender)!
                                  : (rect.height - text.size().height) / 2
                text.draw(at: CGPoint(x: base.size.width + countGap, y: y))
            }
            guard dot else { return true }
            // Inside the symbol's top-right corner; a cleared ring bites into the glyph so the dot reads apart.
            let dotRect = CGRect(x: base.size.width - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -gap, dy: -gap)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
