import Foundation
import SwiftUI
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private final class FrozenBrowseClock: @unchecked Sendable {
    private let instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { instant }
}

/// #137: the Choose Repositories sheet's state, driven through the real AppModel in the offline
/// simulated launch (browse answers go through the production parsers). Waits are bounded
/// handshakes on observable state.
@Suite(.serialized) @MainActor struct ScopeBrowserTests {
    private final class Spoken { var messages: [String] = [] }

    private func model() -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        let clock = FrozenBrowseClock()
        let app = AppModel(options: options, runtime: AppModel.Runtime(now: { Date(timeIntervalSince1970: 1_763_208_000) },
            systemReducedMotion: { true }, schedulesTimers: false,
            repositoryBudget: { CommandBudget(timeout: 20, now: { clock.now() }) }, scopeSimulationHoldLimit: nil))
        app.scopeEditor.budget = { CommandBudget(timeout: 20, now: { clock.now() }) }
        app.scopeEditor.announce = { _ in }
        return app
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() && ContinuousClock.now < end { await Task.yield() }
        try #require(predicate(), "bounded simulated completion")
    }
    private func settled(_ app: AppModel) async throws {
        try await wait { app.simulatedScopeQuiescent && !app.repositoryFetchInFlight && !app.scopeEditor.validationInFlight }
    }
    private func browser(_ app: AppModel, _ spoken: Spoken = Spoken(), mode: ScopeBrowseFixture.Mode = .complete) async throws -> ScopeBrowser {
        try await settled(app)
        app.scopeAccessSimulation?.setBrowse(mode)
        // Start from an empty Selected draft (the simulated account has an active selection).
        app.scopeEditor.draft.rows.forEach { app.scopeEditor.remove($0.id) }
        let browser = app.makeScopeBrowser()
        browser.announce = { spoken.messages.append($0) }
        browser.sync()
        await browser.settle()
        return browser
    }
    private func open(_ browser: ScopeBrowser, _ login: String) async throws -> ScopeBrowseOwner {
        let owner = try #require(browser.owners.first { $0.login == login })
        browser.open(owner)
        await browser.settle()
        return owner
    }

    @Test func openingListsOwnersAndShowsYourAccountFirst() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        let spoken = Spoken()
        let browser = try await browser(app, spoken)
        #expect(browser.ownersPhase == .loaded)
        #expect(browser.owners.map(\.kind) == [.viewer, .shared] + Array(repeating: .organization, count: 5))
        let viewer = try #require(browser.owners.first)
        #expect(browser.pane == .owner(viewer.id) && browser.presentation(viewer) == .rows)
        // The three largest readable organizations are prefetched; the denied one is not.
        #expect(browser.state(try #require(browser.owners.first { $0.login == "demo-harbor" })).completion == .capped)
        #expect(browser.owners.first { $0.login == "demo-tidewater" }?.denied == true)
        #expect(spoken.messages.contains { $0.hasPrefix("Loaded 5 organizations") })
    }

    @Test func checkingRowsEditsTheDraftAndCancelRestoresIt() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        let browser = try await browser(app)
        let editor = app.scopeEditor, before = editor.snapshotDraft(), active = app.activeMonitoringScope
        let owner = try await open(browser, "demo-lumen-labs")
        let rows = browser.visibleRows(owner).rows
        browser.toggle(rows[0], true); browser.toggle(rows[1], true)
        #expect(editor.draft.mode == .selected && editor.draft.rows.count == 2)
        #expect(browser.isSelected(rows[0]) && browser.selectedRepositoryCount(owner) == 2)
        browser.toggle(rows[1], false)
        #expect(editor.draft.rows.map(\.text) == [rows[0].nameWithOwner])
        editor.restoreDraft(before)
        #expect(editor.snapshotDraft() == before && app.activeMonitoringScope == active, "Cancel restores; nothing applied")
    }

    @Test func allRepositoriesReplacesCoveredPicksAndUncheckDoesNotRestoreThem() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        let spoken = Spoken()
        let browser = try await browser(app, spoken)
        let editor = app.scopeEditor
        let owner = try await open(browser, "demo-lumen-labs")
        let rows = browser.visibleRows(owner).rows
        rows.prefix(3).forEach { browser.toggle($0, true) }
        #expect(browser.showsNudge(owner), "three picks in one organization suggest All repositories")
        browser.toggleAll(owner, true)
        #expect(editor.draft.rows.map(\.kind) == [.organization])
        #expect(rows.allSatisfy(browser.isCovered) && !browser.showsNudge(owner))
        #expect(editor.status?.contains("3 individually checked repositories are now covered") == true)
        browser.toggle(rows[0], false)
        #expect(editor.draft.rows.count == 1, "a covered row can't be unchecked on its own")
        browser.toggleAll(owner, false)
        #expect(editor.draft.rows.isEmpty, "previous individual picks are not restored")
    }

    @Test func applyInTheSheetCommitsAndReportsApplied() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        let browser = try await browser(app)
        let editor = app.scopeEditor
        let owner = try await open(browser, "demo-example-org")
        let row = try #require(browser.visibleRows(owner).rows.first)
        browser.toggle(row, true)
        #expect(editor.canApply)
        editor.apply()
        try await wait { editor.applyEvent != nil }
        #expect(editor.applyEvent?.outcome == .applied)
        #expect(app.activeMonitoringScope?.targets == [try #require(row.target)])
    }

    @Test func rejectedApplyReportsRejectedWithInlineProblems() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        _ = try await browser(app)
        let editor = app.scopeEditor
        editor.setMode(.selected)
        #expect(editor.addByName("not-demo/hidden") == nil)
        editor.apply()
        try await wait { editor.applyEvent != nil }
        #expect(editor.applyEvent?.outcome == .rejected)
        #expect(ScopeEntry.entries(editor).first?.problem == ScopeRowProblem.unavailable.message(for: .repository))
        #expect(ScopeEntry.entries(editor).first?.named == true)
    }

    @Test func everyFailureLooksDifferentFromEmpty() async throws {
        for mode in ScopeBrowseFixture.Mode.allCases {
            let app = model(); defer { app.cleanupScopeSimulation() }
            let browser = try await browser(app, mode: mode)
            switch mode {
            case .signedOut, .ghMissing:
                #expect(browser.ownersPhase == .failed(mode == .signedOut ? .signedOut : .ghMissing), "\(mode)")
                #expect(browser.owners.isEmpty && browser.pane == .browse)
            case .identityMismatch:
                #expect(browser.notice != nil && browser.owners.isEmpty, "never mixes accounts")
                #expect(browser.ownersPhase == .checkingAccount)
            default:
                let owner = try await open(browser, "demo-example-org")
                let presentation = browser.presentation(owner)
                let expected: [ScopeBrowseFixture.Mode: ScopeBrowser.Presentation] = [
                    .complete: .capped, .partial: .partial, .rateLimited: .rateLimited, .denied: .denied, .empty: .empty,
                ]
                #expect(presentation == expected[mode], "\(mode): \(presentation)")
                // The SSO-withheld organization is never empty in any mode.
                let withheld = try await open(browser, "demo-tidewater")
                #expect(browser.presentation(withheld) == .denied, "\(mode)")
            }
        }
        // Only a complete, error-free answer with zero rows is empty.
        let app = model(); defer { app.cleanupScopeSimulation() }
        let browser = try await browser(app)
        #expect(browser.presentation(try await open(browser, "demo-quiet-meadow")) == .empty)
    }

    /// QA (#141): an owners answer that names the viewer but carries an error (organizations
    /// missing or malformed, or another GraphQL error) keeps what loaded and warns; it never
    /// reads as "not a member of any organization".
    private struct PartialOwners: ScopeBrowsing {
        let failure: ScopeBrowseFailure
        let account: ScopeAccount
        func owners(_ plan: ScopeOwnersPlan, budget: CommandBudget) -> ScopeOwnersResult {
            ScopeOwnersResult(viewer: ScopeViewer(account: account, login: "demo-user"),
                              owners: [ScopeBrowseOwner(kind: .viewer, login: "demo-user", repositoryCount: 1),
                                       ScopeBrowseOwner(kind: .shared, login: "", repositoryCount: 0)],
                              failure: failure)
        }
        func repositories(_ plan: ScopeRepositoryPagePlan, budget: CommandBudget) -> ScopeRepositoryPage { .failed(failure) }
        func search(_ plan: ScopeRepositorySearchPlan, budget: CommandBudget) -> ScopeRepositoryPage { .failed(failure) }
    }

    @Test(arguments: [ScopeBrowseFailure.malformedResponse, .graphQLError])
    func partialOwnersAnswerWarnsInsteadOfLookingEmpty(_ failure: ScopeBrowseFailure) async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        let spoken = Spoken()
        let browser = ScopeBrowser(editor: app.scopeEditor, now: { app.clock() }) { identity in
            guard case .github(let account) = identity else { return PartialOwners(failure: failure, account: ScopeBrowser.demoAccount) }
            return PartialOwners(failure: failure, account: account)
        }
        browser.announce = { spoken.messages.append($0) }
        browser.sync()
        await browser.settle()
        #expect(browser.ownersPhase == .loaded && browser.organizations.isEmpty)
        #expect(browser.ownersWarning == failure, "the failure is kept, not dropped")
        #expect(spoken.messages.contains { $0.hasSuffix("Your organizations may be incomplete.") })
        #expect(!spoken.messages.contains { $0.hasPrefix("Loaded 0 organizations") })
        // Your own account's page failed too: that owner is a failure, never empty.
        let viewer = try #require(browser.owners.first)
        #expect(browser.presentation(viewer) != .empty)
        browser.loadOwners()
        #expect(browser.ownersWarning == nil, "Retry clears the warning until the answer arrives")
        await browser.settle()
        #expect(browser.ownersWarning == failure)
    }

    @Test func loadMoreAppendsThePageAndKeepsCursorOrder() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        let browser = try await browser(app)
        let owner = try await open(browser, "demo-example-org")
        #expect(browser.state(owner).repositories.count == 100 && browser.state(owner).cursor != nil)
        browser.loadPage(owner, more: true)
        await browser.settle()
        #expect(browser.state(owner).repositories.count == 200 && browser.presentation(owner) == .capped)
        browser.loadPage(owner, more: true)
        await browser.settle()
        #expect(browser.state(owner).repositories.count == 240 && browser.presentation(owner) == .rows)
        #expect(Set(browser.state(owner).repositories.map(\.id)).count == 240)
    }

    @Test func searchFiltersLoadedRowsAndServerSearchMergesTheRest() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        let browser = try await browser(app)
        let owner = try await open(browser, "demo-harbor")
        browser.searchText = "repo:other/x lantern"
        let local = browser.visibleRows(owner)
        #expect(!local.rows.isEmpty && local.rows.allSatisfy { $0.name.contains("lantern") })
        #expect(browser.canSearchServer(owner))
        browser.searchServer(owner)
        await browser.settle()
        let state = browser.state(owner)
        #expect(state.searchedTerm == "lantern" && state.searchFailure == nil)
        #expect(!state.searchResults.isEmpty && Set(state.searchResults.map(\.id)).isDisjoint(with: state.repositories.map(\.id)))
        browser.searchText = "is:pr"
        #expect(browser.visibleRows(owner).rows.isEmpty && !browser.canSearchServer(owner), "only qualifiers: nothing to match or send")
    }

    @Test func filtersHideArchivedAndForksAndSayHowMany() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        let browser = try await browser(app)
        let owner = try await open(browser, "demo-lumen-labs")
        let all = browser.state(owner).repositories
        let visible = browser.visibleRows(owner)
        #expect(visible.hiddenArchived == all.filter(\.isArchived).count && visible.rows.allSatisfy { !$0.isArchived })
        browser.hideForks = true
        #expect(browser.visibleRows(owner).rows.allSatisfy { !$0.isFork && !$0.isArchived })
        browser.hideArchived = false; browser.hideForks = false
        #expect(browser.visibleRows(owner).rows.count == all.count)
    }

    @Test func aLongSelectionIsNeverCappedByTheSheetAndApplies() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        let browser = try await browser(app)
        let editor = app.scopeEditor
        let owner = try await open(browser, "demo-example-org")
        browser.loadPage(owner, more: true)
        await browser.settle()
        let rows = browser.visibleRows(owner).rows.prefix(150)
        try #require(rows.count == 150)
        rows.forEach { browser.toggle($0, true) }
        #expect(editor.draft.rows.count == 150 && rows.allSatisfy(browser.isSelected))
        #expect(ScopeEntry.entries(editor).count == 150 && editor.canApply)
        editor.apply()
        try await wait { editor.applyEvent != nil }
        #expect(editor.applyEvent?.outcome == .applied)
        #expect(app.activeMonitoringScope?.targets.count == 150)
    }

    @Test func selectedListCountsEntriesHiddenBelowAtAnyLength() {
        for count in [0, 5, 6, 7, 150, 1_000] {
            let hidden = ScrollingEntryList<EmptyView>.hiddenBelow(count: count, rowHeight: 36, offset: 0, viewport: 216)
            #expect(hidden == max(0, count - 6), "\(count)")
        }
        let end = ScrollingEntryList<EmptyView>.hiddenBelow(count: 150, rowHeight: 36, offset: 36 * 144, viewport: 216)
        #expect(end == 0)
        let halfway = ScrollingEntryList<EmptyView>.hiddenBelow(count: 150, rowHeight: 36, offset: 18, viewport: 216)
        #expect(halfway == 144, "a half-shown row still counts as hidden")
    }

    @Test func addByNameDetectsKindAndLabelsTheEntry() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        _ = try await browser(app)
        let editor = app.scopeEditor
        #expect(ScopeEditor.nameKind("demo-partner/tools") == .repository && ScopeEditor.nameKind("demo-partner") == .organization)
        #expect(editor.addByNameProblem("org:demo is:pr") == .malformed)
        #expect(editor.addByName("demo-partner") == nil)
        #expect(editor.addByName("demo-partner") == .duplicate)
        let entry = try #require(ScopeEntry.entries(editor).first)
        #expect(entry.named && entry.kindLabel == "All repositories · added by name")
        #expect(entry.spoken == "demo-partner, All repositories, added by name")
    }
}
