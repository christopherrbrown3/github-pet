import Foundation

/// #8: repositories whose review requests are entitlement approvals. Entitlement PRs already
/// arrive as live review requests (review-requested:@me includes team requests), so there is no
/// new search and nothing is ever approved: a matching row only changes its icon and wording,
/// keeps its ID and opens the same pull request on GitHub. The list lives only in local settings.
public enum EntitlementRepositories {
    public static let maximum = 20

    public enum Problem: Error, Equatable, Sendable {
        case invalid, duplicate, limit
        public var message: String {
            switch self {
            case .invalid: return "Enter a repository as owner/name."
            case .duplicate: return "That repository is already listed."
            case .limit: return "Up to \(EntitlementRepositories.maximum) repositories."
            }
        }
    }

    /// Lowercased `owner/name`, or nil when it isn't a valid repository.
    public static func key(_ repository: String) -> String? {
        guard let target = try? MonitoringTarget(repository: repository), let name = target.name else { return nil }
        return "\(target.owner)/\(name)"
    }

    /// Valid entries only, deduped in order and bounded.
    public static func normalized(_ entries: [String]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for entry in entries {
            guard result.count < maximum, let key = key(entry), seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }

    public static func add(_ entry: String, to list: [String]) -> Result<[String], Problem> {
        guard let key = key(entry) else { return .failure(.invalid) }
        guard !list.contains(key) else { return .failure(.duplicate) }
        guard list.count < maximum else { return .failure(.limit) }
        return .success(list + [key])
    }

    public static func classify(_ item: InboxItem, repositories: Set<String>) -> InboxItem {
        guard item.kind == .reviewRequest, !repositories.isEmpty,
              let key = key(item.repository), repositories.contains(key) else { return item }
        var copy = item
        copy.kind = .entitlement
        return copy
    }
}
