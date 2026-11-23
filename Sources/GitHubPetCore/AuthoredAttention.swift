import Foundation
import CoreFoundation

/// Whether one of your open pull requests needs your action (#9), decided strictly from the
/// authored search row. `init` returns nil for any missing field or unknown value, so the row
/// is malformed and the poll Partial (fail-closed).
///
/// Needs action: changes requested, a merge conflict, or failing checks on the head commit
/// (the combined rollup: GraphQL can't ask a search row which checks are required).
/// Everything else, drafts, and conflict status GitHub is still computing (`UNKNOWN`) are
/// waiting: listed under Waiting on others with why where known (#148), never alerting.
/// `UNKNOWN` is re-evaluated on the next poll.
///
/// Stable reason keys record first gains. A changes-requested round also carries the visible
/// review's identity and submission date for chronological comparison by the inbox engine.
public enum AuthoredAttention: Equatable, Sendable {
    case waiting([WaitReason])
    case needsAction([Reason])

    /// Why a PR that needs nothing from you is waiting (#148), in display order. Fixed wording,
    /// no names, so it stays visible in privacy mode. A draft is only "Draft"; "Approved, ready
    /// to merge" only when nothing else is pending (it stays waiting: no alert change).
    public enum WaitReason: String, Equatable, Sendable {
        case draft, reviewPending, checksRunning, mergeabilityPending, approved

        public var text: String {
            switch self {
            case .draft: return "Draft"
            case .reviewPending: return "Review pending"
            case .checksRunning: return "Checks running"
            case .mergeabilityPending: return "Checking for conflicts"
            case .approved: return "Approved, ready to merge"
            }
        }

        /// Every reason in one sentence-case line, e.g. "Review pending, checks running".
        public static func summary(_ reasons: [WaitReason]) -> String? {
            guard let first = reasons.first else { return nil }
            return ([first.text] + reasons.dropFirst().map { $0.text.lowercased() }).joined(separator: ", ")
        }
    }

    public struct Review: Hashable, Codable, Sendable {
        let digest: String
        let submittedAt: Date?
    }

    public enum Reason: Equatable, Sendable {
        case changesRequested(review: Review?)
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

        var review: Review? {
            if case .changesRequested(let review) = self { return review }
            return nil
        }
    }

    private static let reviewDecisions: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"]
    private static let mergeables: Set<String> = ["MERGEABLE", "CONFLICTING", "UNKNOWN"]
    private static let rollupStates: Set<String> = ["EXPECTED", "ERROR", "FAILURE", "PENDING", "SUCCESS"]
    private static let reviewDatePattern = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|\+00:00)\z"#
    private static let wholeSeconds = Date.ISO8601FormatStyle()
    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func reviewDate(_ text: String) -> Date? {
        // DateTime is UTC. Foundation accepts a parsed prefix and normalizes invalid calendar
        // components, so check both the full input and the calendar before comparing rounds.
        guard text.utf8.count <= 35,
              text.range(of: reviewDatePattern, options: .regularExpression) != nil,
              let date = (try? fractionalSeconds.parse(text)) ?? (try? wholeSeconds.parse(text)),
              wholeSeconds.format(date).prefix(19) == text.prefix(19) else { return nil }
        return date
    }

    public init?(_ node: Any) {
        guard let row = node as? [String: Any],
              let draftValue = row["isDraft"] as? NSNumber, CFGetTypeID(draftValue) == CFBooleanGetTypeID(),
              let decisionValue = row["reviewDecision"],
              let mergeable = row["mergeable"] as? String, Self.mergeables.contains(mergeable),
              let commits = (row["commits"] as? [String: Any])?["nodes"] as? [Any], commits.count <= 1,
              let reviews = (row["reviews"] as? [String: Any])?["nodes"] as? [Any], reviews.count <= 1 else { return nil }
        var latestChangesReview: Review?
        if let first = reviews.first {
            guard let review = first as? [String: Any], let id = review["id"] as? String,
                  ScopeASCII.nodeID(id), let submission = review["submittedAt"] else { return nil }
            let submittedAt: Date?
            if submission is NSNull {
                submittedAt = nil
            } else {
                guard let text = submission as? String, let date = Self.reviewDate(text) else { return nil }
                submittedAt = date
            }
            latestChangesReview = Review(digest: EventBaseline.digest(id), submittedAt: submittedAt)
        }
        let decision: String?
        if decisionValue is NSNull { decision = nil }
        else if let value = decisionValue as? String, Self.reviewDecisions.contains(value) { decision = value }
        else { return nil }
        var failingOID: String?, checksRunning = false
        if let first = commits.first {
            guard let commit = (first as? [String: Any])?["commit"] as? [String: Any],
                  let oid = commit["oid"] as? String, Self.isOID(oid),
                  let rollupValue = commit["statusCheckRollup"] else { return nil }
            if !(rollupValue is NSNull) {
                guard let state = (rollupValue as? [String: Any])?["state"] as? String,
                      Self.rollupStates.contains(state) else { return nil }
                if state == "FAILURE" || state == "ERROR" { failingOID = oid }
                if state == "PENDING" || state == "EXPECTED" { checksRunning = true }
            }
        }
        if draftValue.boolValue { self = .waiting([.draft]); return }
        var reasons: [Reason] = []
        if decision == "CHANGES_REQUESTED" { reasons.append(.changesRequested(review: latestChangesReview)) }
        if mergeable == "CONFLICTING" { reasons.append(.conflict) }
        if let failingOID { reasons.append(.checksFailing(failingOID)) }
        guard reasons.isEmpty else { self = .needsAction(reasons); return }
        var waits: [WaitReason] = []
        if decision == "REVIEW_REQUIRED" { waits.append(.reviewPending) }
        if checksRunning { waits.append(.checksRunning) }
        if mergeable == "UNKNOWN" { waits.append(.mergeabilityPending) }
        if decision == "APPROVED" && waits.isEmpty { waits.append(.approved) }
        self = .waiting(waits)
    }

    static func isOID(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
