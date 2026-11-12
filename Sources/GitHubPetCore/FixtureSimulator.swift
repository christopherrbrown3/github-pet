import Foundation

/// Offline data source for development and QA. Produces deterministic fixture snapshots
/// and lets the user inject events and simulate disconnects, partial data and recovery.
public final class FixtureSimulator {
    public private(set) var baseItems: [InboxItem]
    public private(set) var injected: [InboxItem] = []
    public private(set) var connected = true
    /// While on, every poll is partial (assigned-issue fixtures "unavailable"). Sticky, so the
    /// periodic fixture poll cannot silently flip the state back to complete.
    public var partialPolls = false
    private let makeID: () -> String

    public init(baseItems: [InboxItem] = FixtureSimulator.defaultItems(),
                makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.baseItems = baseItems
        self.makeID = makeID
    }

    /// The next poll result. Partial polls drop the assigned-issue fixtures.
    public func poll() -> FetchOutcome {
        guard connected else { return .failure(.failed("simulated disconnect")) }
        let all = baseItems + injected
        if partialPolls {
            return .snapshot(items: all.filter { $0.kind != .assignedIssue }, complete: false)
        }
        return .snapshot(items: all, complete: true)
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
            item(.assignedIssue, "example/pet-demo", 18, "Quiet hours should wrap midnight", 26),
        ]
    }
}
