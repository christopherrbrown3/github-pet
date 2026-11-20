import Foundation

/// Which releases an update check may offer. Stable never offers a prerelease; Beta offers the
/// newest of stable and prerelease.
public enum UpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable, beta

    /// Stable is the default for everyone, matching Sparkle's model. Beta is an explicit opt-in, so
    /// a check never moves a stable user to a prerelease, and a beta build isn't opted in silently.
    public static let `default`: UpdateChannel = .stable

    public var title: String {
        switch self {
        case .stable: return "Stable"
        case .beta: return "Beta"
        }
    }
}

/// What this copy of GitHub Pet knows about itself, from its Info.plist.
///
/// `VERSION` is MAJOR.MINOR.PATCH only, so a Beta build reports `0.1.0` even though its release
/// tag is `v0.1.0-beta.N`. Builds made for a release carry the full version in the optional
/// `GitHubPetReleaseVersion` key (set by `RELEASE_VERSION=… scripts/build-app.sh`). A build
/// without it ("untagged": every build before this key, and local or CI builds) is recognised by
/// its source revision when it matches a published release, and otherwise treated as older than
/// every release of its version, so it is offered the matching Beta or stable release.
public struct InstalledBuild: Equatable, Sendable {
    public var shortVersion: String
    public var buildNumber: String
    public var releaseVersion: SemanticVersion?
    public var revision: String?

    public init(shortVersion: String, buildNumber: String, releaseVersion: SemanticVersion? = nil, revision: String? = nil) {
        self.shortVersion = shortVersion; self.buildNumber = buildNumber
        self.releaseVersion = releaseVersion; self.revision = revision
    }

    public init(infoDictionary: [String: Any]?) {
        let info = infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let tag = (info["GitHubPetReleaseVersion"] as? String).flatMap(SemanticVersion.init)
        let revision = (info["GitHubPetSourceRevision"] as? String).flatMap { $0.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil ? $0 : nil }
        self.init(shortVersion: short, buildNumber: info["CFBundleVersion"] as? String ?? "?", releaseVersion: tag, revision: revision)
    }

    /// Display text such as `0.1.0-beta.3 (build 214)` or `0.1.0 (build 214, untagged)`.
    public var displayVersion: String {
        if let releaseVersion { return "\(releaseVersion) (build \(buildNumber))" }
        return "\(shortVersion) (build \(buildNumber), untagged)"
    }

    /// True for a build that is a prerelease or whose release is unknown (untagged). Such a build
    /// on the Stable channel is told, in the UI, that Beta is available to opt into.
    public var mayBePrerelease: Bool { releaseVersion?.isPrerelease ?? true }

    var baseline: SemanticVersion? {
        if let releaseVersion { return releaseVersion }
        guard let core = SemanticVersion("\(shortVersion)") else { return nil }
        // Older than every prerelease or release of this version.
        return SemanticVersion(major: core.major, minor: core.minor, patch: core.patch, prerelease: [.numeric(0)])
    }
}

public struct AvailableUpdate: Equatable, Sendable {
    public let version: SemanticVersion
    public let tag: String
    public let isPrerelease: Bool
    public let publishedAt: Date?
    /// Plain release notes cut to `UpdateChecker.notesLimit` characters.
    public let notes: String
    /// A validated https://github.com/<owner>/<repo>/releases/... page. Never an asset URL.
    public let url: URL
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(AvailableUpdate)
}

/// Why a check produced no answer. Never rendered as "up to date".
public enum UpdateCheckError: Error, Equatable, Sendable {
    case offline
    case timedOut
    case rateLimited(resetAt: Date?)
    case httpStatus(Int)
    case malformed
    case unexpectedResponse
    case tooLarge
    case network(String)

    public var message: String {
        switch self {
        case .offline: return "You appear to be offline."
        case .timedOut: return "GitHub didn't answer in time."
        case .rateLimited(let reset):
            if let reset { return "GitHub's request limit was reached. Try again after \(reset.formatted(date: .omitted, time: .shortened))." }
            return "GitHub's request limit was reached. Try again later."
        case .httpStatus(let code): return "GitHub answered with HTTP \(code)."
        case .malformed: return "GitHub's release list couldn't be read."
        case .unexpectedResponse: return "GitHub's reply wasn't what was expected."
        case .tooLarge: return "GitHub's reply was too large."
        case .network(let detail): return "Network problem: \(detail)."
        }
    }
}

/// A source of "is there a newer release?" answers. The UI depends only on this and the update-state
/// model, so a different mechanism (such as Sparkle in phase 2) can replace the GitHub list reader.
public protocol UpdateChecking: Sendable {
    func check(installed: InstalledBuild, channel: UpdateChannel) async -> Result<UpdateCheckResult, UpdateCheckError>
}

/// Reads the public, unauthenticated GitHub Releases list for GitHub Pet. No gh, no token, no
/// account access; `/releases/latest` is not used because it skips prereleases.
public struct UpdateChecker: UpdateChecking {
    public static let repository = "christopherrbrown3/github-pet"
    public static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
    public static let allowedHosts: Set<String> = ["api.github.com"]
    public static let defaultMaxBytes = 1024 * 1024
    public static let notesLimit = 600

    public let endpoint: URL
    public let maxBytes: Int
    private let transport: StatusTransport
    private let now: @Sendable () -> Date

    public init(endpoint: URL = UpdateChecker.endpoint, transport: StatusTransport? = nil,
                maxBytes: Int = UpdateChecker.defaultMaxBytes, timeout: TimeInterval = 15,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.maxBytes = maxBytes
        self.transport = transport ?? URLSessionStatusTransport(timeout: timeout)
        self.now = now
    }

    public func check(installed: InstalledBuild, channel: UpdateChannel) async -> Result<UpdateCheckResult, UpdateCheckError> {
        do {
            let data = try await fetch()
            return .success(try Self.evaluate(data, installed: installed, channel: channel))
        } catch let error as UpdateCheckError {
            return .failure(error)
        } catch {
            return .failure(.network("request failed"))
        }
    }

    func fetch() async throws -> Data {
        guard Self.hostAllowed(endpoint) else { throw UpdateCheckError.unexpectedResponse }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitHubPet-update-check", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.get(request, maxBytes: maxBytes)
        } catch let error as StatusFetchError {
            switch error {
            case .tooLarge: throw UpdateCheckError.tooLarge
            case .timedOut: throw UpdateCheckError.timedOut
            case .offline: throw UpdateCheckError.offline
            default: throw UpdateCheckError.unexpectedResponse
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw UpdateCheckError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: throw UpdateCheckError.offline
            default: throw UpdateCheckError.network("error \(error.code.rawValue)")
            }
        }
        guard Self.hostAllowed(response.url ?? endpoint) else { throw UpdateCheckError.unexpectedResponse }
        if response.statusCode == 429 || response.statusCode == 403, let limited = rateLimit(response) { throw limited }
        guard response.statusCode == 200 else { throw UpdateCheckError.httpStatus(response.statusCode) }
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard type == "application/json" else { throw UpdateCheckError.unexpectedResponse }
        guard data.count <= maxBytes else { throw UpdateCheckError.tooLarge }
        return data
    }

    /// 429, or 403 with an exhausted quota or Retry-After, is rate limiting; other 403s are plain HTTP errors.
    private func rateLimit(_ response: HTTPURLResponse) -> UpdateCheckError? {
        let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining")
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        guard response.statusCode == 429 || remaining == "0" || retryAfter != nil else { return nil }
        var reset: Date?
        if let epoch = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init), epoch > 0 {
            reset = Date(timeIntervalSince1970: epoch)
        } else if let retryAfter {
            reset = now().addingTimeInterval(retryAfter)
        }
        return .rateLimited(resetAt: reset)
    }

    static func hostAllowed(_ url: URL?) -> Bool {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              let host = c.host, allowedHosts.contains(host), c.user == nil, c.password == nil,
              c.port == nil || c.port == 443 else { return false }
        return true
    }

    // MARK: Evaluation (pure)

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: String
        let published_at: String?
        let body: String?
        let target_commitish: String?
    }

    public static func evaluate(_ data: Data, installed: InstalledBuild, channel: UpdateChannel) throws -> UpdateCheckResult {
        let releases: [Release]
        do { releases = try JSONDecoder().decode([Release].self, from: data) } catch { throw UpdateCheckError.malformed }
        let published = releases.filter { !$0.draft }
        var valid: [(Release, AvailableUpdate)] = []
        for release in published {
            guard let update = validated(release) else { continue }
            valid.append((release, update))
        }
        // Releases existed but none could be trusted: that is a failure, not "no update".
        if !published.isEmpty && valid.isEmpty { throw UpdateCheckError.malformed }

        var baseline = installed.baseline
        if installed.releaseVersion == nil, let revision = installed.revision,
           let match = valid.first(where: { $0.0.target_commitish?.lowercased().hasPrefix(revision.lowercased()) == true || revision.lowercased().hasPrefix($0.0.target_commitish?.lowercased() ?? "\u{0}") }) {
            baseline = match.1.version
        }
        guard let baseline else { throw UpdateCheckError.malformed }
        let eligible = valid.map(\.1).filter { channel == .beta || !$0.isPrerelease }
        guard let newest = eligible.max(by: { SemanticVersion.isOrdered($0.version, before: $1.version) }),
              SemanticVersion.isOrdered(baseline, before: newest.version) else { return .upToDate }
        return .available(newest)
    }

    private static func validated(_ release: Release) -> AvailableUpdate? {
        guard let version = SemanticVersion(release.tag_name),
              release.tag_name.hasPrefix("v"),
              // The API's flag and the tag must agree, or the metadata can't be trusted.
              release.prerelease == version.isPrerelease,
              let url = URL(string: release.html_url), SafeLink.validated(url) != nil,
              url.path.hasPrefix("/\(repository)/releases/") else { return nil }
        let date = release.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return AvailableUpdate(version: version, tag: release.tag_name, isPrerelease: version.isPrerelease,
                               publishedAt: date, notes: shortNotes(release.body ?? ""), url: url)
    }

    static func shortNotes(_ body: String) -> String {
        let lines = body.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "**", with: "") }
        let text = lines.joined(separator: "\n")
        guard text.count > notesLimit else { return text }
        return String(text.prefix(notesLimit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Per-user update preferences, kept apart from `PetSettings` so a settings reset or schema change
/// never touches them. Local only.
public struct UpdatePreferences {
    public static let channelKey = "update.channel"
    public static let autoCheckKey = "update.autoCheck"
    public static let lastCheckKey = "update.lastCheck"
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// nil until the user picks one; `UpdateChannel.default` applies until then.
    public var channel: UpdateChannel? {
        get { defaults.string(forKey: Self.channelKey).flatMap(UpdateChannel.init) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: Self.channelKey) }
    }
    public var autoCheck: Bool {
        get { defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.autoCheckKey) }
    }
    public var lastCheck: Date? {
        get { defaults.object(forKey: Self.lastCheckKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastCheckKey) }
    }

    public func isDue(now: Date) -> Bool {
        guard autoCheck else { return false }
        guard let last = lastCheck else { return true }
        return now.timeIntervalSince(last) >= Self.checkInterval || last > now
    }
}
