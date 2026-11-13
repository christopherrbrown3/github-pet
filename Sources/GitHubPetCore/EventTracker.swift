import Foundation

/// Remembers which stable IDs have been seen so each one produces at most one event.
///
/// Semantics follow the reference monitor's tracker: the first observation of an ID is
/// recorded even when it cannot be reported, and an ID is only reported when the snapshot
/// is comparable to earlier data and a baseline exists. Capacity is bounded; IDs still
/// present in the latest snapshot are refreshed so they are evicted last.
public struct EventTracker: Sendable {
    public let capacity: Int
    public private(set) var baselineEstablished = false
    private var order: [String] = []
    private var known: Set<String> = []

    public init(capacity: Int = 1024) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { known.count }

    public func contains(_ id: String) -> Bool { known.contains(id) }

    /// Record `ids` and mark the baseline as established. IDs observed earlier (e.g. during
    /// partial polls before the first complete snapshot) are kept, so they never fire later;
    /// `reset()` is the only way to forget them (source or account change, baseline reset).
    public mutating func seed<S: Sequence>(_ ids: S) where S.Element == String {
        for id in ids where !id.isEmpty {
            if known.contains(id) { refresh(id) } else { remember(id) }
        }
        baselineEstablished = true
    }

    /// Record `id`; returns true only if it is new and reportable.
    public mutating func observe(_ id: String, comparableSnapshot: Bool) -> Bool {
        guard !id.isEmpty else { return false }
        if known.contains(id) {
            refresh(id)
            return false
        }
        remember(id)
        return comparableSnapshot && baselineEstablished
    }

    public mutating func reset() {
        order.removeAll()
        known.removeAll()
        baselineEstablished = false
    }

    private mutating func remember(_ id: String) {
        guard !id.isEmpty, !known.contains(id) else { return }
        if order.count >= capacity {
            let evicted = order.removeFirst()
            known.remove(evicted)
        }
        order.append(id)
        known.insert(id)
    }

    private mutating func refresh(_ id: String) {
        if let index = order.firstIndex(of: id) {
            order.remove(at: index)
            order.append(id)
        }
    }
}
