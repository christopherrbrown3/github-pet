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
    func checkForUpdates()
}

/// Update state for the menu and Settings. Sparkle owns checking, downloading, verification and
/// installation, and shows its own windows; nothing here touches the inbox, its badge or the mascot.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    let installed: InstalledBuild
    let configuration: UpdateConfiguration
    private let preferences: UpdatePreferences
    private var backend: (any UpdaterBackend)?
    private var observers: [AnyCancellable] = []

    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticInstall = false
    @Published private(set) var lastCheck: Date?
    /// Set by a scheduled check that found an update while the user wasn't asking: shown quietly in
    /// the menu instead of Sparkle opening a window on top of their work.
    @Published private(set) var pendingVersion: String?
    /// A verified update that Sparkle will install when GitHub Pet quits (silent install is on).
    @Published private(set) var readyVersion: String?
    @Published var betaOptIn: Bool { didSet { if betaOptIn != oldValue { preferences.betaOptIn = betaOptIn } } }

    /// `backend` is nil when the build isn't configured or must not start an updater.
    init(installed: InstalledBuild, configuration: UpdateConfiguration, defaults: UserDefaults,
         backend: (any UpdaterBackend)?) {
        self.installed = installed
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
    func checkForUpdates() { controller.updater.checkForUpdates() }

    // SPUUpdaterDelegate: beta only for a prerelease build or an opted-in user; stable users are never moved.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { channels() }
    }

    // SPUStandardUserDriverDelegate: a scheduled (background) check must not pop a window over the
    // user's work. Sparkle waits, we show a quiet line in the menu, and "Check for Updates…" opens it.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
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
                        .accessibilityHint(updates.canCheck ? "" : "Unavailable while an update check is running.")
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
            Text("Updates are checked and installed by Sparkle and verified with GitHub Pet's update signing key. Builds are ad-hoc signed and not notarized, so the first install still needs Open Anyway in System Settings. Updates need no sign-in or token. Nothing is installed without your OK unless you turn automatic install on.")
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
                                   : updates.isAvailable ? "Unavailable while an update check is running." : "Updates are not configured in this build.")
                .accessibilityIdentifier("menu.checkForUpdates")
            Spacer()
            if let version = updates.readyVersion {
                Text("Version \(version) installs on quit").foregroundStyle(.secondary)
            } else if let version = updates.pendingVersion {
                Text("Version \(version) available").foregroundStyle(.secondary)
            } else if !updates.isAvailable {
                Text("Updates not configured").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}
