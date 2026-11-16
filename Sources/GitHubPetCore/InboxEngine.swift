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
    /// Matches hidden from the viewer in the last complete snapshot (0 otherwise). Informational.
    public private(set) var hiddenCount = 0
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
            hiddenCount = 0
            switch failure {
            case .ghMissing: state = .ghMissing
            case .unauthenticated: state = .unauthenticated
            case .failed(let message): state = .error(message)
            }
            return []

        case .snapshot(let rawItems, let complete, let hidden):
            let deduped = Self.dedupe(rawItems)
            // Comparable only against a fresh, complete previous success; checking the age here
            // keeps stale recovery silent regardless of freshness-timer ordering (e.g. after sleep).
            let fresh = lastSuccess.map { now.timeIntervalSince($0) < staleAfter && now >= $0 } ?? false
            let comparable = complete && previousWasComparable && fresh && tracker.baselineEstablished
            var events: [InboxEvent] = []
            if !tracker.baselineEstablished && complete {
                tracker.seed(deduped.map(\.id))
            } else {
                // Decide newness before recording anything, so eviction while recording this
                // snapshot can never make an existing or previously shown ID look new.
                let previousIDs = Set(items.map(\.id))
                let newItems = deduped.filter { !tracker.contains($0.id) && !previousIDs.contains($0.id) }
                for item in deduped { _ = tracker.observe(item.id, comparableSnapshot: false) }
                if comparable { events = newItems.map(InboxEvent.init(item:)) }
            }
            items = deduped
            lastSuccess = now
            // Hidden matches never make a snapshot Partial, and never let zero visible look all clear.
            hiddenCount = complete ? max(0, hidden) : 0
            state = complete ? (deduped.isEmpty ? (hiddenCount > 0 ? .hiddenOnly(hiddenCount) : .empty) : .ready) : .partial
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

    /// Forget everything from the current source: items, state, timestamps and baseline.
    /// Used when the data source changes so old rows are never shown as the new source's data.
    public func reset() {
        items = []
        state = .loading
        lastSuccess = nil
        hiddenCount = 0
        resetBaseline()
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
