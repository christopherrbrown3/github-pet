import Foundation

/// Gatekeeper for every URL the app opens. Only plain HTTPS links to github.com pass.
public enum SafeLink {
    public static let allowedHosts: Set<String> = ["github.com"]

    public static func validated(_ url: URL?) -> URL? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              allowedHosts.contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else {
            return nil
        }
        return url
    }

    public static func validated(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == string, !string.contains(where: { $0.isNewline }) else { return nil }
        return validated(URL(string: string))
    }
}
