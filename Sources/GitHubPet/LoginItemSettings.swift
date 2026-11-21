import AppKit
import Combine
import GitHubPetCore

/// Settings › "Open at login" (#15). macOS owns the state (the user can also change it in System
/// Settings), so this only reads it, except when the user flips the toggle. Without a backend
/// (simulated, snapshot, QA or test launches) the row says so and never touches the system.
@MainActor
final class LoginItemSettings: ObservableObject {
    /// `nil` until first read: the Settings row shows "Checking…" rather than guessing Off.
    @Published private(set) var status: LoginItemStatus?
    @Published private(set) var failure: String?
    private let item: LoginItem?
    /// The status the last failure was reported against; a later system change clears it.
    private var failedStatus: LoginItemStatus?

    private let openURL: (URL) -> Void

    /// `openURL` is injected so tests never open System Settings.
    init(backend: (any LoginItemBackend)?, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        item = backend.map { LoginItem(backend: $0) }
        self.openURL = openURL
    }

    var isAvailable: Bool { item != nil }

    /// Re-read the system's status (Settings appears, or the app becomes active again).
    func refresh() {
        guard let item else { return }
        let current = item.status
        status = current
        if failure != nil, current != failedStatus { failure = nil; failedStatus = nil }
    }

    /// The only path that changes the system state: the user flipped the toggle.
    func setEnabled(_ enabled: Bool) {
        guard let item else { return }
        let result = item.setEnabled(enabled)
        status = result.status
        failure = result.failure.map { _ in
            enabled ? "macOS didn't turn on open at login." : "macOS didn't turn off open at login."
        }
        failedStatus = result.failure == nil ? nil : result.status
    }

    var isOn: Bool { status?.isRegistered ?? false }
    /// The toggle works only once the status is known and the system supports this build.
    var canToggle: Bool { isAvailable && (status?.allowsToggle ?? false) }
    var offersSystemSettings: Bool { status?.offersSystemSettings ?? false }

    /// Opens System Settings › Login Items so the user can add the app themselves. Registers nothing.
    func openLoginItemsSettings() {
        guard let url = SystemSettingsLink.validated(SystemSettingsLink.loginItems) else { return }
        openURL(url)
    }

    /// One honest line: on, off, waiting for approval, unavailable, or the failure.
    var summary: String {
        guard isAvailable else { return "Not available in this launch (simulated, snapshot or test). Nothing was changed." }
        let state: String
        switch status {
        case nil: state = "Checking with macOS…"
        case .enabled?: state = "On: GitHub Pet opens when you log in."
        case .disabled?: state = "Off."
        case .requiresApproval?: state = "Pending approval. " + LoginItemStatus.requiresApproval.explanation!
        case .notFound?: state = "Unavailable. " + LoginItemStatus.notFound.explanation!
        }
        guard let failure else { return state }
        return failure + " Status now: " + state
    }
}
