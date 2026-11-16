import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private final class FrozenBudgetClock: @unchecked Sendable {
    private let instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { instant }
}

// Hang guard only: settling is quiescence-driven and the budget clock is frozen, so passing
// never depends on runner speed.
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct QAScenarioRunnerTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qa-runner-tests-\(UUID().uuidString)")
    }
    private func options(_ extra: [String]) -> LaunchOptions {
        LaunchOptions.parse(arguments: ["GitHubPet"] + extra, environment: [:])
    }
    private func scenarioFile(_ json: String) throws -> String {
        let url = temporaryDirectory().appendingPathExtension("json")
        try Data(json.utf8).write(to: url)
        return url.path
    }
    private func refusal(_ extra: [String]) -> String? {
        do { _ = try QAScenarioRunner.makePlan(options(extra)); return nil } catch { return "\(error)" }
    }
    /// Executes a plan on a model whose budget clock is frozen and whose held replies have no
    /// real-time bound; the runner's settle limit is a generous harness bound.
    private func execute(_ plan: QAScenarioRunner.Plan) async throws -> (AppModel, [String: Any]) {
        var plan = plan
        plan.rendersPNGs = false
        plan.settleLimit = .seconds(600)
        let budgetClock = FrozenBudgetClock(), clock = plan.clock
        var launch = options(["--simulate-monitoring-scope", "--placeholder"])
        launch.forcePlaceholder = true
        let model = AppModel(options: launch, runtime: AppModel.Runtime(
            now: { clock.now() }, systemReducedMotion: { false }, schedulesTimers: false,
            repositoryBudget: { CommandBudget(timeout: 20, now: { budgetClock.now() }) }, scopeSimulationHoldLimit: nil))
        return (model, try await QAScenarioRunner.execute(plan, model: model))
    }
    private func records(_ directory: URL) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") && $0.hasPrefix("step-") }
            .sorted().map { try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent($0))) as! [String: Any] }
    }

    @Test func runnerFlagsWithoutSimulationAreRefusedBeforeAnythingIsWritten() throws {
        let output = temporaryDirectory()
        for flags in [["--qa-scenario", "account-a-b-a", "--qa-output", output.path],
                      ["--qa-output", output.path], ["--qa-scenario", "account-a-b-a"],
                      ["--render-snapshots", "/tmp/unused", "--simulate-monitoring-scope", "--qa-scenario", "account-a-b-a", "--qa-output", output.path]] {
            #expect(refusal(flags)?.contains("require --simulate-monitoring-scope") == true)
        }
        #expect(refusal(["--simulate-monitoring-scope", "--qa-scenario", "account-a-b-a"])?.contains("--qa-output") == true)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(options([]).qaScenario == nil && options([]).qaOutput == nil)
    }

    @Test func badScenariosFailLoudlyAndEveryBuiltInParses() throws {
        let sim = ["--simulate-monitoring-scope", "--qa-output", temporaryDirectory().path, "--qa-scenario"]
        #expect(refusal(sim + ["nope"])?.contains("unknown scenario") == true)
        #expect(refusal(sim + [try scenarioFile(#"{"name":"x","steps":["#)])?.contains("not a JSON object") == true)
        #expect(refusal(sim + [try scenarioFile(#"{"name":"x","steps":[{"action":"fly"}]}"#)])?.contains("unknown action") == true)
        #expect(refusal(sim + [try scenarioFile(#"{"name":"x","steps":[{"action":"hold","cnt":2}]}"#)])?.contains("unknown key") == true)
        #expect(refusal(sim + [try scenarioFile(#"{"name":"x","steps":[{"action":"hold","count":true}]}"#)]) != nil, "a boolean is not a count")
        #expect(refusal(sim + [try scenarioFile(#"{"name":"x","steps":[{"action":"hold","count":9}]}"#)]) != nil)
        #expect(refusal(sim + [try scenarioFile(#"{"name":"x","steps":[{"action":"quit"},{"action":"capture"}]}"#)])?.contains("last step") == true)
        #expect(refusal(sim + [try scenarioFile(#"{"name":"x","steps":[{"action":"capture","label":"../x"}]}"#)])?.contains("label") == true)
        #expect(refusal(sim + [try scenarioFile(#"{"name":"x","extra":1,"steps":[{"action":"capture"}]}"#)])?.contains("unknown scenario key") == true)
        #expect(refusal(sim + [try scenarioFile(#"{"name":"x","steps":[{"action":"clock-advance","seconds":1}]}"#)]) == nil, "integer JSON numbers are numbers")
        for name in QAScenarioRunner.builtInScenarios.keys {
            #expect(refusal(sim + [name]) == nil, "built-in \(name) must validate")
        }
        // PR A's set; PR B's Settings scenarios are pinned in SettingsScenarioRunnerTests.
        #expect(Set(QAScenarioRunner.coreScenarios.keys) == ["restore-before-display", "account-a-b-a", "stale-reply-after-apply",
            "corrupt-saved-selected", "partial-recovery-new-once", "incidents-preserved", "privacy-summary", "demo-isolation"])
    }

    @Test func outputNeverOverwritesFilesTheRunnerDidNotWrite() throws {
        let fm = FileManager.default
        let foreign = temporaryDirectory()
        try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreign.appendingPathComponent("notes.txt"))
        #expect(throws: QAScenarioRunner.HarnessError.self) { try QAScenarioRunner.checkOutput(foreign.path) }
        try Data().write(to: foreign.appendingPathComponent(QAScenarioRunner.markerName))
        #expect(throws: QAScenarioRunner.HarnessError.self) { try QAScenarioRunner.checkOutput(foreign.path) }
        #expect(try String(contentsOf: foreign.appendingPathComponent("notes.txt"), encoding: .utf8) == "keep")
        let home = fm.homeDirectoryForCurrentUser.path
        for path in ["/", home, home + "/Library/Preferences/qa", "/System/qa", "/etc/qa"] {
            #expect(throws: QAScenarioRunner.HarnessError.self) { try QAScenarioRunner.checkOutput(path) }
        }
        let file = temporaryDirectory()
        try Data().write(to: file)
        #expect(throws: QAScenarioRunner.HarnessError.self) { try QAScenarioRunner.checkOutput(file.path) }
        #expect(QAScenarioRunner.isRunnerFile("step-03-hold-one-inbox.png") && QAScenarioRunner.isRunnerFile("runner.json"))
        #expect(!QAScenarioRunner.isRunnerFile("notes.txt") && !QAScenarioRunner.isRunnerFile("step-1-x.json"))
    }

    @Test func twoHeldRepliesDeliveredNewestFirstAreBothDiscardedAndStepsRecordWhatIsVisible() async throws {
        let output = temporaryDirectory()
        let path = try scenarioFile(#"""
        {"name": "a1", "steps": [
          {"action": "hold", "count": 2, "label": "hold-two"},
          {"action": "apply", "scope": "everything", "label": "apply-everything"},
          {"action": "apply", "scope": "selected", "label": "apply-selected"},
          {"action": "deliver-newest", "label": "deliver-newest"},
          {"action": "deliver-oldest", "label": "deliver-oldest"},
          {"action": "quit"}]}
        """#)
        let plan = try QAScenarioRunner.makePlan(options(["--simulate-monitoring-scope", "--qa-scenario", path, "--qa-output", output.path]))
        let (model, summary) = try await execute(plan)
        let steps = try records(output)
        #expect(steps.map { $0["label"] as! String } == ["launch", "hold-two", "apply-everything", "apply-selected", "deliver-newest", "deliver-oldest"])
        func sim(_ i: Int) -> [String: Any] { steps[i]["scopeSimulation"] as! [String: Any] }
        func inbox(_ i: Int) -> [String: Any] { steps[i]["inbox"] as! [String: Any] }
        #expect(sim(1)["held"] as? Int == 1 && sim(2)["held"] as? Int == 2 && sim(3)["held"] as? Int == 2)
        #expect(sim(4)["discarded"] as? Int == 1 && sim(5)["discarded"] as? Int == 2 && sim(5)["held"] as? Int == 0)
        for i in steps.indices.dropFirst(3) {
            let rows = inbox(i)["rows"] as! [[String: Any]]
            #expect(rows.map { $0["repository"] as! String } == ["demo-a/pet"], "final Selected scope survives both stale replies")
            #expect((inbox(i)["scopeHeader"] as! String).hasPrefix("Monitoring scope · Selected"))
            #expect((steps[i]["attention"] as! [String: Any])["unseenCount"] as? Int == 0)
        }
        let requests = sim(5)["requests"] as! [[String: Any]]
        #expect(requests.map { $0["scope"] as! String } == ["Selected", "Selected", "Everything", "Selected"])
        #expect(requests.allSatisfy { $0["expectedAccount"] as? String == "A" })
        #expect(requests.map { $0["generation"] as! Int } == requests.map { $0["generation"] as! Int }.sorted())
        #expect(steps.allSatisfy { ($0["defaultsDomain"] as? String)?.hasPrefix("dev.github-pet.scope-simulation.") == true })
        let quit = try #require(summary["quit"] as? [String: Any])
        #expect(quit["heldAtQuit"] as? Int == 0 && quit["domainKeysAfterCleanup"] as? Int == 0)
        #expect(quit["plistOnDisk"] as? Bool == false)
        #expect(model.simulatedHeldReplies == 0)
    }

    @Test func heldReplyThatTimesOutIsNoLongerCountedAsHeld() {
        // A zero hold bound expires on the first check, whatever the runner speed.
        let simulation = ScopeSimulation(holdLimit: .zero), clock = FrozenBudgetClock()
        simulation.holdNextReply()
        let result = simulation.fetch(scope: ScopeSimulation.selectedA, expectedAccount: ScopeSimulation.accountA,
                                      budget: CommandBudget(timeout: 20, now: { clock.now() }))
        #expect(result.issues == [.deadline] && result.items.isEmpty)
        #expect(simulation.heldCount == 0)
        #expect(simulation.progress == (entered: 1, finished: 1, held: 0))
        #expect(!simulation.releaseReply(newest: false), "nothing is left to deliver")
    }
    @Test func quitWithHeldReplyCleansDomainAndRejectsTheLateCallback() async throws {
        let output = temporaryDirectory()
        let plan = try QAScenarioRunner.makePlan(options(["--simulate-monitoring-scope", "--qa-scenario", "demo-isolation", "--qa-output", output.path]))
        let (model, summary) = try await execute(plan)
        let quit = try #require(summary["quit"] as? [String: Any])
        #expect(quit["heldAtQuit"] as? Int == 1 && quit["lateRepliesReceivedAfterCleanup"] as? Int == 1)
        #expect(quit["domainKeysAfterCleanup"] as? Int == 0 && quit["plistOnDisk"] as? Bool == false)
        let domain = try #require(model.simulationDomain)
        #expect(UserDefaults.standard.persistentDomain(forName: domain)?.isEmpty != false)
        let steps = try records(output)
        let demo = steps.filter { ($0["settings"] as! [String: Any])["dataSource"] as? String == "fixtures" }
        #expect(!demo.isEmpty && demo.allSatisfy { (($0["inbox"] as! [String: Any])["scopeHeader"] as! String).hasPrefix("Demo scope") })
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(QAScenarioRunner.markerName).path))
    }
}
