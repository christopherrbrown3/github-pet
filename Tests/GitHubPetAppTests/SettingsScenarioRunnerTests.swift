import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private final class FrozenClock: @unchecked Sendable {
    private let instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { instant }
}

/// PR B runner scenarios run through the real AppModel and ScopeEditor. Settling is
/// quiescence-driven (launched == received + held) with a frozen budget clock; the time limit is
/// a hang guard only.
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct SettingsScenarioRunnerTests {
    private func run(_ name: String) async throws -> [[String: Any]] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("qa-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        var plan = try QAScenarioRunner.makePlan(LaunchOptions.parse(
            arguments: ["GitHubPet", "--simulate-monitoring-scope", "--qa-scenario", name, "--qa-output", output.path], environment: [:]))
        plan.rendersPNGs = false
        plan.settleLimit = .seconds(600)
        let budget = FrozenClock(), clock = plan.clock
        var launch = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        launch.forcePlaceholder = true
        let model = AppModel(options: launch, runtime: AppModel.Runtime(
            now: { clock.now() }, systemReducedMotion: { false }, schedulesTimers: false,
            repositoryBudget: { CommandBudget(timeout: 20, now: { budget.now() }) }, scopeSimulationHoldLimit: nil))
        model.scopeEditor.budget = { CommandBudget(timeout: 20, now: { budget.now() }) }
        model.scopeEditor.announce = { _ in }
        defer { model.cleanupScopeSimulation() }
        let summary = try await QAScenarioRunner.execute(plan, model: model)
        #expect(summary["completed"] as? Bool == true)
        return try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.hasPrefix("step-") && $0.hasSuffix(".json") }.sorted()
            .map { try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent($0))) as! [String: Any] }
    }
    private func settings(_ record: [String: Any]) -> [String: Any] { record["settingsScope"] as? [String: Any] ?? [:] }
    private func step(_ records: [[String: Any]], _ label: String) throws -> [String: Any] {
        try #require(records.first { $0["label"] as? String == label }, "missing step \(label)")
    }
    private func texts(_ settings: [String: Any], _ key: String) -> [String] {
        (settings[key] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }

    @Test func everySettingsScenarioIsBuiltInAndParses() throws {
        for name in ["settings-draft-apply-cancel", "settings-invalid-input", "settings-max-10", "settings-discovery-capped",
                     "settings-discovery-partial", "settings-discovery-denied", "settings-discovery-identity-mismatch",
                     "settings-validation-failure-keeps-active", "settings-min-size-long-lists"] {
            #expect(QAScenarioRunner.settingsScenarios[name] != nil)
            #expect(QAScenarioRunner.builtInScenarios[name] != nil, "\(name) is built in")
            _ = try QAScenarioRunner.loadScenario(name)
        }
        #expect(QAScenarioRunner.builtInScenarios["account-a-b-a"] != nil, "PR A scenarios remain")
        #expect(QAScenarioRunner.settingsScenarios.count == 9 && Set(QAScenarioRunner.settingsScenarios.keys).isDisjoint(with: QAScenarioRunner.coreScenarios.keys))
        #expect(throws: QAScenarioRunner.HarnessError.self) {
            try QAScenarioRunner.loadScenario(Self.file(#"{"name":"x","steps":[{"action":"settings-add","kind":"team","text":"a"}]}"#))
        }
        #expect(throws: QAScenarioRunner.HarnessError.self) {
            try QAScenarioRunner.loadScenario(Self.file(#"{"name":"x","steps":[{"action":"settings-edit","kind":"organization","index":11,"text":"a"}]}"#))
        }
    }
    private static func file(_ json: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qa-settings-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url.path
    }

    @Test func draftApplyCancelRecordsWhatSettingsShows() async throws {
        let records = try await run("settings-draft-apply-cancel")
        let cancelled = settings(try step(records, "cancel-restores-active"))
        #expect(texts(cancelled, "organizations") == ["demo-a"] && texts(cancelled, "repositories").isEmpty)
        #expect((try step(records, "cancel-restores-active")["monitoringScope"] as? [String: Any])?["active"] as? String == "Selected")
        let applied = try step(records, "apply-validated")
        #expect(settings(applied)["status"] as? String == "Monitoring scope applied: Selected · 2 organizations, 1 repository.")
        #expect((applied["inbox"] as? [String: Any])?["scopeHeader"] as? String == "Monitoring scope · Selected · 2 organizations, 1 repositories")
        let everything = try step(records, "apply-everything")
        #expect((everything["monitoringScope"] as? [String: Any])?["active"] as? String == "Everything")
        #expect(settings(everything)["applyEnabled"] as? Bool == false)
    }

    @Test func invalidInputIsRejectedInlineAndApplyBlocked() async throws {
        let records = try await run("settings-invalid-input")
        for label in ["org-qualifier", "org-space", "org-graphql"] {
            #expect(settings(try step(records, label))["organizationInputError"] as? String == ScopeRowProblem.malformed.message(for: .organization))
        }
        for label in ["repo-qualifier", "repo-extra-slash"] {
            #expect(settings(try step(records, label))["repositoryInputError"] as? String == ScopeRowProblem.malformed.message(for: .repository))
        }
        #expect(texts(settings(try step(records, "org-trimmed")), "organizations") == ["demo-a", "Demo-B"])
        #expect(settings(try step(records, "org-duplicate"))["organizationInputError"] as? String == ScopeRowProblem.duplicate.message(for: .organization))
        let blocked = settings(try step(records, "apply-blocked"))
        #expect(blocked["applyEnabled"] as? Bool == false && blocked["checksLaunched"] as? Int == 0)
        #expect(blocked["applyBlockedReason"] as? String == "Correct the highlighted entries before applying.")
    }

    @Test func maxTenRejectsTheEleventhAndAppliesTen() async throws {
        let records = try await run("settings-max-10")
        #expect(settings(try step(records, "add-11-rejected"))["repositoryInputError"] as? String == ScopeRowProblem.overLimit.message(for: .repository))
        let applied = try step(records, "apply-ten")
        #expect((applied["inbox"] as? [String: Any])?["scopeHeader"] as? String == "Monitoring scope · Selected · 5 organizations, 5 repositories")
    }

    @Test func discoveryStatesAreRecorded() async throws {
        let capped = try await run("settings-discovery-capped")
        let found = settings(try step(capped, "find-capped"))
        #expect((found["organizationSuggestions"] as? [String])?.count == 150)
        #expect((found["discovery"] as? String)?.contains("limit reached") == true)
        #expect(texts(settings(try step(capped, "use-last-suggestion")), "organizations") == ["demo-a", "demo-org-149"])
        #expect(settings(try step(capped, "typed-add-still-works"))["repositoryInputError"] == nil, "no error is recorded as an absent key")

        let partial = settings(try step(try await run("settings-discovery-partial"), "find-partial"))
        #expect((partial["discovery"] as? String)?.contains("incomplete") == true)
        let denied = settings(try step(try await run("settings-discovery-denied"), "find-denied"))
        #expect((denied["discovery"] as? String)?.contains("gh auth login") == true && (denied["organizationSuggestions"] as? [String])?.isEmpty == true)

        let mismatch = try await run("settings-discovery-identity-mismatch")
        #expect((settings(try step(mismatch, "find-mismatch-discards"))["discovery"] as? String)?.contains("account changed") == true)
        #expect((settings(try step(mismatch, "find-again"))["organizationSuggestions"] as? [String])?.count == 3)
        let afterSwitch = settings(try step(mismatch, "account-change-clears-hints"))
        #expect((afterSwitch["organizationSuggestions"] as? [String])?.isEmpty == true && texts(afterSwitch, "repositories") == ["demo-b/pet"])
    }

    @Test func validationFailuresKeepTheActiveSelection() async throws {
        let records = try await run("settings-validation-failure-keeps-active")
        for label in ["apply-rejected", "apply-renamed-rejected", "apply-network-failure", "back-to-a-unchanged"] {
            let record = try step(records, label)
            let requests = (record["scopeSimulation"] as? [String: Any])?["requests"] as? [[String: Any]] ?? []
            #expect((record["inbox"] as? [String: Any])?["scopeHeader"] as? String == "Monitoring scope · Selected · 1 organizations, 0 repositories", "\(label)")
            #expect(requests.last?["targets"] as? [String] == ["demo-a"], "\(label): no request for an unapplied scope")
        }
        let rejected = settings(try step(records, "apply-rejected"))
        #expect((rejected["organizations"] as? [[String: Any]])?.last?["error"] as? String == ScopeRowProblem.unavailable.message(for: .organization))
        #expect(settings(try step(records, "apply-network-failure"))["status"] as? String == ScopeAccessFailure.transport.message)
        let switched = settings(try step(records, "account-b-discards-draft"))
        #expect(texts(switched, "repositories") == ["demo-b/pet"] && texts(switched, "organizations").isEmpty)
        let delivered = settings(try step(records, "deliver-late-validation"))
        #expect(delivered["discardedReplies"] as? Int == 1 && delivered["checksLaunched"] as? Int == delivered["checksReceived"] as? Int)
    }

    @Test func longListsKeepTenEntriesWithInlineErrors() async throws {
        let records = try await run("settings-min-size-long-lists")
        let last = settings(try step(records, "settings-long-lists"))
        #expect(texts(last, "organizations").count + texts(last, "repositories").count == 10)
        #expect((last["organizations"] as? [[String: Any]])?[1]["error"] as? String == ScopeRowProblem.malformed.message(for: .organization))
        #expect(last["applyEnabled"] as? Bool == false)
    }

    /// Pre-existing leak on main: snapshot renders used a real per-pid suite, so cfprefsd left
    /// dev.github-pet.render-snapshots.<pid>.plist behind. The suite is now in-memory only.
    @Test func snapshotRendersNeverUseARealPreferencesSuite() throws {
        let options = LaunchOptions.parse(arguments: ["GitHubPet", "--render-snapshots", "/tmp/unused-render"], environment: [:])
        #expect(options.defaultsSuite == LaunchOptions.snapshotDefaultsSuite)
        let defaults = try #require(options.userDefaults as? EphemeralDefaults)
        #expect(defaults === options.userDefaults, "one shared in-memory instance per launch")
        SettingsStore(defaults: defaults).save(PetSettings())
        #expect(defaults.dictionaryRepresentation().isEmpty == false)
        #expect(UserDefaults.standard.persistentDomain(forName: LaunchOptions.snapshotDefaultsSuite) == nil, "nothing reached cfprefsd")
        EphemeralDefaults.release(LaunchOptions.snapshotDefaultsSuite)
        #expect(defaults.dictionaryRepresentation().isEmpty)
        let plain = LaunchOptions.parse(arguments: ["GitHubPet", "--defaults-suite", LaunchOptions.snapshotDefaultsSuite], environment: [:])
        #expect(!(plain.userDefaults is EphemeralDefaults), "only an actual snapshot launch is redirected")
    }
}
