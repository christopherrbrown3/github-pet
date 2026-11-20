import Foundation
import ServiceManagement

/// Whether the app is registered to open at login, as the system reports it.
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user still has to allow it in System Settings → General → Login Items.
    case requiresApproval
    /// macOS reports the app as unknown to its login-item service. Seen for every ad-hoc-signed build,
    /// in /Applications too. The cause is not proven; the signature is the leading suspect.
    case notFound

    public init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        case .notRegistered: self = .disabled
        @unknown default: self = .notFound
        }
    }

    /// Whether the app will open at the next login (or would, once approved).
    public var isRegistered: Bool { self == .enabled || self == .requiresApproval }

    /// One line for Settings; `nil` when nothing needs saying.
    public var explanation: String? {
        switch self {
        case .enabled, .disabled: return nil
        case .requiresApproval: return "Allow GitHub Pet in System Settings → General → Login Items."
        case .notFound:
            return "Open at login isn't available in this beta. macOS doesn't register ad-hoc-signed builds like this one as login items. You can add GitHub Pet yourself in System Settings → General → Login Items."
        }
    }

    /// Whether the Settings toggle may be used. `notFound` is off and disabled: nothing is attempted.
    public var allowsToggle: Bool { self != .notFound }

    /// Whether Settings should offer a button that opens the system Login Items pane.
    public var offersSystemSettings: Bool { self == .notFound }
}

/// The system calls behind the login item, so the logic around them is testable.
public protocol LoginItemBackend: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// `SMAppService.mainApp`. Ad-hoc-signed builds read `.notFound` (measured on macOS 27, in /Applications and
/// elsewhere); callers show whatever status the system reports and never register from `.notFound`.
public struct SystemLoginItemBackend: LoginItemBackend {
    public init() {}
    public var status: LoginItemStatus { LoginItemStatus(SMAppService.mainApp.status) }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// What a change attempt ended up as. `status` is always re-read from the system afterwards.
public struct LoginItemResult: Equatable, Sendable {
    public var status: LoginItemStatus
    /// The system's error text when register or unregister threw.
    public var failure: String?
}

/// Turns "open at login" on or off. The system owns the state (the user can also change it in
/// System Settings), so nothing is stored by the app: read `status` whenever it is shown.
public struct LoginItem: Sendable {
    public var backend: LoginItemBackend

    public init(backend: LoginItemBackend = SystemLoginItemBackend()) { self.backend = backend }

    public var status: LoginItemStatus { backend.status }

    /// Registers or unregisters only when the current status needs it, then reports the status the
    /// system now has. A throw is reported in `failure`, never raised. An item already waiting for
    /// approval is registered: enabling it again is pending approval, not another register().
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> LoginItemResult {
        let current = backend.status
        // The system doesn't know this build, so register() would only fail or do nothing useful.
        guard current.allowsToggle else { return LoginItemResult(status: current, failure: nil) }
        do {
            if enabled {
                if !current.isRegistered { try backend.register() }
            } else if current.isRegistered {
                try backend.unregister()
            }
            return LoginItemResult(status: backend.status, failure: nil)
        } catch {
            return LoginItemResult(status: backend.status, failure: error.localizedDescription)
        }
    }
}

/// The one system-settings page the app may open: Login Items. Kept apart from `SafeLink`, which
/// only ever allows github.com, and exact-match so nothing else can pass through it.
public enum SystemSettingsLink {
    public static let loginItems = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    public static func validated(_ url: URL?) -> URL? { url == loginItems ? loginItems : nil }
}
