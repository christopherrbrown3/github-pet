import Foundation

/// What this copy of GitHub Pet knows about itself, from its Info.plist.
///
/// `VERSION` is MAJOR.MINOR.PATCH only, so a Beta build reports `0.1.0` even though its release tag
/// is `v0.1.0-beta.N`. Release builds are made with `RELEASE_VERSION=0.1.0-beta.N`, which adds the
/// full version as `GitHubPetReleaseVersion`. A build without it (local and CI builds) is treated
/// as a stable build: it is never moved to the beta channel on its own.
public struct InstalledBuild: Equatable, Sendable {
    public var shortVersion: String
    public var buildNumber: String
    public var releaseVersion: SemanticVersion?

    public init(shortVersion: String, buildNumber: String, releaseVersion: SemanticVersion? = nil) {
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
        self.releaseVersion = releaseVersion
    }

    public init(infoDictionary: [String: Any]?) {
        let info = infoDictionary ?? [:]
        self.init(shortVersion: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
                  buildNumber: info["CFBundleVersion"] as? String ?? "?",
                  releaseVersion: (info["GitHubPetReleaseVersion"] as? String).flatMap(SemanticVersion.init))
    }

    public var isPrerelease: Bool { releaseVersion?.isPrerelease ?? false }

    /// `0.1.0-beta.4 (build 214)`, or `0.1.0 (build 214)` for a build that doesn't record its tag.
    public var displayVersion: String { "\(releaseVersion?.description ?? shortVersion) (build \(buildNumber))" }
}

/// Which appcast channels Sparkle may offer. Items with no channel are stable and always allowed;
/// `beta` items are offered only to an installed prerelease build or a user who opted in.
public enum UpdateChannelPolicy {
    public static let beta = "beta"

    public static func allowedChannels(installed: InstalledBuild, optedInToBeta: Bool) -> Set<String> {
        installed.isPrerelease || optedInToBeta ? [beta] : []
    }
}

/// Whether this build may check for updates at all. A build without a valid feed URL and public
/// EdDSA key (such as a local or CI build before the release key exists) never starts the updater.
public struct UpdateConfiguration: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case configured
        case notConfigured(String)

        public var isConfigured: Bool { self == .configured }
    }

    public let feedURL: URL?
    public let publicKey: String?
    public let allowsAutomaticInstall: Bool

    public init(infoDictionary: [String: Any]?) {
        let info = infoDictionary ?? [:]
        feedURL = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        publicKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        allowsAutomaticInstall = info["SUAllowsAutomaticUpdates"] as? Bool ?? false
    }

    public var state: State {
        guard let feedURL, ["https", "http"].contains(feedURL.scheme?.lowercased()), feedURL.host != nil else {
            return .notConfigured("This build has no update feed.")
        }
        guard let publicKey, !publicKey.isEmpty else {
            return .notConfigured("Updates aren't set up in this build yet: it has no update signing key.")
        }
        // An EdDSA public key is 32 bytes. Anything else could never verify an update.
        guard let bytes = Data(base64Encoded: publicKey), bytes.count == 32 else {
            return .notConfigured("This build's update signing key isn't valid.")
        }
        return .configured
    }
}

/// The user's update choices that Sparkle doesn't store itself. Local only.
public struct UpdatePreferences {
    public static let betaOptInKey = "update.betaOptIn"
    public static let silentInstallOptInKey = "update.silentInstallOptIn"

    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// Set only by the Settings toggle for silent install. Sparkle's first-run prompt also has an
    /// "automatically download and install" checkbox; install stays user-confirmed unless this is on.
    public var silentInstallOptIn: Bool {
        get { defaults.bool(forKey: Self.silentInstallOptInKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.silentInstallOptInKey) }
    }

    public var betaOptIn: Bool {
        get { defaults.bool(forKey: Self.betaOptInKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.betaOptInKey) }
    }
}
