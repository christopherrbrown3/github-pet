import Foundation
import Testing
@testable import GitHubPetCore

/// #8: review requests from configured entitlement repositories show as entitlement approvals.
/// No new searches, no approval mutation: the row is the same review request and opens the PR.
@Suite struct EntitlementRepositoriesTests {
    private func item(_ kind: ItemKind, _ repo: String, id: String = "x") -> InboxItem {
        InboxItem(id: "\(kind.rawValue):\(id)", kind: kind, repository: repo, title: "t",
                  url: URL(string: "https://github.com/\(repo)/pull/1"), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func entriesAreNormalizedDedupedValidatedAndBounded() {
        let raw = ["  Example/Entitlements ", "example/entitlements", "not a repo", "org-only", "a/b/c", "", "Other/Access"]
            + (0..<30).map { "owner/repo\($0)" }
        let normalized = EntitlementRepositories.normalized(raw)
        #expect(Array(normalized.prefix(2)) == ["example/entitlements", "other/access"])
        #expect(normalized.count == EntitlementRepositories.maximum)
        #expect(EntitlementRepositories.add("Example/New", to: ["a/b"]) == .success(["a/b", "example/new"]))
        #expect(EntitlementRepositories.add("a/B", to: ["a/b"]) == .failure(.duplicate))
        #expect(EntitlementRepositories.add("nope", to: []) == .failure(.invalid))
        let full = (0..<EntitlementRepositories.maximum).map { "o/r\($0)" }
        #expect(EntitlementRepositories.add("o/more", to: full) == .failure(.limit))
    }

    @Test func onlyReviewRequestsFromListedRepositoriesAreClassified() {
        let repositories: Set<String> = ["example/entitlements"]
        let review = item(.reviewRequest, "Example/Entitlements")
        let classified = EntitlementRepositories.classify(review, repositories: repositories)
        #expect(classified.kind == .entitlement)
        #expect(classified.id == review.id && classified.url == review.url && classified.title == review.title,
                "same row identity and link: no new event, opens the same pull request")
        for other in [item(.reviewRequest, "example/other"), item(.assignedIssue, "example/entitlements"),
                      item(.ciFailure, "example/entitlements"), item(.reviewRequest, "not-a-repo")] {
            #expect(EntitlementRepositories.classify(other, repositories: repositories) == other)
        }
        #expect(EntitlementRepositories.classify(review, repositories: []) == review)
    }

    @Test func settingsKeepTheListLocallyAndOldSettingsDecodeEmpty() throws {
        let old = try JSONDecoder().decode(PetSettings.self, from: Data(#"{"schemaVersion":1,"privacyMode":false}"#.utf8))
        #expect(old.entitlementRepositories.isEmpty && !old.privacyMode)
        let hostile = try JSONDecoder().decode(PetSettings.self, from: Data(
            #"{"entitlementRepositories":["Example/Entitlements","bad entry","example/entitlements"]}"#.utf8))
        #expect(hostile.entitlementRepositories == ["example/entitlements"])
        let wrongType = try JSONDecoder().decode(PetSettings.self, from: Data(#"{"entitlementRepositories":"x","mascotSize":96}"#.utf8))
        #expect(wrongType.entitlementRepositories.isEmpty && wrongType.mascotSize == 96, "one bad field never resets the rest")
        var settings = PetSettings()
        settings.entitlementRepositories = ["example/entitlements"]
        let round = try JSONDecoder().decode(PetSettings.self, from: JSONEncoder().encode(settings))
        #expect(round == settings)
    }
}
