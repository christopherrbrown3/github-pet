import Foundation

/// The one place that reads gh's exit status and stderr to say why a call failed (#7): CLI missing,
/// signed out, rate limited, token scope / SAML / 403 denial, or a transport problem. Every poller
/// and the scope editor call these instead of keeping their own copy of the wording. Raw stderr is
/// only ever matched here, never shown.
public enum GhFailure: Equatable, Sendable {
    case ghMissing, signedOut, rateLimited, accessDenied, transport

    /// Only the active account matters: without `--active`, `gh auth status` fails when any stored
    /// account on the host (e.g. an expired inactive one) is invalid.
    static let authStatusArguments = ["auth", "status", "--active", "--hostname", "github.com"]

    /// gh's own sign-in signals: exit 4, or text such as "gh auth login".
    static func isAuthFailure(_ result: CommandResult) -> Bool {
        if result.exitCode == 4 { return true }
        let text = result.stderrText.lowercased()
        return text.contains("not logged in") || text.contains("gh auth login")
            || text.contains("authentication required")
    }

    /// gh's sign-in signals plus GitHub's own 401 answer for a bad or expired token.
    static func isSignedOut(_ result: CommandResult) -> Bool {
        let message = result.stderrText.lowercased()
        return isAuthFailure(result) || message.contains("bad credentials") || message.contains("http 401")
    }

    static func isRateLimited(_ text: String) -> Bool { text.lowercased().contains("rate limit") }

    /// Scope, SAML/SSO and 403 wording from gh or GitHub. Check after rate limits, which are 403s too.
    static func deniesAccess(_ text: String) -> Bool {
        let message = text.lowercased()
        return ["http 403", "saml enforcement", "saml sso", "saml single sign-on", "single sign-on (sso)",
                "required scopes", "insufficient_scopes", "not been granted"]
            .contains(where: message.contains)
    }

    static func isNetwork(_ text: String) -> Bool {
        let message = text.lowercased()
        return ["network", "could not resolve", "connection", "timed out", "dial tcp"].contains(where: message.contains)
    }

    /// Classifies a failed `gh auth status` preflight. Rate limit, then denial, then network wording
    /// win over sign-in; exit 1 or sign-in wording means signed out; anything else is transport.
    static func classifyPreflight(_ result: CommandResult) -> GhFailure {
        if isRateLimited(result.stderrText) { return .rateLimited }
        if deniesAccess(result.stderrText) { return .accessDenied }
        if isNetwork(result.stderrText) { return .transport }
        return result.exitCode == 1 || isSignedOut(result) ? .signedOut : .transport
    }
}
