import Foundation
import Darwin
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private final class FrozenBudgetClock: @unchecked Sendable {
    private let instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { instant }
}

/// Test-only transport: each discovery completes only when its own gate is released. The
/// blocking work runs on ScopeEditor's GCD queue, never the cooperative pool or main actor.
private final class ControlledDiscovery: ScopeAccessChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [DispatchSemaphore] = []
    var started: Int { lock.lock(); defer { lock.unlock() }; return gates.count }
    func release(_ index: Int) {
        lock.lock(); let gate = gates[index]; lock.unlock(); gate.signal()
    }
    func releaseAll() {
        lock.lock(); let all = gates; lock.unlock(); all.forEach { $0.signal() }
    }
    func validate(scope: MonitoringScope, expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeAccessOutcome {
        .failed(.transport)
    }
    func discover(expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeDiscoveryResult {
        let gate = DispatchSemaphore(value: 0)
        lock.lock(); let index = gates.count; gates.append(gate); lock.unlock()
        guard gate.wait(timeout: .now() + 300) == .success else { return .failed(.deadline) }
        let name = index == 0 ? "demo-old" : "demo-new"
        return ScopeDiscoveryResult(viewer: ScopeViewer(account: expectedAccount, login: "demo-user"),
            organizations: .init(suggestions: [name], completion: .exhausted, pages: 1),
            repositories: .init(suggestions: [name + "/pet"], completion: .exhausted, pages: 1))
    }
}

/// Test-only paged transport: real ScopeDiscovery.run over fixture pages that always report
/// more. The first run's first page blocks until the test releases it after cancellation, so
/// any later page of that run proves cancellation never reached the Dispatch thread.
private final class PagedDiscovery: ScopeAccessChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let firstPage = DispatchSemaphore(value: 0)
    private var pages: [Int] = []
    private var results: [Int: ScopeDiscoveryResult] = [:]
    var started: Int { lock.lock(); defer { lock.unlock() }; return pages.count }
    func pages(_ run: Int) -> Int { lock.lock(); defer { lock.unlock() }; return pages[run] }
    func result(_ run: Int) -> ScopeDiscoveryResult? { lock.lock(); defer { lock.unlock() }; return results[run] }
    func releaseFirstPage() { firstPage.signal() }
    func validate(scope: MonitoringScope, expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeAccessOutcome {
        .failed(.transport)
    }
    func discover(expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeDiscoveryResult {
        lock.lock(); let run = pages.count; pages.append(0); lock.unlock()
        let result = ScopeDiscovery.run(expectedAccount: expectedAccount, budget: budget) { plan in
            self.lock.lock(); self.pages[run] += 1; let number = self.pages[run]; self.lock.unlock()
            if run == 0 && number == 1 { _ = self.firstPage.wait(timeout: .now() + 300) }
            let name = "demo-\(run == 0 ? "old" : "new")-\(number)"
            var viewer: [String: Any] = ["id": expectedAccount.viewerID, "login": "demo-user"]
            let more: [String: Any] = ["hasNextPage": true, "endCursor": "cursor\(number)"]
            if case .some = plan.organizationCursor { viewer["organizations"] = ["nodes": [["login": name]], "pageInfo": more] }
            if case .some = plan.repositoryCursor { viewer["repositories"] = ["nodes": [["nameWithOwner": name + "/pet"]], "pageInfo": more] }
            let bytes = try JSONSerialization.data(withJSONObject: ["data": ["viewer": viewer]])
            guard budget.reserve(bytes.count) else { throw CommandError.outputLimitExceeded }
            return CommandResult(exitCode: 0, stdout: bytes, stderr: Data())
        }
        lock.lock(); results[run] = result; lock.unlock()
        return result
    }
}

/// Real gh transport pointed at a fixture executable that reports its PID through a FIFO, then
/// execs a short sleep. Records each outcome so the test sees what the Dispatch thread returned.
private final class RecordingGhAccess: ScopeAccessChecking, @unchecked Sendable {
    let base: ScopeGhAccess
    private let lock = NSLock()
    private var outcomes: [ScopeAccessOutcome] = []
    init(_ base: ScopeGhAccess) { self.base = base }
    var recorded: [ScopeAccessOutcome] { lock.lock(); defer { lock.unlock() }; return outcomes }
    func validate(scope: MonitoringScope, expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeAccessOutcome {
        let outcome = base.validate(scope: scope, expectedAccount: expectedAccount, budget: budget)
        lock.lock(); outcomes.append(outcome); lock.unlock()
        return outcome
    }
    func discover(expectedAccount: ScopeAccount, budget: CommandBudget) -> ScopeDiscoveryResult { .failed(.transport) }
}

/// Nonblocking: the main actor must stay free to start the validation Task under test.
private func readChildPID(_ fd: Int32) -> Int32? {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, 0) > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: 64)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0 else { return nil }
    return Int32(String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Drives the Settings editor through the real AppModel in the offline simulated launch.
/// Budgets use a frozen clock; waits are handshakes on observable state (the bound only
/// limits a broken run, it never decides an assertion).
@Suite(.serialized, .timeLimit(.minutes(5))) @MainActor struct ScopeEditorTests {
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
        // No wall-clock deadline (#171): starved CI runners outlast any fixed bound. The suite's
        // time limit is the hang guard; the wait only ends when the observable state is reached.
        while !predicate() { try await Task.sleep(nanoseconds: 1_000_000) }
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
        for index in 0..<12 { editor.repositoryInput = "demo-x/r\(index)"; editor.addRepository() }
        #expect(editor.draft.rows.count == 13 && editor.repositoryInputProblem == nil, "no target cap (#137)")
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

    // FAIL before (#60 C1): with a clean draft, the old account's "N found" line stayed under
    // "Suggestions not loaded".
    @Test func accountChangeClearsTheOldAccountsStatusLine() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }; try await settled(app)
        let editor = app.scopeEditor
        editor.loadSuggestions(); try await settled(app)
        #expect(editor.status?.contains("found") == true && !editor.hasChanges)
        app.simulateScopeAccount(true); try await settled(app)
        #expect(editor.discovery == .idle)
        #expect(editor.status == nil, "a clean draft carries no status across accounts")

        // A dirty draft still reports the discard, for the new account only.
        editor.loadSuggestions(); try await settled(app)
        editor.repositoryInput = "demo-b/extra"; editor.addRepository()
        #expect(editor.hasChanges)
        app.simulateScopeAccount(false); try await settled(app)
        #expect(editor.status == "Account or data source changed. The draft was discarded; nothing was applied.")
    }

    @Test func cancelledDiscoveryCannotMutateReplacementAfterIdentityOrSourceRoundTrip() async throws {
        for accountRoundTrip in [true, false] {
            for oldCompletesFirst in [true, false] {
                let app = model(), access = ControlledDiscovery()
                defer { access.releaseAll(); app.cleanupScopeSimulation() }
                try await settled(app)
                let editor = ScopeEditor(model: app, access: access)
                let clock = FrozenBudgetClock()  // frozen (#171): the default real-clock budget expires on a starved runner
                editor.budget = { CommandBudget(timeout: 20, now: { clock.now() }) }
                editor.announce = { _ in }
                editor.observeActive()
                editor.loadSuggestions()
                try await wait { access.started == 1 }
                // Drive actual model changes, then the same observer AppModel.sync calls.
                if accountRoundTrip {
                    app.simulateScopeAccount(true); try await settled(app); editor.observeActive()
                    app.simulateScopeAccount(false); try await settled(app); editor.observeActive()
                } else {
                    app.settings.dataSource = .fixtures; editor.observeActive()
                    app.settings.dataSource = .githubCLI; try await settled(app); editor.observeActive()
                }
                #expect(editor.discovery == .idle && !editor.discoveryInFlight)
                editor.loadSuggestions()
                try await wait { access.started == 2 }
                let loadingStatus = editor.status
                access.release(oldCompletesFirst ? 0 : 1)
                try await wait { editor.receivedChecks == 1 }
                if oldCompletesFirst {
                    #expect(editor.discovery == .loading && editor.discoveryInFlight,
                            "Cancelled origin must not clear the replacement task or finish its loading state")
                    #expect(editor.suggestions.organizations.isEmpty && editor.status == loadingStatus)
                    #expect(!editor.canLoadSuggestions, "The replacement still owns Find suggestions")
                } else {
                    #expect(editor.suggestions.organizations == ["demo-new"])
                }
                access.release(oldCompletesFirst ? 1 : 0)
                try await wait { editor.receivedChecks == 2 }
                #expect(!editor.discoveryInFlight && editor.canLoadSuggestions)
                #expect(editor.suggestions.organizations == ["demo-new"])
                #expect(editor.suggestions.repositories == ["demo-new/pet"])
                #expect(editor.discardedReplies == 1)
            }
        }
    }

    @Test func cancelledDiscoveryStopsBeforeLaterPagesWhileReplacementCompletes() async throws {
        let app = model(), access = PagedDiscovery()
        defer { access.releaseFirstPage(); app.cleanupScopeSimulation() }
        try await settled(app)
        let editor = ScopeEditor(model: app, access: access)
        let clock = FrozenBudgetClock()
        editor.budget = { CommandBudget(timeout: 20, now: { clock.now() }) }
        editor.announce = { _ in }
        editor.observeActive()
        editor.loadSuggestions()
        try await wait { access.started == 1 }
        // Account round-trip cancels the origin Task while its first page is still in flight.
        app.simulateScopeAccount(true); try await settled(app); editor.observeActive()
        app.simulateScopeAccount(false); try await settled(app); editor.observeActive()
        editor.loadSuggestions()
        try await wait { editor.receivedChecks == 1 }
        // The replacement owns an independent budget and completes all three pages first.
        #expect(access.pages(1) == 3)
        #expect(editor.suggestions.organizations == ["demo-new-1", "demo-new-2", "demo-new-3"])
        guard case .finished(let replacement) = editor.discovery else { Issue.record("replacement unfinished"); return }
        #expect(replacement.failure == nil && replacement.organizations.completion == .capped)
        access.releaseFirstPage()
        try await wait { editor.receivedChecks == 2 }
        #expect(access.pages(0) == 1, "a cancelled run never starts a later page")
        let old = try #require(access.result(0))
        #expect(old.failure == .cancelled)
        #expect(![ScopeDiscoveryCompletion.exhausted, .capped].contains(old.organizations.completion))
        #expect(![ScopeDiscoveryCompletion.exhausted, .capped].contains(old.repositories.completion))
        #expect(editor.discardedReplies == 1 && editor.discovery == .finished(replacement), "no old hints reach state")
        #expect(!editor.suggestions.organizations.contains { $0.hasPrefix("demo-old") })
    }

    @Test func cancelledValidationStopsItsRealChildOffPool() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("started"), script = directory.appendingPathComponent("gh")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let fd = open(fifo.path, O_RDWR | O_NONBLOCK)
        try #require(fd >= 0)
        defer { close(fd) }
        try "#!/bin/sh\nprintf '%s\\n' $$ > '\(fifo.path)'\nexec /bin/sleep 3\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(chmod(script.path, 0o700) == 0)
        let access = RecordingGhAccess(ScopeGhAccess(
            locator: GhLocator(environment: [GhLocator.overrideVariable: script.path]), runner: ProcessCommandRunner()))
        let editor = ScopeEditor(model: app, access: access)
        // A real process needs the system clock, so use the longest budget (it caps at 20 s); the child
        // is cancelled long before it lapses, and the cap only matters if a starved runner outlasts it.
        editor.budget = { CommandBudget(timeout: CommandBudget.maximumSeconds) }
        editor.announce = { _ in }
        editor.observeActive()
        editor.repositoryInput = "demo-b/pet"; editor.addRepository()
        editor.apply()
        #expect(editor.validationInFlight)
        var pid: Int32?
        try await wait { pid = pid ?? readChildPID(fd); return pid != nil }
        let child = try #require(pid, "actual child-start receipt")
        #expect(kill(child, 0) == 0)
        editor.cancel()
        try await wait { editor.receivedChecks == 1 }
        // Before the fix the Dispatch thread waited for the child to exit on its own and parsed
        // its empty output; now it observes the cancelled budget and tears the child down.
        #expect(access.recorded == [.failed(.cancelled)])
        let status = kill(child, 0), error = errno
        #expect(status == -1 && error == ESRCH, "cancelled child is gone/reaped")
        #expect(editor.discardedReplies == 1 && app.activeMonitoringScope == ScopeSimulation.selectedA)
    }
}
