import Foundation

/// Setup links offered when the GitHub CLI is missing or signed out (#52). The URLs are fixed
/// constants on `cli.github.com`; nothing here installs software, runs a command or takes input.
public enum GhSetupLink: Equatable, CaseIterable, Sendable {
    case getCLI
    case signIn

    public var title: String {
        switch self {
        case .getCLI: return "Get GitHub CLI"
        case .signIn: return "How to sign in"
        }
    }

    public var url: URL {
        switch self {
        case .getCLI: return GhSetup.installURL
        case .signIn: return GhSetup.signInURL
        }
    }

    /// What VoiceOver says after the title, so the destination is known before activating.
    public var accessibilityHint: String {
        switch self {
        case .getCLI: return "Opens cli.github.com in your browser"
        case .signIn: return "Opens the gh auth login manual in your browser"
        }
    }
}

public enum GhSetup {
    public static let host = "cli.github.com"
    public static let installURL = URL(string: "https://cli.github.com/")!
    public static let signInURL = URL(string: "https://cli.github.com/manual/gh_auth_login")!
    /// Offered to copy to the pasteboard only; the app never runs it.
    public static let signInCommand = "gh auth login"

    /// Links for a data state: only the two setup states have any.
    public static func links(for state: DataState) -> [GhSetupLink] {
        switch state {
        case .ghMissing: return [.getCLI]
        case .unauthenticated: return [.signIn]
        default: return []
        }
    }

    /// Command the "Copy command" button puts on the pasteboard, for the signed-out state only.
    public static func copyableCommand(for state: DataState) -> String? {
        state == .unauthenticated ? signInCommand : nil
    }

    /// Plain https on the CLI site's own host, without credentials or a custom port.
    public static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https" && components.host == host
            && components.user == nil && components.password == nil
            && (components.port == nil || components.port == 443)
    }
}
