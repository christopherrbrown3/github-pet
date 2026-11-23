import Foundation

/// Offline data source for development and QA. Produces deterministic fixture snapshots
/// and lets the user inject events and simulate disconnects, partial data and recovery.
public final class FixtureSimulator {
    private static let teamReviewID = "reviewRequest:example/pet-tools#7"
    public private(set) var baseItems: [InboxItem]
    public private(set) var injected: [InboxItem] = []
    /// Demo rows for the Waiting on others group (#148): never polled into the inbox itself.
    public private(set) var waitingItems: [InboxItem]
    public private(set) var connected = true
    /// While on, every poll is partial (assigned-issue fixtures "unavailable"). Sticky, so the
    /// periodic fixture poll cannot silently flip the state back to complete.
    public var partialPolls = false
    private let makeID: () -> String

    public init(baseItems: [InboxItem] = FixtureSimulator.defaultItems(),
                waitingItems: [InboxItem] = FixtureSimulator.defaultWaitingItems(),
                makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.baseItems = baseItems
        self.waitingItems = waitingItems
        self.makeID = makeID
    }

    /// The next poll result. Partial polls drop the assigned-issue fixtures.
    public func poll(assignmentMode: AssignmentMode = .all) -> FetchOutcome {
        guard connected else { return .failure(.failed("simulated disconnect")) }
        let all = baseItems + injected
        let matching = assignmentMode == .direct ? all.filter { $0.id != Self.teamReviewID } : all
        if partialPolls {
            return .snapshot(items: matching.filter { $0.kind != .assignedIssue }, complete: false)
        }
        return .snapshot(items: matching, complete: true)
    }

    /// Add one entitlement item with a never-before-used stable ID.
    @discardableResult
    public func injectEntitlementEvent(now: Date = Date()) -> InboxItem {
        let token = makeID()
        let item = InboxItem(id: "entitlement:fixture-\(token)", kind: .entitlement,
                             repository: "example/pet-demo",
                             title: "Fixture entitlement granted (\(token.prefix(8)))",
                             url: URL(string: "https://github.com/settings/copilot"),
                             updatedAt: now, isDemo: true)
        injected.append(item)
        return item
    }

    /// Add one workflow-failure item (critical severity → urgent mood) with a unique stable ID.
    @discardableResult
    public func injectWorkflowFailure(now: Date = Date()) -> InboxItem {
        let token = makeID()
        let item = InboxItem(id: "ciFailure:fixture-\(token)", kind: .ciFailure,
                             repository: "example/pet-demo",
                             title: "Fixture workflow failed (\(token.prefix(8)))",
                             url: URL(string: "https://github.com/example/pet-demo/actions"),
                             updatedAt: now, isDemo: true)
        injected.append(item)
        return item
    }

    /// Replace every fixture row, injected ones included (render hooks: an exact set of rows).
    public func replaceItems(_ items: [InboxItem]) {
        baseItems = items
        injected = []
    }

    /// Replace the Waiting on others rows (render hooks: an exact set of rows).
    public func replaceWaitingItems(_ items: [InboxItem]) {
        waitingItems = items
    }

    public func disconnect() { connected = false }
    public func reconnect() { connected = true }

    public static func defaultItems(reference: Date = Date(timeIntervalSince1970: 1_793_000_000)) -> [InboxItem] {
        func item(_ kind: ItemKind, _ repo: String, _ number: Int, _ title: String, _ hoursAgo: Double) -> InboxItem {
            let path = kind == .assignedIssue ? "issues" : "pull"
            return InboxItem(id: "\(kind.rawValue):\(repo)#\(number)", kind: kind, repository: repo,
                             title: title, url: URL(string: "https://github.com/\(repo)/\(path)/\(number)"),
                             updatedAt: reference.addingTimeInterval(-hoursAgo * 3600), isDemo: true)
        }
        return [
            item(.reviewRequest, "example/pet-demo", 42, "Add hover summary to mascot", 1),
            item(.reviewRequest, "example/pet-tools", 7, "Tighten link validation", 5),
            item(.assignedIssue, "example/pet-demo", 18, "Mascot position resets after a display change", 26),
        ]
    }

    /// Your pull requests and a deployment that need nothing from you (#148), with why each waits.
    public static func defaultWaitingItems(reference: Date = Date(timeIntervalSince1970: 1_793_000_000)) -> [InboxItem] {
        [
            InboxItem(id: "authoredPullRequest:example/pet-demo#57", kind: .authoredPullRequest, repository: "example/pet-demo",
                      title: "Animate the badge count change", url: URL(string: "https://github.com/example/pet-demo/pull/57"),
                      updatedAt: reference.addingTimeInterval(-2 * 3600), isDemo: true,
                      attention: [AuthoredAttention.WaitReason.reviewPending, .checksRunning].map(\.text).joined(separator: ", ")),
            InboxItem(id: "deploy:fixture-pet-site-4242", kind: .deploymentApproval, repository: "example/pet-site",
                      title: "Deploy site is waiting for deployment approval",
                      url: URL(string: "https://github.com/example/pet-site/actions/runs/4242"),
                      updatedAt: reference.addingTimeInterval(-4 * 3600), isDemo: true,
                      attention: DeploymentApprovals.waitingReason),
            InboxItem(id: "authoredPullRequest:example/pet-tools#12", kind: .authoredPullRequest, repository: "example/pet-tools",
                      title: "Fixture simulator presets", url: URL(string: "https://github.com/example/pet-tools/pull/12"),
                      updatedAt: reference.addingTimeInterval(-30 * 3600), isDemo: true,
                      attention: AuthoredAttention.WaitReason.draft.text),
        ]
    }
}
