import Foundation
import GitHubPetCore

/// A row action must still belong to the source/account/scope that rendered it.
struct InboxDismissalContext: Equatable {
    let identity: ScopeIdentity
    let generation: Int
}

struct DismissedInboxRow: Equatable, Identifiable {
    let record: DismissedInboxItem
    let item: InboxItem?
    var id: String { record.id }
}

/// App-owned projection of the local store onto the current primary Inbox snapshot.
struct InboxDismissalState {
    private let store: InboxDismissalStore
    private var identity: ScopeIdentity?
    private var entries: [DismissedInboxItem] = []
    private var matchedItems: [String: InboxItem] = [:]
    private(set) var hiddenIDs: Set<String> = []
    private var lastItems: [InboxItem]?
    private(set) var canEdit = false
    private(set) var notice: String?

    init(defaults: UserDefaults) {
        store = InboxDismissalStore(defaults: defaults)
    }

    mutating func update(identity: ScopeIdentity?, items: [InboxItem]) {
        if self.identity != identity {
            self.identity = identity
            entries = []
            lastItems = nil
            notice = nil
            canEdit = false
            if let identity {
                do {
                    entries = Self.sorted(try store.load(for: identity))
                    canEdit = true
                } catch {
                    notice = "Saved dismissals couldn’t be read."
                }
            }
        }
        guard !entries.isEmpty else {
            matchedItems = [:]
            hiddenIDs = []
            lastItems = nil
            return
        }
        guard lastItems != items else { return }
        lastItems = items
        let digests = Set(entries.map(\.id))
        matchedItems = [:]
        hiddenIDs = []
        for item in items where DismissedInboxItem.supports(item.kind) {
            let digest = EventBaseline.digest(item.id)
            if digests.contains(digest) {
                matchedItems[digest] = item
                hiddenIDs.insert(item.id)
            }
        }
    }

    func rows(showCurrentItems: Bool, classify: (InboxItem) -> InboxItem) -> [DismissedInboxRow] {
        entries.map { entry in
            DismissedInboxRow(record: entry, item: showCurrentItems ? matchedItems[entry.id].map(classify) : nil)
        }
    }

    mutating func dismiss(_ item: InboxItem, at date: Date) -> Bool {
        guard canEdit, !hiddenIDs.contains(item.id),
              let entry = DismissedInboxItem(item: item, dismissedAt: date) else { return false }
        guard entries.count < InboxDismissalStore.capacity else {
            notice = "You’ve reached the dismissal limit. Restore an item to make room."
            return false
        }
        return save(entries + [entry])
    }

    mutating func restore(_ id: String) {
        guard canEdit, entries.contains(where: { $0.id == id }) else { return }
        _ = save(entries.filter { $0.id != id })
    }

    private mutating func save(_ updated: [DismissedInboxItem]) -> Bool {
        guard let identity else { return false }
        do {
            try store.save(updated, for: identity)
            entries = Self.sorted(updated)
            lastItems = nil
            notice = nil
            return true
        } catch {
            notice = "The dismissal change couldn’t be saved."
            return false
        }
    }

    private static func sorted(_ entries: [DismissedInboxItem]) -> [DismissedInboxItem] {
        entries.sorted {
            $0.dismissedAt == $1.dismissedAt ? $0.id < $1.id : $0.dismissedAt > $1.dismissedAt
        }
    }
}
