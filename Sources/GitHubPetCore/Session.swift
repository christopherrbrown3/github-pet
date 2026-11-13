import Foundation

/// Tracks which GitHub account the current session's data belongs to. `gh auth switch`
/// leaves the data-source mode unchanged, so the account itself must identify the session.
public struct AccountWatch: Equatable, Sendable {
    public private(set) var account: String?

    public init() {}

    /// Records the account a poll ran as. Returns true when it differs from the account the
    /// session's data came from, so the caller must start a fresh baseline before applying
    /// the poll. Polls that failed before identifying an account (nil) change nothing.
    public mutating func observe(_ newAccount: String?) -> Bool {
        guard let newAccount else { return false }
        defer { account = newAccount }
        return account != nil && account != newAccount
    }

    public mutating func reset() {
        account = nil
    }
}

/// Unread markers for inbox items. Events add markers; opening an item or the inbox removes
/// them. Markers for absent items are pruned only after a complete snapshot: a partial one
/// may just be missing a source that failed, and recovery never re-announces its items.
public struct UnseenItems: Equatable, Sendable {
    public private(set) var ids: Set<String> = []

    public init() {}

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    public mutating func record(_ events: [InboxEvent]) {
        for event in events { ids.insert(event.item.id) }
    }

    public mutating func reconcile(after outcome: FetchOutcome, items: [InboxItem]) {
        guard case .snapshot(_, complete: true) = outcome else { return }
        let present = Set(items.map(\.id))
        if !ids.isSubset(of: present) { ids.formIntersection(present) }
    }

    public mutating func remove(_ id: String) {
        ids.remove(id)
    }

    public mutating func removeAll() {
        ids.removeAll()
    }
}
