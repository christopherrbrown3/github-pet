import Foundation
import Testing
@testable import GitHubPetCore

@Suite struct InboxDismissalStoreTests {
    private let date = Date(timeIntervalSince1970: 1_763_208_000)

    private func item(_ id: String, kind: ItemKind = .reviewRequest) -> InboxItem {
        InboxItem(id: id, kind: kind, repository: "sample/repository", title: "Private fixture title",
                  url: URL(string: "https://github.com/sample/repository/pull/42"), updatedAt: date)
    }

    @Test func recordsUseStableIdentityAndOnlyMinimalMetadata() throws {
        let defaults = EphemeralDefaults(name: "dismissals.metadata")
        let store = InboxDismissalStore(defaults: defaults)
        var candidate = item("reviewRequest:PR_demo")
        let original = try #require(DismissedInboxItem(item: candidate, dismissedAt: date))
        candidate.title = "Updated title"
        candidate.updatedAt = date + 60
        candidate.attentionKeys = ["new-round"]
        candidate.kind = .entitlement
        let revision = try #require(DismissedInboxItem(item: candidate, dismissedAt: date + 60))
        #expect(original.id == revision.id)
        #expect(original.number == 42)

        try store.save([original], for: .demo)
        let data = try #require(defaults.data(forKey: InboxDismissalStore.key(for: .demo)))
        let payload = String(decoding: data, as: UTF8.self)
        for detail in ["Private fixture title", "sample", "github.com", "PR_demo", "https://", "new-round"] {
            #expect(!payload.contains(detail))
        }
        #expect(try InboxDismissalStore(defaults: defaults).load(for: .demo) == [original])
    }

    @Test func isolatesAccountsAndDemoAndRemovesEmptyRecord() throws {
        let defaults = EphemeralDefaults(name: "dismissals.identity")
        let store = InboxDismissalStore(defaults: defaults)
        let a = try ScopeIdentity.github(ScopeAccount(viewerID: "U_demo_A"))
        let b = try ScopeIdentity.github(ScopeAccount(viewerID: "U_demo_B"))
        let entry = try #require(DismissedInboxItem(item: item("shared"), dismissedAt: date))
        try store.save([entry], for: a)
        #expect(try store.load(for: a) == [entry])
        #expect(try store.load(for: b).isEmpty)
        #expect(try store.load(for: .demo).isEmpty)
        try store.save([entry], for: .demo)
        try store.save([], for: a)
        #expect(defaults.object(forKey: InboxDismissalStore.key(for: a)) == nil)
        #expect(try store.load(for: .demo) == [entry])
    }

    @Test func boundsRecordsWithoutEvictingExistingChoices() throws {
        let defaults = EphemeralDefaults(name: "dismissals.capacity")
        let store = InboxDismissalStore(defaults: defaults)
        let entries = try (0...InboxDismissalStore.capacity).map { index in
            try #require(DismissedInboxItem(item: item("reviewRequest:item-\(index)"), dismissedAt: date))
        }
        let atCapacity = Array(entries.dropLast())
        try store.save(atCapacity, for: .demo)
        #expect(throws: InboxDismissalStore.Failure.self) { try store.save(entries, for: .demo) }
        #expect(throws: InboxDismissalStore.Failure.self) { try store.save([entries[0], entries[0]], for: .demo) }
        #expect(try store.load(for: .demo) == atCapacity)
    }

    @Test func invalidStorageAndIndependentSourcesAreRejected() throws {
        let defaults = EphemeralDefaults(name: "dismissals.invalid")
        let store = InboxDismissalStore(defaults: defaults)
        let key = InboxDismissalStore.key(for: .demo)
        let invalid = Data(#"{"entries":[{"id":"raw-id","kind":"assignedIssue","dismissedAt":10}]}"#.utf8)
        defaults.set(invalid, forKey: key)
        #expect(throws: InboxDismissalStore.Failure.self) { try store.load(for: .demo) }
        #expect(defaults.data(forKey: key) == invalid)
        for kind in [ItemKind.ciFailure, .workflowFailure, .deploymentApproval, .serviceIncident] {
            #expect(DismissedInboxItem(item: item("independent-source", kind: kind), dismissedAt: date) == nil)
        }
    }
}
