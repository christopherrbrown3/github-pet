import Foundation

/// The kind of thing that landed in the inbox.
public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case reviewRequest
    case assignedIssue
    case authoredPullRequest
    case ciFailure
    /// #10: a failing workflow on a watched repository's default branch that someone else
    /// triggered: actionable. One the viewer triggered is `ciFailure` (critical).
    case workflowFailure
    /// #10: a workflow run waiting for a deployment approval the viewer can give. Actionable;
    /// the row opens the run on GitHub, and GitHub Pet never approves.
    case deploymentApproval
    case entitlement
    /// A confirmed GitHub service incident from githubstatus.com (see `ServiceIncident`).
    case serviceIncident

    /// Generic label used whenever privacy mode hides repository and title.
    public var genericLabel: String {
        switch self {
        case .reviewRequest: return "Review request"
        case .assignedIssue: return "Assigned issue"
        case .authoredPullRequest: return "Your pull request"
        case .ciFailure, .workflowFailure: return "Workflow failure"
        case .deploymentApproval: return "Deployment approval"
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
    /// Why it needs you, e.g. "Changes requested, checks failing" (#9). Fixed wording, no names,
    /// so it stays visible in privacy mode.
    public var attention: String?
    /// Extra event keys besides `id` (#9): one per attention reason. The item is new when its ID
    /// is new or when it gains a key never seen before; losing keys never announces.
    public var attentionKeys: [String]

    public init(id: String, kind: ItemKind, repository: String, title: String,
                url: URL?, updatedAt: Date, isDemo: Bool = false, attention: String? = nil,
                attentionKeys: [String] = []) {
        self.id = id
        self.kind = kind
        self.repository = repository
        self.title = title
        self.url = url
        self.updatedAt = updatedAt
        self.isDemo = isDemo
        self.attention = attention
        self.attentionKeys = attentionKeys
    }
}

/// Data quality of the inbox, mirroring the reference source states.
/// Only `ready` and `empty` mean the count is fully known.
public enum DataState: Equatable, Sendable {
    case loading
    case ready
    case empty
    /// Complete, nothing visible, but GitHub counted this many matches the viewer can't see.
    /// Never the verified-empty "all clear" state.
    case hiddenOnly(Int)
    case partial
    case stale
    case ghMissing
    case unauthenticated
    case error(String)

    public var countIsKnown: Bool {
        switch self {
        case .ready, .empty, .hiddenOnly: return true
        default: return false
        }
    }

    /// Whether items held in this state came from at least one successful fetch.
    public var hasUsableItems: Bool {
        switch self {
        case .ready, .empty, .hiddenOnly, .partial, .stale: return true
        default: return false
        }
    }

    public var statusText: String {
        switch self {
        case .loading: return "Loading…"
        case .ready: return "Up to date"
        case .empty: return "All clear"
        case .hiddenOnly(let hidden): return "No visible items · " + HiddenResults.matchesHidden(hidden)
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

/// Wording for matches GitHub counted but the viewer can't see (#35). Counts only, no names.
public enum HiddenResults {
    public static func matchesHidden(_ count: Int) -> String {
        count == 1 ? "1 match hidden from your account" : "\(count) matches hidden from your account"
    }
    public static func notVisible(_ count: Int) -> String {
        count == 1 ? "1 matching item isn't visible to your account" : "\(count) matching items aren't visible to your account"
    }
}

/// Wording for your open PRs that need nothing from you (#9). Counts only, no names.
public enum AuthoredWaiting {
    /// Shown beside usable data only; a lower bound ("at least") while data is partial.
    public static func note(_ count: Int, dataState: DataState) -> String? {
        guard count > 0, dataState.hasUsableItems else { return nil }
        let prefix = dataState == .partial ? "At least " : ""
        let verb = count == 1 && prefix.isEmpty ? "is" : "are"
        return "\(prefix)\(count) of your pull requests \(verb) waiting on others or being checked by GitHub"
    }
}

/// The result of one poll, from fixtures or from `gh`.
public enum FetchOutcome: Equatable, Sendable {
    /// `complete == false` means some sub-query failed; items are a lower bound.
    /// `hidden` (only with `complete`): matches GitHub counted that the viewer can't see. They are
    /// informational, never a Partial result: the visible results are complete.
    case snapshot(items: [InboxItem], complete: Bool, hidden: Int = 0)
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
