import Foundation

/// Folds fetch outcomes into inbox state and reports genuinely new items.
///
/// Baseline rules (ported from the reference monitor):
/// - the first successful snapshot establishes the baseline and never produces events;
/// - unchanged polls never re-trigger, because each stable ID is reported at most once;
/// - a snapshot is only comparable if the previous state was a fresh, complete success,
///   so recovery from error, staleness or partial data records IDs silently (no replay);
/// - partial snapshots are never comparable.
public final class InboxEngine {
    public static let defaultStaleAfter: TimeInterval = 10 * 60

    public private(set) var items: [InboxItem] = []
    public private(set) var state: DataState = .loading
    public private(set) var lastSuccess: Date?
    public let staleAfter: TimeInterval

    private var tracker: EventTracker
    private var previousWasComparable = false

    public init(staleAfter: TimeInterval = InboxEngine.defaultStaleAfter, trackerCapacity: Int = 1024) {
        self.staleAfter = staleAfter
        self.tracker = EventTracker(capacity: trackerCapacity)
    }

    public var baselineEstablished: Bool { tracker.baselineEstablished }

    /// Apply one poll result; returns the new events, newest first.
    @discardableResult
    public func apply(_ outcome: FetchOutcome, now: Date) -> [InboxEvent] {
        switch outcome {
        case .failure(let failure):
            previousWasComparable = false
            switch failure {
            case .ghMissing: state = .ghMissing
            case .unauthenticated: state = .unauthenticated
            case .failed(let message): state = .error(message)
            }
            return []

        case .snapshot(let rawItems, let complete):
            let deduped = Self.dedupe(rawItems)
            let comparable = complete && previousWasComparable && tracker.baselineEstablished
            var events: [InboxEvent] = []
            if !tracker.baselineEstablished && complete {
                tracker.seed(deduped.map(\.id))
            } else {
                for item in deduped where tracker.observe(item.id, comparableSnapshot: comparable) {
                    events.append(InboxEvent(item: item))
                }
            }
            items = deduped
            lastSuccess = now
            state = complete ? (deduped.isEmpty ? .empty : .ready) : .partial
            previousWasComparable = complete
            return events
        }
    }

    /// Downgrade to `.stale` once the last success is too old. Returns true if state changed.
    @discardableResult
    public func refreshFreshness(now: Date) -> Bool {
        guard state.hasUsableItems, state != .stale, let lastSuccess else { return false }
        guard now.timeIntervalSince(lastSuccess) >= staleAfter else { return false }
        markStale()
        return true
    }

    /// Force the stale state (used by the fixture simulator and freshness checks).
    public func markStale() {
        guard state.hasUsableItems else { return }
        state = .stale
        previousWasComparable = false
    }

    /// Forget the baseline; the next complete snapshot re-seeds without events.
    public func resetBaseline() {
        tracker.reset()
        previousWasComparable = false
    }

    /// Keep one row per stable ID (the most recently updated), sorted newest first.
    public static func dedupe(_ items: [InboxItem]) -> [InboxItem] {
        var byID: [String: InboxItem] = [:]
        for item in items where !item.id.isEmpty {
            if let existing = byID[item.id], existing.updatedAt >= item.updatedAt { continue }
            byID[item.id] = item
        }
        return byID.values.sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id
        }
    }
}
