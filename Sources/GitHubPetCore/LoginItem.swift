import Foundation
import ServiceManagement

/// Whether the app is registered to open at login, as the system reports it.
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user still has to allow it in System Settings → General → Login Items.
    case requiresApproval
    /// The system cannot find the app to register (for example it runs from an unsupported location).
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
        case .notFound: return "macOS can't register this copy of GitHub Pet. Move it to Applications and try again."
        }
    }
}

/// The system calls behind the login item, so the logic around them is testable.
public protocol LoginItemBackend: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// `SMAppService.mainApp`. Behaviour for an ad-hoc-signed build (no Developer ID) is unproven until
/// it is exercised on real macOS; callers must show whatever status the system reports.
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
    /// system now has. A throw is reported in `failure`, never raised.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> LoginItemResult {
        let current = backend.status
        do {
            if enabled {
                if current != .enabled { try backend.register() }
            } else if current.isRegistered {
                try backend.unregister()
            }
            return LoginItemResult(status: backend.status, failure: nil)
        } catch {
            return LoginItemResult(status: backend.status, failure: error.localizedDescription)
        }
    }
}
