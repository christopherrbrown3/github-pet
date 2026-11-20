import AppKit
import GitHubPetCore
import SwiftUI

/// State behind "Check for Updates…" and the update section in Settings. Separate from the GitHub
/// activity inbox and its badge: nothing here touches items, counts or the mascot.
@MainActor
final class UpdateModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case failed(UpdateCheckError)

        /// Stable name for QA records.
        var name: String {
            switch self {
            case .idle: return "never-checked"
            case .checking: return "checking"
            case .upToDate: return "up-to-date"
            case .available: return "update-available"
            case .failed: return "error"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCheck: Date?
    @Published var channel: UpdateChannel { didSet { if channel != oldValue { channelChosen(channel) } } }
    @Published var autoCheck: Bool { didSet { preferences.autoCheck = autoCheck; if autoCheck { checkIfDue() } } }
    let installed: InstalledBuild
    /// Where the Download button went last (QA reads this; tests inject an opener).
    private(set) var lastOpenedURL: URL?

    private let preferences: UpdatePreferences
    private var checker: any UpdateChecking
    private let now: () -> Date
    private let opener: (URL) -> Void
    private var task: Task<Void, Never>?
    private var timer: Timer?

    init(installed: InstalledBuild, defaults: UserDefaults, checker: any UpdateChecking, now: @escaping () -> Date = Date.init,
         opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.installed = installed
        self.preferences = UpdatePreferences(defaults: defaults)
        self.checker = checker
        self.now = now
        self.opener = opener
        channel = preferences.channel ?? UpdateChannel.default
        autoCheck = preferences.autoCheck
        lastCheck = preferences.lastCheck
    }

    static func fixtureChecker(_ fixture: UpdateFixture) -> any UpdateChecking {
        UpdateChecker(transport: fixture.transport)
    }

    /// QA only: swap the offline fixture the next check reads.
    func useFixture(_ fixture: UpdateFixture) { checker = Self.fixtureChecker(fixture) }

    var isChecking: Bool { status == .checking }

    /// The selected channel is a user choice from now on, so it sticks even if it equals the default.
    private func channelChosen(_ channel: UpdateChannel) {
        preferences.channel = channel
        // A result for another channel says nothing about this one.
        if status != .checking { status = .idle }
    }

    /// Starts a check unless one is running. Returns the task so callers can await the outcome.
    @discardableResult
    func checkNow() -> Task<Void, Never> {
        if let task, status == .checking { return task }
        status = .checking
        let installed = installed, channel = channel, checker = checker
        let started = Task { [weak self] in
            let result = await checker.check(installed: installed, channel: channel)
            guard let self, !Task.isCancelled else { return }
            self.finish(result, channel: channel)
        }
        task = started
        return started
    }

    private func finish(_ result: Result<UpdateCheckResult, UpdateCheckError>, channel checked: UpdateChannel) {
        // The channel changed mid-flight: discard rather than show the wrong channel's answer.
        guard checked == channel else { status = .idle; return }
        lastCheck = now()
        // A failure still counts as an attempt, so a broken network is retried daily, not every launch.
        preferences.lastCheck = lastCheck
        switch result {
        case .success(.upToDate): status = .upToDate
        case .success(.available(let update)): status = .available(update)
        case .failure(let error): status = .failed(error)
        }
    }

    /// Launch and hourly gate for the optional automatic check: at most once per 24 hours, silent.
    func checkIfDue() {
        guard preferences.isDue(now: now()), status != .checking else { return }
        checkNow()
    }

    func startPeriodicChecks() {
        checkIfDue()
        timer?.invalidate()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Opens the release page through the same SafeLink gate as every other link.
    @discardableResult
    func openDownloadPage() -> Bool {
        guard case .available(let update) = status, let url = SafeLink.validated(update.url) else { return false }
        lastOpenedURL = url
        opener(url)
        return true
    }

    /// Opens Settings at the update section so the menu command has somewhere to show its result.
    func checkFromMenu(model: AppModel) {
        checkNow()
        WindowPresenter.shared.showSettings(model: model)
    }
}

/// One line per state for the UI and for QA records.
extension UpdateModel {
    var summary: String {
        switch status {
        case .idle: return "Not checked yet."
        case .checking: return "Checking for updates…"
        case .upToDate: return "You're up to date (\(channel.title) channel)."
        case .available(let update): return "Version \(update.version) is available."
        case .failed(let error): return "Couldn't check for updates. \(error.message)"
        }
    }
}

struct UpdateStatusSection: View {
    @ObservedObject var updates: UpdateModel

    var body: some View {
        Section("Software updates") {
            LabeledContent("Installed", value: updates.installed.displayVersion)
            LabeledContent("Last checked", value: updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
            statusRow
            if case .available(let update) = updates.status { details(update) }
            Picker("Channel", selection: $updates.channel) {
                ForEach(UpdateChannel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings.updateChannel")
            Toggle("Check automatically once a day", isOn: $updates.autoCheck)
                .accessibilityIdentifier("settings.updateAutoCheck")
            if updates.channel == .stable && updates.installed.mayBePrerelease {
                Text("This is a beta build, and every release so far is a beta. Choose Beta to be told about beta releases.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.updateBetaHint")
            }
            Text("Checks read GitHub's public release list. No sign-in or token is used. GitHub Pet doesn't download or install updates itself yet: it opens the release page, where you download the new version and replace the app. Automatic installation waits on trusted distribution (#89).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        HStack {
            if updates.isChecking { ProgressView().controlSize(.small) }
            Text(updates.summary)
                .foregroundStyle(isFailure ? Color.orange : Color.primary)
                .accessibilityIdentifier("settings.updateStatus")
            Spacer()
            Button(isFailure ? "Retry" : "Check for Updates…") { updates.checkNow() }
                .disabled(updates.isChecking)
                .accessibilityIdentifier("settings.updateCheck")
        }
    }

    private var isFailure: Bool {
        if case .failed = updates.status { return true }
        return false
    }

    private func details(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(update.isPrerelease ? "Beta" : "Stable") \(update.version)"
                 + (update.publishedAt.map { ", published \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                .font(.subheadline.bold())
            if !update.notes.isEmpty {
                Text(update.notes).font(.caption).textSelection(.enabled)
            }
            Button("Download…") { updates.openDownloadPage() }
                .accessibilityIdentifier("settings.updateDownload")
            Text("Opens the release page on GitHub in your browser.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The menu-bar menu's update entry: a quiet one-liner, never a badge or alert.
struct UpdateMenuRow: View {
    let model: AppModel
    @ObservedObject var updates: UpdateModel

    var body: some View {
        HStack(spacing: 6) {
            Button(updates.isChecking ? "Checking…" : "Check for Updates…") { updates.checkFromMenu(model: model) }
                .disabled(updates.isChecking)
                .accessibilityIdentifier("menu.checkForUpdates")
            Spacer()
            if case .available(let update) = updates.status {
                Text("Version \(update.version) available").foregroundStyle(.secondary)
            } else if case .failed = updates.status {
                Text("Update check failed").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}
