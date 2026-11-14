import Foundation

/// The kind of thing that landed in the inbox.
public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case reviewRequest
    case assignedIssue
    case authoredPullRequest
    case ciFailure
    case entitlement
    /// A confirmed GitHub service incident from githubstatus.com (see `ServiceIncident`).
    case serviceIncident

    /// Generic label used whenever privacy mode hides repository and title.
    public var genericLabel: String {
        switch self {
        case .reviewRequest: return "Review request"
        case .assignedIssue: return "Assigned issue"
        case .authoredPullRequest: return "Your pull request"
        case .ciFailure: return "Workflow failure"
        case .entitlement: return "Entitlement update"
        case .serviceIncident: return "GitHub service incident"
        }
    }

    public var severity: EventSeverity {
        self == .ciFailure ? .critical : .actionable
    }
}

public enum EventSeverity: Int, Comparable, Codable, Sendable {
    case actionable = 1
    case critical = 2

    public static func < (lhs: EventSeverity, rhs: EventSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One inbox row. `id` must be stable across polls (for example `review:owner/repo#12`);
/// it is the only key used for dedupe and new-event detection.
public struct InboxItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var kind: ItemKind
    public var repository: String
    public var title: String
    public var url: URL?
    public var updatedAt: Date
    /// Invented fixture data. Always labelled "Demo", including in privacy mode.
    public var isDemo: Bool

    public init(id: String, kind: ItemKind, repository: String, title: String,
                url: URL?, updatedAt: Date, isDemo: Bool = false) {
        self.id = id
        self.kind = kind
        self.repository = repository
        self.title = title
        self.url = url
        self.updatedAt = updatedAt
        self.isDemo = isDemo
    }
}

/// Data quality of the inbox, mirroring the reference source states.
/// Only `ready` and `empty` mean the count is fully known.
public enum DataState: Equatable, Sendable {
    case loading
    case ready
    case empty
    case partial
    case stale
    case ghMissing
    case unauthenticated
    case error(String)

    public var countIsKnown: Bool { self == .ready || self == .empty }

    /// Whether items held in this state came from at least one successful fetch.
    public var hasUsableItems: Bool {
        switch self {
        case .ready, .empty, .partial, .stale: return true
        default: return false
        }
    }

    public var statusText: String {
        switch self {
        case .loading: return "Loading…"
        case .ready: return "Up to date"
        case .empty: return "All clear"
        case .partial: return "Partial data"
        case .stale: return "Stale"
        case .ghMissing: return "GitHub CLI not found"
        case .unauthenticated: return "Not signed in to GitHub CLI"
        case .error(let message): return "Error: \(message)"
        }
    }

    /// Setup guidance shown under the status line, if any.
    public var hint: String? {
        switch self {
        case .ghMissing: return "Install it with: brew install gh"
        case .unauthenticated: return "Run: gh auth login"
        default: return nil
        }
    }
}

/// Why a fetch did not produce a snapshot.
public enum FetchFailure: Equatable, Sendable {
    case ghMissing
    case unauthenticated
    case failed(String)
}

/// The result of one poll, from fixtures or from `gh`.
public enum FetchOutcome: Equatable, Sendable {
    /// `complete == false` means some sub-query failed; items are a lower bound.
    case snapshot(items: [InboxItem], complete: Bool)
    case failure(FetchFailure)
}

/// A newly observed item, reported at most once per stable ID.
public struct InboxEvent: Equatable, Sendable {
    public var item: InboxItem
    /// The kind's severity unless the source knows better (service incidents use their impact).
    public var severity: EventSeverity

    public init(item: InboxItem) {
        self.init(item: item, severity: item.kind.severity)
    }

    public init(item: InboxItem, severity: EventSeverity) {
        self.item = item
        self.severity = severity
    }
}
