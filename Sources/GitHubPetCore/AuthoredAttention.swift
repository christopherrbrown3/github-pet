import Foundation
import CoreFoundation

/// Whether one of your open pull requests needs your action (#9), decided strictly from the
/// authored search row. `init` returns nil for any missing field or unknown value, so the row
/// is malformed and the poll Partial (fail-closed).
///
/// Needs action: changes requested, a merge conflict, or failing checks on the head commit
/// (the combined rollup: GraphQL can't ask a search row which checks are required).
/// Everything else, drafts, and conflict status GitHub is still computing (`UNKNOWN`) are
/// waiting: counted, never alerting. `UNKNOWN` is re-evaluated on the next poll.
///
/// Events (via `InboxItem.attentionKeys`): a PR announces when a reason is gained that was never
/// seen for it, or when checks fail on a new head commit. Losing a reason, or regaining one already
/// seen for the PR (changes requested or a conflict again, failing checks again on the same head),
/// never announces.
public enum AuthoredAttention: Equatable, Sendable {
    case waiting
    case needsAction([Reason])

    public enum Reason: Equatable, Sendable {
        case changesRequested
        case conflict
        /// Head commit OID: the same failure stays one event; a new failing commit is another.
        case checksFailing(String)

        public var text: String {
            switch self {
            case .changesRequested: return "Changes requested"
            case .conflict: return "Merge conflict"
            case .checksFailing: return "Checks failing"
            }
        }

        var idComponent: String {
            switch self {
            case .changesRequested: return "changes"
            case .conflict: return "conflict"
            case .checksFailing(let oid): return "checks@" + oid
            }
        }
    }

    private static let reviewDecisions: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"]
    private static let mergeables: Set<String> = ["MERGEABLE", "CONFLICTING", "UNKNOWN"]
    private static let rollupStates: Set<String> = ["EXPECTED", "ERROR", "FAILURE", "PENDING", "SUCCESS"]

    public init?(_ node: Any) {
        guard let row = node as? [String: Any],
              let draftValue = row["isDraft"] as? NSNumber, CFGetTypeID(draftValue) == CFBooleanGetTypeID(),
              let decisionValue = row["reviewDecision"],
              let mergeable = row["mergeable"] as? String, Self.mergeables.contains(mergeable),
              let commits = (row["commits"] as? [String: Any])?["nodes"] as? [Any], commits.count <= 1 else { return nil }
        let decision: String?
        if decisionValue is NSNull { decision = nil }
        else if let value = decisionValue as? String, Self.reviewDecisions.contains(value) { decision = value }
        else { return nil }
        var failingOID: String?
        if let first = commits.first {
            guard let commit = (first as? [String: Any])?["commit"] as? [String: Any],
                  let oid = commit["oid"] as? String, Self.isOID(oid),
                  let rollupValue = commit["statusCheckRollup"] else { return nil }
            if !(rollupValue is NSNull) {
                guard let state = (rollupValue as? [String: Any])?["state"] as? String,
                      Self.rollupStates.contains(state) else { return nil }
                if state == "FAILURE" || state == "ERROR" { failingOID = oid }
            }
        }
        if draftValue.boolValue { self = .waiting; return }
        var reasons: [Reason] = []
        if decision == "CHANGES_REQUESTED" { reasons.append(.changesRequested) }
        if mergeable == "CONFLICTING" { reasons.append(.conflict) }
        if let failingOID { reasons.append(.checksFailing(failingOID)) }
        self = reasons.isEmpty ? .waiting : .needsAction(reasons)
    }

    static func isOID(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
