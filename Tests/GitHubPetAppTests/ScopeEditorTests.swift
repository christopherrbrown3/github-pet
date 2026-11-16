import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private final class FrozenBudgetClock: @unchecked Sendable {
    private let instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { instant }
}

/// Drives the Settings editor through the real AppModel in the offline simulated launch.
/// Budgets use a frozen clock; waits are handshakes on observable state (the bound only
/// limits a broken run, it never decides an assertion).
@Suite(.serialized) @MainActor struct ScopeEditorTests {
    private final class Spoken { var messages: [String] = [] }
    private func model(_ spoken: Spoken = Spoken()) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        let clock = FrozenBudgetClock()
        let app = AppModel(options: options, runtime: AppModel.Runtime(now: { Date(timeIntervalSince1970: 1_763_208_000) },
            systemReducedMotion: { true }, schedulesTimers: false,
            repositoryBudget: { CommandBudget(timeout: 20, now: { clock.now() }) }, scopeSimulationHoldLimit: nil))
        app.scopeEditor.budget = { CommandBudget(timeout: 20, now: { clock.now() }) }
        app.scopeEditor.announce = { spoken.messages.append($0) }
        return app
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() && ContinuousClock.now < end { await Task.yield() }
        try #require(predicate(), "bounded simulated completion")
    }
    private func settled(_ app: AppModel) async throws {
        try await wait { app.simulatedScopeQuiescent && !app.repositoryFetchInFlight && !app.scopeEditor.validationInFlight && !app.scopeEditor.discoveryInFlight }
    }
    private var simulatedA: ScopeIdentity { .github(ScopeSimulation.accountA) }

    @Test func draftEditsNeverTouchTheActiveScopeAndCancelRestoresIt() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        let editor = app.scopeEditor, generation = app.monitoringScopeGeneration
        #expect(editor.draft.mode == .selected && editor.draft.rows.map(\.text) == ["demo-a"])
        #expect(!editor.hasChanges && !editor.canApply)
        editor.repositoryInput = "  Demo-B/Pet "
        editor.addRepository()
        editor.update(editor.draft.rows[0].id, text: "demo-c")
        editor.setMode(.everything); editor.setMode(.selected)
        #expect(editor.hasChanges && editor.canApply)
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA && app.monitoringScopeGeneration == generation)
        #expect(app.scopeAccessSimulation?.validationCount == 0, "editing never connects")
        editor.cancel()
        #expect(editor.draft.rows.map(\.text) == ["demo-a"] && !editor.hasChanges)
        #expect(editor.status?.contains("unchanged") == true)
    }

    @Test func applyValidatesThenCommitsAtomicallyAndAnnounces() async throws {
        let spoken = Spoken(), app = model(spoken); defer { app.cleanupScopeSimulation() }; try await settled(app)
        app.injectServiceIncident(.major)
        let incidents = app.serviceIncidents, unseenIncidents = app.unseenIncidents
        let editor = app.scopeEditor
        editor.organizationInput = "demo-b"; editor.addOrganization()
        editor.repositoryInput = "demo-c/tools"; editor.addRepository()
        editor.apply()
        #expect(editor.phase == .validating && !editor.canApply)
        try await settled(app)
        let expected = try MonitoringScope(selected: [MonitoringTarget(organization: "demo-a"), MonitoringTarget(organization: "demo-b"),
                                                      MonitoringTarget(repository: "demo-c/tools")])
        #expect(app.activeMonitoringScope == expected)
        #expect(app.scopeAccessSimulation?.validationCount == 1)
        #expect(!editor.hasChanges && editor.phase == .idle)
        #expect(spoken.messages.last == "Monitoring scope applied: Selected · 2 organizations, 1 repository.")
        #expect(app.serviceIncidents == incidents && app.unseenIncidents == unseenIncidents, "incidents untouched")
        #expect(app.scopeSummary.hasPrefix("Monitoring scope · Selected · 2 organizations"))
        #expect(!app.scopeSummary.contains("demo"), "outside Settings only counts appear")
        // The new account record persisted; returning to the account restores it.
        app.simulateScopeAccount(true); try await settled(app)
        app.simulateScopeAccount(false); try await settled(app)
        #expect(app.activeMonitoringScope == expected)
    }

    @Test func unavailableTargetsAndNetworkFailureLeaveTheActiveSelectionIntact() async throws {
        let spoken = Spoken(), app = model(spoken); defer { app.cleanupScopeSimulation() }; try await settled(app)
        let editor = app.scopeEditor, generation = app.monitoringScopeGeneration, rows = app.items
        editor.organizationInput = "demo-denied"; editor.addOrganization()
        editor.repositoryInput = "elsewhere/pet"; editor.addRepository()
        editor.apply(); try await settled(app)
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA && app.monitoringScopeGeneration == generation)
        #expect(app.items == rows)
        let snapshot = editor.snapshot
        #expect(snapshot.organizations.map(\.error) == [nil, ScopeRowProblem.unavailable.message(for: .organization)])
        #expect(snapshot.repositories.first?.error == ScopeRowProblem.unavailable.message(for: .repository))
        #expect(spoken.messages.last?.contains("2 entries could not be verified") == true)
        editor.remove(editor.draft.rows[1].id)
        editor.update(editor.draft.rows[1].id, text: "demo-renamed/pet")
        editor.apply(); try await settled(app)
        #expect(editor.snapshot.repositories.first?.error == ScopeRowProblem.renamed.message(for: .repository))
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA)
        app.simulateScopeValidation(.networkFailure)
        editor.update(editor.draft.rows[1].id, text: "demo-b/pet")
        editor.apply(); try await settled(app)
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA && app.monitoringScopeGeneration == generation)
        #expect(editor.status == ScopeAccessFailure.transport.message && editor.hasChanges, "the draft survives for a retry")
        app.simulateScopeValidation(.normal)
        editor.apply(); try await settled(app)
        #expect(app.activeMonitoringScope?.targets.count == 2)
    }

    @Test func emptyOrInvalidSelectedCannotApply() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        let editor = app.scopeEditor
        editor.remove(editor.draft.rows[0].id)
        #expect(!editor.canApply && editor.applyBlockedReason == "Add at least one organization or repository.")
        editor.apply()
        #expect(app.scopeAccessSimulation?.validationCount == 0)
        editor.organizationInput = "org:demo is:pr"; editor.addOrganization()
        #expect(editor.organizationInputProblem == .malformed && editor.draft.rows.isEmpty)
        #expect(editor.snapshot.organizationInputError == ScopeRowProblem.malformed.message(for: .organization))
        editor.organizationInput = "demo-b"; editor.addOrganization()
        editor.update(editor.draft.rows[0].id, text: "demo b")
        #expect(!editor.canApply && editor.applyBlockedReason == "Correct the highlighted entries before applying.")
        for index in 0..<10 { editor.repositoryInput = "demo-x/r\(index)"; editor.addRepository() }
        #expect(editor.draft.rows.count == 10 && editor.repositoryInputProblem == .overLimit)
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA)
    }

    @Test func lateValidationCannotCommitAfterAccountChangeEditOrCancel() async throws {
        let spoken = Spoken(), app = model(spoken); defer { app.cleanupScopeSimulation() }; try await settled(app)
        let editor = app.scopeEditor, simulation = try #require(app.scopeAccessSimulation)
        // Account switch while validating: B's reply is a mismatch AND the generation moved.
        simulation.holdNextValidation()
        editor.organizationInput = "demo-b"; editor.addOrganization(); editor.apply()
        try await wait { simulation.heldCount == 1 }
        app.simulateScopeAccount(true); try await wait { !app.repositoryFetchInFlight }
        #expect(!editor.validationInFlight && editor.draft.rows.map(\.text) == ["demo-b/pet"], "B's own selection, not A's draft")
        #expect(spoken.messages.last?.contains("draft was discarded") == true)
        app.simulateScopeDeliver(); try await wait { editor.discardedReplies == 1 }
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedB)
        app.simulateScopeAccount(false); try await settled(app)
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA, "A's record was never written by the late reply")
        // Editing during validation cancels it.
        simulation.holdNextValidation()
        editor.organizationInput = "demo-b"; editor.addOrganization(); editor.apply()
        try await wait { simulation.heldCount == 1 }
        editor.organizationInput = "demo-c"; editor.addOrganization()
        #expect(!editor.validationInFlight && editor.phase == .idle)
        app.simulateScopeDeliver(); try await wait { editor.discardedReplies == 2 }
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA)
        // Cancel during validation.
        simulation.holdNextValidation(); editor.apply()
        try await wait { simulation.heldCount == 1 }
        editor.cancel()
        app.simulateScopeDeliver(); try await wait { editor.discardedReplies == 3 }
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA && editor.draft.rows.map(\.text) == ["demo-a"])
    }

    @Test func corruptConfigurationIsRepairedOnlyThroughValidatedApply() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        app.simulateScopeReload(corrupt: true); try await settled(app)
        let editor = app.scopeEditor
        #expect(app.monitoringScopeConfigurationError && editor.draft.mode == .selected && editor.draft.rows.isEmpty)
        #expect(app.scopeQuality?.contains("Settings › Monitoring scope") == true)
        #expect(!editor.canApply)
        editor.setMode(.everything)
        #expect(editor.canApply, "choosing Everything explicitly is a valid repair")
        editor.setMode(.selected)
        editor.repositoryInput = "demo-a/pet"; editor.addRepository()
        editor.apply(); try await settled(app)
        #expect(!app.monitoringScopeConfigurationError)
        #expect(app.activeMonitoringScope == (try MonitoringScope(selected: [MonitoringTarget(repository: "demo-a/pet")])))
        #expect(app.items.count == 1 && app.items.allSatisfy { $0.repository == "demo-a/pet" } && app.unseenCount == 0)
    }

    @Test func demoScopeUsesItsOwnRecordAndNeverValidatesLive() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        app.settings.dataSource = .fixtures
        let editor = app.scopeEditor
        #expect(editor.isDemo && editor.draft.mode == .everything && !editor.canLoadSuggestions)
        editor.setMode(.selected)
        editor.repositoryInput = "octo-org/octo-repo"; editor.addRepository()
        editor.apply()
        #expect(!editor.validationInFlight && app.scopeAccessSimulation?.validationCount == 0)
        #expect(app.activeMonitoringScope?.mode == .selected && app.scopeSummary.hasPrefix("Demo scope"))
        #expect(editor.status?.hasSuffix("(Demo).") == true)
        app.settings.dataSource = .githubCLI; try await settled(app)
        #expect(app.activeMonitoringScope == ScopeSimulation.selectedA, "Demo never overwrote the account record")
    }

    @Test func discoveryStatesAreVisibleAndTypedAddStaysAvailable() async throws {
        let spoken = Spoken(), app = model(spoken); defer { app.cleanupScopeSimulation() }; try await settled(app)
        let editor = app.scopeEditor
        #expect(app.scopeAccessSimulation?.discoveryPageCount == 0, "opening Settings never discovers")
        editor.loadSuggestions(); try await settled(app)
        #expect(editor.suggestions.organizations == ["demo-a", "demo-b", "demo-c"])
        #expect(editor.discoveryText.contains("end of this list") && editor.discoveryText.contains("hints"))
        editor.useSuggestion("demo-b", kind: .organization)
        #expect(editor.draft.rows.map(\.text) == ["demo-a", "demo-b"])
        editor.useSuggestion("demo-b", kind: .organization)
        #expect(editor.organizationInputProblem == .duplicate)

        app.simulateScopeDiscovery(.capped); editor.loadSuggestions(); try await settled(app)
        #expect(editor.suggestions.organizations.count == 150 && editor.discoveryText.contains("limit reached"))
        app.simulateScopeDiscovery(.partial); editor.loadSuggestions(); try await settled(app)
        #expect(editor.suggestions.organizations.count == 100 && editor.discoveryText.contains("incomplete"), "the errored page's valid entries stay, marked incomplete")
        app.simulateScopeDiscovery(.denied); editor.loadSuggestions(); try await settled(app)
        #expect(editor.suggestions.organizations.isEmpty && editor.discoveryText.contains("gh auth login"))
        app.simulateScopeDiscovery(.identityMismatch); editor.loadSuggestions(); try await settled(app)
        #expect(editor.suggestions.organizations.isEmpty && editor.discoveryText.contains("account changed"))
        #expect(spoken.messages.last == editor.discoveryText)
        editor.repositoryInput = "demo-z/not-suggested"; editor.addRepository()
        #expect(editor.repositoryInputProblem == nil, "suggestions never reject typed input")
        editor.apply(); try await settled(app)
        #expect(app.activeMonitoringScope?.targets.count == 3)
    }

    @Test func accountChangeDiscardsSuggestionsInFlight() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        let editor = app.scopeEditor
        editor.loadSuggestions(); try await settled(app)
        #expect(!editor.suggestions.organizations.isEmpty)
        app.simulateScopeAccount(true); try await settled(app)
        #expect(editor.discovery == .idle && editor.suggestions.organizations.isEmpty, "hints belong to one account")
    }
}
