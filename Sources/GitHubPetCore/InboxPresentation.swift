import Foundation

/// Inbox groups by meaning (#87). Display only: IDs, counts, events and the badge never change,
/// and no group implies that its items are urgent.
public enum InboxGroup: String, CaseIterable, Sendable {
    case failingWorkflows, approvals, reviewRequests, yourPullRequests, assignedIssues, incidents

    public init(kind: ItemKind) {
        switch kind {
        case .ciFailure, .workflowFailure: self = .failingWorkflows
        case .deploymentApproval, .entitlement: self = .approvals
        case .reviewRequest: self = .reviewRequests
        case .authoredPullRequest: self = .yourPullRequests
        case .assignedIssue: self = .assignedIssues
        case .serviceIncident: self = .incidents
        }
    }

    public var title: String {
        switch self {
        case .failingWorkflows: return "Failing workflows"
        case .approvals: return "Approvals"
        case .reviewRequests: return "Review requests"
        case .yourPullRequests: return "Your pull requests"
        case .assignedIssues: return "Assigned issues"
        case .incidents: return "GitHub incidents"
        }
    }

    /// Short count for the overview, e.g. "2 reviews".
    public func count(_ count: Int) -> String {
        let (one, many): (String, String)
        switch self {
        case .failingWorkflows: (one, many) = ("failing workflow", "failing workflows")
        case .approvals: (one, many) = ("approval", "approvals")
        case .reviewRequests: (one, many) = ("review", "reviews")
        case .yourPullRequests: (one, many) = ("authored PR", "authored PRs")
        case .assignedIssues: (one, many) = ("issue", "issues")
        case .incidents: (one, many) = ("incident", "incidents")
        }
        return "\(count) \(count == 1 ? one : many)"
    }
}

extension ItemKind {
    /// One SF Symbol per kind, used by every Inbox row.
    public var symbolName: String {
        switch self {
        case .reviewRequest: return "eye"
        case .assignedIssue: return "smallcircle.filled.circle"
        case .authoredPullRequest: return "arrow.triangle.pull"
        case .ciFailure, .workflowFailure: return "xmark.octagon"
        case .deploymentApproval: return "checkmark.shield"
        case .entitlement: return "key"
        case .serviceIncident: return "exclamationmark.icloud"
        }
    }
}

public struct InboxSection: Identifiable, Equatable, Sendable {
    public var group: InboxGroup
    public var items: [InboxItem]
    public var id: String { group.rawValue }
}

/// How faithful a source's data is right now. Only `healthy` may ever read as all clear or operational.
public enum SourceHealth: String, Equatable, Sendable {
    case healthy, loading, unknown, stale, partial, error

    public init(_ state: DataState) {
        switch state {
        case .ready, .empty, .hiddenOnly: self = .healthy
        case .loading: self = .loading
        // Without a working CLI we cannot know anything about the account.
        case .ghMissing, .unauthenticated: self = .unknown
        case .stale: self = .stale
        case .partial: self = .partial
        case .error: self = .error
        }
    }

    public init(_ state: ServiceStatusState) {
        switch state {
        case .operational, .incidents: self = .healthy
        case .loading: self = .loading
        case .stale: self = .stale
        case .error: self = .error
        }
    }

    public var label: String {
        switch self {
        case .healthy: return "Up to date"
        case .loading: return "Loading"
        case .unknown: return "Unknown"
        case .stale: return "Stale"
        case .partial: return "Partial"
        case .error: return "Error"
        }
    }
}

/// Visual weight of an overview tile. Words always carry the meaning; tone only supports it.
public enum InboxTone: String, Equatable, Sendable {
    case neutral, positive, caution, critical
}

/// The three overview tiles: Assigned to you, Waiting on others, GitHub status.
public struct InboxOverview: Equatable, Sendable {
    public struct Tile: Equatable, Sendable {
        public var title: String
        public var value: String
        public var detail: String
        public var tone: InboxTone
        public var accessibilityLabel: String { "\(title): \(value), \(detail)" }
    }

    public var assigned: Tile
    public var waiting: Tile
    public var status: Tile
    public var tiles: [Tile] { [assigned, waiting, status] }

    public init(dataState: DataState, items: [InboxItem], allDismissed: Bool = false,
                authoredWaiting: Int, deploymentsWaiting: Int, deploymentsComplete: Bool,
                serviceState: ServiceStatusState, incidents: [ServiceIncident]) {
        assigned = Self.assignedTile(dataState: dataState, items: items, allDismissed: allDismissed)
        waiting = Self.waitingTile(dataState: dataState, authored: authoredWaiting, deployments: deploymentsWaiting,
                                   deploymentsComplete: deploymentsComplete)
        status = Self.statusTile(serviceState, incidents: incidents)
    }

    /// The same count as the badge (never a second count), with a neutral breakdown.
    static func assignedTile(dataState: DataState, items: [InboxItem], allDismissed: Bool) -> Tile {
        let value = MascotPolicy.badge(dataState: dataState, count: items.count) ?? "0"
        let detail: String
        switch SourceHealth(dataState) {
        case .healthy:
            if case .hiddenOnly = dataState { detail = "Hidden from your account" }
            else if items.isEmpty { detail = allDismissed && dataState == .ready ? "All dismissed locally" : "Nothing needs you" }
            else { detail = breakdown(items) }
        case .partial: detail = "Some sources unavailable"
        case .stale: detail = "Last known, out of date"
        case .loading: detail = "Loading…"
        case .unknown: detail = "GitHub CLI needs setup"
        case .error: detail = "Couldn't update"
        }
        return Tile(title: "Assigned to you", value: value, detail: detail, tone: tone(SourceHealth(dataState)))
    }

    static func waitingTile(dataState: DataState, authored: Int, deployments: Int, deploymentsComplete: Bool) -> Tile {
        let health = SourceHealth(dataState)
        let total = max(0, authored) + max(0, deployments)
        let lowerBound = health == .partial || !deploymentsComplete
        var parts: [String] = []
        if authored > 0 { parts.append(authored == 1 ? "1 pull request" : "\(authored) pull requests") }
        if deployments > 0 { parts.append(deployments == 1 ? "1 deployment" : "\(deployments) deployments") }
        let value: String, detail: String
        switch health {
        case .healthy, .partial:
            value = "\(total)" + (lowerBound ? "+" : "")
            if lowerBound { detail = parts.isEmpty ? "Some sources unavailable" : "At least " + parts.joined(separator: " · ") }
            else { detail = parts.isEmpty ? "Nothing waiting" : parts.joined(separator: " · ") }
        case .stale:
            // Like the badge: a stale count is not current. The last known one is labelled as such.
            value = "?"
            detail = parts.isEmpty ? "Last known, out of date" : "Last known: " + parts.joined(separator: " · ")
        case .loading: value = "?"; detail = "Loading…"
        case .unknown, .error: value = "?"; detail = "Unknown"
        }
        let tone: InboxTone = health == .healthy && lowerBound ? .caution : (health == .healthy ? .neutral : Self.tone(health))
        return Tile(title: "Waiting on others", value: value, detail: detail, tone: tone == .critical ? .caution : tone)
    }

    /// Green "Operational" only for a fresh, verified success with no incidents.
    static func statusTile(_ state: ServiceStatusState, incidents: [ServiceIncident]) -> Tile {
        let title = "GitHub status"
        switch state {
        case .loading:
            return Tile(title: title, value: "Checking…", detail: "GitHub Status", tone: .neutral)
        case .operational:
            return Tile(title: title, value: "Operational", detail: "No active incidents", tone: .positive)
        case .incidents:
            let worst = incidents.map(\.impact).max()
            let value = incidents.count == 1 ? "1 incident" : "\(incidents.count) incidents"
            let tone: InboxTone = (worst?.severity ?? .actionable) == .critical ? .critical : .caution
            return Tile(title: title, value: value, detail: worst?.label ?? "Active", tone: tone)
        case .stale:
            return Tile(title: title, value: "Stale", detail: "Last check out of date", tone: .caution)
        case .error:
            return Tile(title: title, value: "Unavailable", detail: "Couldn't check", tone: .caution)
        }
    }

    static func breakdown(_ items: [InboxItem]) -> String {
        let sections = InboxPresentation.sections(items)
        let parts = sections.prefix(2).map { $0.group.count($0.items.count) }
        return parts.joined(separator: " · ") + (sections.count > 2 ? " · more" : "")
    }

    static func tone(_ health: SourceHealth) -> InboxTone {
        switch health {
        case .healthy, .loading: return .neutral
        case .partial, .stale: return .caution
        case .unknown, .error: return .critical
        }
    }
}

/// What the Inbox shows when no rows are visible. Only a verified, fresh, complete empty inbox is
/// `allClear`; every other state says what is (not) known.
public enum InboxEmptyState: Equatable, Sendable {
    case allClear
    case allDismissed
    case hiddenOnly(Int)
    case partial
    case stale
    case loading
    case setupNeeded
    case failed

    /// The dismissed message is only for a fresh, complete inbox that local dismissals emptied.
    /// A verified empty inbox is all clear; degraded states keep saying what isn't known, even
    /// when dismissals are also hiding rows.
    public init(dataState: DataState, allDismissed: Bool) {
        switch dataState {
        case .empty: self = .allClear
        case .ready: self = allDismissed ? .allDismissed : .allClear
        case .hiddenOnly(let hidden): self = .hiddenOnly(hidden)
        case .partial: self = .partial
        case .stale: self = .stale
        case .loading: self = .loading
        case .ghMissing, .unauthenticated: self = .setupNeeded
        case .error: self = .failed
        }
    }

    public var headline: String {
        switch self {
        case .allClear: return "All caught up"
        case .allDismissed: return "All current Inbox items are dismissed."
        case .hiddenOnly: return "No visible items"
        case .partial: return "No items in the sources that loaded."
        case .stale: return "No recent data"
        case .loading: return "Loading your Inbox…"
        case .setupNeeded: return "Can't check GitHub yet"
        case .failed: return "Couldn't load your Inbox"
        }
    }

    public var detail: String? {
        switch self {
        case .allClear: return "Nothing needs you right now."
        case .allDismissed: return "Dismissing only hides items here; GitHub is unchanged."
        case .hiddenOnly(let hidden): return HiddenResults.matchesHidden(hidden)
        case .partial: return "Some sources didn't load, so there may be more."
        case .stale: return "The last update is too old to say nothing needs you."
        case .loading: return nil
        case .setupNeeded: return "Set up GitHub CLI to see what needs you."
        case .failed: return "Nothing is known until the next successful update."
        }
    }

    /// Only the verified empty inbox shows the celebratory mascot pose.
    public var showsMascot: Bool { self == .allClear }

    public var symbolName: String? {
        switch self {
        case .allClear: return nil
        case .allDismissed: return "eye.slash"
        case .hiddenOnly: return "eye.slash"
        case .partial, .stale: return "exclamationmark.triangle"
        case .loading: return "hourglass"
        case .setupNeeded, .failed: return "xmark.octagon"
        }
    }
}

public enum InboxPresentation {
    /// Groups in display order; items keep their given (newest-first) order within a group.
    public static func sections(_ items: [InboxItem]) -> [InboxSection] {
        var byGroup: [InboxGroup: [InboxItem]] = [:]
        for item in items { byGroup[InboxGroup(kind: item.kind), default: []].append(item) }
        return InboxGroup.allCases.compactMap { group in
            byGroup[group].map { InboxSection(group: group, items: $0) }
        }
    }

    /// Row context under the title: Demo, the attention reason and the short repository,
    /// never the repository in privacy mode. Kind is carried by the group and symbol.
    public static func context(_ item: InboxItem, privacy: Bool) -> String {
        var parts: [String] = []
        if item.isDemo { parts.append(PrivacyText.demoLabel) }
        if let attention = item.attention { parts.append(attention) }
        if let repository = PrivacyText.repository(item, privacy: privacy) { parts.append(repository) }
        if parts.isEmpty || (parts == [PrivacyText.demoLabel]) { parts.append(item.kind.genericLabel) }
        return parts.joined(separator: " · ")
    }

    /// "Updated 10:42" from the last success; never claims an update that didn't happen.
    public static func updatedText(lastSuccess: Date?, dataState: DataState,
                                   format: (Date) -> String) -> String {
        guard let lastSuccess else {
            return dataState == .loading ? "Not updated yet" : "No successful update yet"
        }
        let time = format(lastSuccess)
        return SourceHealth(dataState) == .healthy ? "Updated \(time)" : "Last updated \(time)"
    }
}
