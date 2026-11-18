import CryptoKit
import Foundation

/// Last known quality of a source, persisted without any message text. Only the complete
/// qualities can make the first snapshot after a relaunch comparable.
public enum SourceQuality: String, Codable, Sendable {
    case loading, ready, empty, hiddenOnly, partial, stale, ghMissing, unauthenticated, error

    public init(_ state: DataState) {
        switch state {
        case .loading: self = .loading
        case .ready: self = .ready
        case .empty: self = .empty
        case .hiddenOnly: self = .hiddenOnly
        case .partial: self = .partial
        case .stale: self = .stale
        case .ghMissing: self = .ghMissing
        case .unauthenticated: self = .unauthenticated
        case .error: self = .error
        }
    }

    /// Fresh and complete: the same condition the engine requires of the previous poll.
    public var isComplete: Bool { self == .ready || self == .empty || self == .hiddenOnly }
}

/// What a source/account/scope session has already seen, as sanitized digests (#12).
///
/// Never holds titles, repositories, URLs, bodies or tokens: item IDs are stored as truncated
/// SHA-256 digests, and the session key is a digest of the source, account node ID and scope.
public struct EventBaseline: Codable, Equatable, Sendable {
    public static let version = 1
    public static let maximumDigests = 1024

    public var version = EventBaseline.version
    /// `BaselineKey.value` of the session that produced this record.
    public var key: String
    /// Digests of seen stable IDs, oldest first (the tracker's eviction order).
    public var digests: [String]
    public var baselineEstablished: Bool
    public var quality: SourceQuality
    public var lastSuccess: Date?

    public init(key: String, digests: [String], baselineEstablished: Bool,
                quality: SourceQuality, lastSuccess: Date?) {
        self.key = key
        self.digests = digests
        self.baselineEstablished = baselineEstablished
        self.quality = quality
        self.lastSuccess = lastSuccess
    }

    /// 128-bit SHA-256 prefix of a stable ID, lowercase hex.
    public static func digest(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Structural checks beyond decoding; a record failing any of them is discarded.
    var isValid: Bool {
        version == Self.version && Self.isDigest(key) && digests.count <= Self.maximumDigests
            && digests.allSatisfy(Self.isDigest) && Set(digests).count == digests.count
            && (lastSuccess.map { $0.timeIntervalSince1970.isFinite } ?? true)
    }
}

/// Identifies one baseline session. Any change of source, account, scope or review reach changes the key, so
/// the previous record is discarded and the next complete snapshot re-baselines silently.
public struct BaselineKey: Equatable, Sendable {
    public let value: String

    public init(source: DataSourceMode, identity: ScopeIdentity, scope: MonitoringScope,
                assignmentMode: AssignmentMode = .all) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let scopeText = (try? encoder.encode(scope)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        // Existing records were all-mode and used the same search and fixture coverage.
        let reach = assignmentMode == .all ? "" : "\nassignment=\(assignmentMode.rawValue)"
        value = EventBaseline.digest("v\(EventBaseline.version)\nc\(ScopeQueryPlan.categoriesVersion)\n\(source.rawValue)\n\(identity.storageSuffix)\n\(scopeText)\(reach)")
    }
}

/// One record in the app's `UserDefaults` domain (the launch's suite, or a throwaway one).
/// A single slot: only the current session's baseline is ever kept.
public final class EventBaselineStore {
    public static let key = "GitHubPet.event-baseline.v1"
    public static let maximumRecordBytes = 64 * 1024
    /// A record whose only change is `lastSuccess` is rewritten at most this often (#60). The saved
    /// time can lag by up to this much, which only shortens the 24 h relaunch window (fail-safe).
    public static let lastSuccessRefreshInterval: TimeInterval = 10 * 60
    private let defaults: UserDefaults
    private var lastSaved: EventBaseline?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved baseline for `key`. A record for another session, or one that is corrupt,
    /// oversized or from another version, is removed and nil returned (fresh silent baseline).
    public func load(for key: BaselineKey) -> EventBaseline? {
        guard let object = defaults.object(forKey: Self.key) else { return nil }
        guard let data = object as? Data, data.count <= Self.maximumRecordBytes,
              let record = try? JSONDecoder().decode(EventBaseline.self, from: data),
              record.isValid, record.key == key.value else {
            reset()
            return nil
        }
        return record
    }

    public func save(_ baseline: EventBaseline) {
        guard baseline.isValid, let data = try? JSONEncoder().encode(baseline),
              data.count <= Self.maximumRecordBytes else { return }
        // Polls repeat every 30–120 s and each moves lastSuccess: write only when the content changes,
        // or when the saved success time is getting old.
        if let lastSaved, Self.sameContent(lastSaved, baseline) { return }
        defaults.set(data, forKey: Self.key)
        lastSaved = baseline
    }

    public func reset() {
        defaults.removeObject(forKey: Self.key)
        lastSaved = nil
    }

    static func sameContent(_ saved: EventBaseline, _ new: EventBaseline) -> Bool {
        var ignoringTime = new
        ignoringTime.lastSuccess = saved.lastSuccess
        guard ignoringTime == saved else { return false }
        switch (saved.lastSuccess, new.lastSuccess) {
        case (nil, nil): return true
        case (let old?, let current?): return current >= old && current.timeIntervalSince(old) < lastSuccessRefreshInterval
        default: return false
        }
    }
}
