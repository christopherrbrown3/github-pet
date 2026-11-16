import AppKit
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
        // Resolved (/var -> /private/var): the output walk refuses every symlinked component.
        QAScenarioRunner.resolvedOutputURL(FileManager.default.temporaryDirectory).appendingPathComponent("qa-runner-tests-\(UUID().uuidString)")
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

    @Test func linksAndRunnerNamedDirectoriesAreRefusedAndNeverFollowedOrDeleted() async throws {
        let fm = FileManager.default
        let sentinel = temporaryDirectory().appendingPathExtension("sentinel")
        try Data("outside".utf8).write(to: sentinel)
        func outsideIntact() throws -> Bool { try String(contentsOf: sentinel, encoding: .utf8) == "outside" }

        // Preflight: a symlinked marker, a symlinked step file and a runner-named directory are refused.
        for variant in ["marker-link", "step-link", "step-dir"] {
            let dir = temporaryDirectory()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let marker = dir.appendingPathComponent(QAScenarioRunner.markerName)
            if variant == "marker-link" { try fm.createSymbolicLink(at: marker, withDestinationURL: sentinel) }
            else { try Data().write(to: marker) }
            if variant == "step-link" { try fm.createSymbolicLink(at: dir.appendingPathComponent("step-01-x.json"), withDestinationURL: sentinel) }
            if variant == "step-dir" {
                let nested = dir.appendingPathComponent("step-01-notes.json")
                try fm.createDirectory(at: nested, withIntermediateDirectories: false)
                try Data("keep".utf8).write(to: nested.appendingPathComponent("inner.txt"))
            }
            #expect(throws: QAScenarioRunner.HarnessError.self, "\(variant)") { try QAScenarioRunner.checkOutput(dir.path) }
            #expect(try outsideIntact())
            if variant == "step-dir" { #expect(fm.fileExists(atPath: dir.appendingPathComponent("step-01-notes.json/inner.txt").path)) }
        }

        // After validation: swaps through the descriptor never write through a link or recurse.
        let dir = temporaryDirectory()
        let out = try QAOutputDirectory(dir)
        try out.write(Data("marker".utf8), name: QAScenarioRunner.markerName)
        try fm.removeItem(at: dir.appendingPathComponent(QAScenarioRunner.markerName))
        try fm.createSymbolicLink(at: dir.appendingPathComponent(QAScenarioRunner.markerName), withDestinationURL: sentinel)
        #expect(throws: QAOutputDirectory.Failure.self) { try out.write(Data("overwrite".utf8), name: QAScenarioRunner.markerName) }
        #expect(throws: QAOutputDirectory.Failure.self) { try out.removeRegularFile(QAScenarioRunner.markerName) }
        #expect(try outsideIntact())
        let nested = dir.appendingPathComponent("step-02-x.json")
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: nested.appendingPathComponent("inner.txt"))
        #expect(throws: QAOutputDirectory.Failure.self) { try out.removeRegularFile("step-02-x.json") }
        #expect(throws: QAOutputDirectory.Failure.self) { try out.write(Data(), name: "step-02-x.json") }
        #expect(fm.fileExists(atPath: nested.appendingPathComponent("inner.txt").path))
        #expect(throws: QAScenarioRunner.HarnessError.self) { try QAScenarioRunner.validate(try out.entries(), path: dir.path) }
        #expect(throws: QAOutputDirectory.Failure.self) { try out.write(Data(), name: "../escape.json") }

        // The output path itself may not be a symlink when it is opened.
        let link = temporaryDirectory()
        try fm.createSymbolicLink(at: link, withDestinationURL: dir)
        #expect(throws: QAOutputDirectory.Failure.self) { _ = try QAOutputDirectory(link) }

        // A full run into a directory whose step file was swapped for a link fails without touching the sentinel.
        let runDir = temporaryDirectory()
        try fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        try Data().write(to: runDir.appendingPathComponent(QAScenarioRunner.markerName))
        try Data().write(to: runDir.appendingPathComponent("step-00-launch.json"))
        let plan = try QAScenarioRunner.makePlan(options(["--simulate-monitoring-scope", "--qa-scenario", "account-a-b-a", "--qa-output", runDir.path]))
        try fm.removeItem(at: runDir.appendingPathComponent("step-00-launch.json"))
        try fm.createSymbolicLink(at: runDir.appendingPathComponent("step-00-launch.json"), withDestinationURL: sentinel)
        await #expect(throws: QAScenarioRunner.HarnessError.self) { _ = try await execute(plan) }
        #expect(try outsideIntact())
    }

    @Test func hardLinkedOutputsAreRefusedAtPreflightWriteAndCleanup() async throws {
        let fm = FileManager.default
        let root = temporaryDirectory()
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        // The "outside" file is test-owned and stays inside this fresh private sandbox.
        let sentinel = root.appendingPathComponent("outside-sentinel")
        let original = Data("test-owned outside contents must survive".utf8)
        try original.write(to: sentinel)
        for (index, name) in [QAScenarioRunner.markerName, "runner.json", "step-00-launch.json", "step-00-launch-inbox.png",
                              "step-00-launch-mascot.png", "step-01-open-settings-settings.png"].enumerated() {
            let dir = root.appendingPathComponent("output-\(index)")
            let out = try QAOutputDirectory(dir)
            try out.write(Data("marker".utf8), name: QAScenarioRunner.markerName)
            // Validate a safe plan first, then insert the hard link before descriptor revalidation.
            let plan = try QAScenarioRunner.makePlan(options(["--simulate-monitoring-scope", "--qa-scenario", "account-a-b-a", "--qa-output", dir.path]))
            let target = dir.appendingPathComponent(name)
            if name == QAScenarioRunner.markerName { try fm.removeItem(at: target) }
            try fm.linkItem(at: sentinel, to: target)
            #expect(throws: QAScenarioRunner.HarnessError.self, "preflight: \(name)") { try QAScenarioRunner.checkOutput(dir.path) }
            #expect(throws: QAScenarioRunner.HarnessError.self, "dirfd: \(name)") { try QAScenarioRunner.validate(try out.entries(), path: dir.path) }
            #expect(throws: QAOutputDirectory.Failure.self, "write: \(name)") { try out.write(Data("must not truncate".utf8), name: name) }
            #expect(throws: QAOutputDirectory.Failure.self, "cleanup: \(name)") { try out.removeRegularFile(name) }
            await #expect(throws: QAScenarioRunner.HarnessError.self, "execution revalidation: \(name)") { _ = try await execute(plan) }
            #expect(try Data(contentsOf: sentinel) == original)
            #expect(try Data(contentsOf: target) == original)
            // A rejected write must leave no temporary output behind.
            #expect(try out.entries().allSatisfy { !$0.name.hasPrefix(".github-pet-qa-write-") })
        }
    }

    @Test func writesReplaceInodesAndKeepTheOpenedDirectoryWhenItsPathChanges() throws {
        let fm = FileManager.default
        let root = temporaryDirectory()
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("output")
        let out = try QAOutputDirectory(dir)
        for name in [QAScenarioRunner.markerName, "runner.json", "step-00-launch.json", "step-00-launch-inbox.png"] {
            let original = Data("old inode".utf8), replacement = Data("complete new output".utf8)
            try out.write(original, name: name)
            let reader = try FileHandle(forReadingFrom: dir.appendingPathComponent(name))
            defer { try? reader.close() }
            try out.write(replacement, name: name)
            // This fails for in-place truncate/write even if a pre-open nlink check is added.
            #expect(try reader.readToEnd() == original)
            #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == replacement)
            #expect(out.kind(name) == .regular)
        }
        let moved = root.appendingPathComponent("opened-output")
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("runner.json")
        try Data("outside".utf8).write(to: sentinel)
        try fm.moveItem(at: dir, to: moved)
        try fm.createSymbolicLink(at: dir, withDestinationURL: outside)
        try out.write(Data("held directory".utf8), name: "runner.json")
        #expect(try Data(contentsOf: sentinel) == Data("outside".utf8))
        #expect(try Data(contentsOf: moved.appendingPathComponent("runner.json")) == Data("held directory".utf8))
        try out.removeRegularFile("runner.json")
        #expect(try Data(contentsOf: sentinel) == Data("outside".utf8))
        #expect(throws: QAOutputDirectory.Failure.self) { try out.write(Data(), name: "runner.json\0ignored") }
        #expect(try out.entries().allSatisfy { !$0.name.hasPrefix(".github-pet-qa-write-") })
    }

    @Test func ancestorSwappedForASymlinkAfterValidationIsNeverTraversed() async throws {
        // Everything lives in a private temp tree; "protected" only stands in for a protected location.
        let fm = FileManager.default
        let root = temporaryDirectory()
        let protected = root.appendingPathComponent("protected"), base = root.appendingPathComponent("base")
        try fm.createDirectory(at: protected, withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("a"), withIntermediateDirectories: true)
        func swapAncestor() throws {
            try fm.moveItem(at: base.appendingPathComponent("a"), to: base.appendingPathComponent("a-moved"))
            try fm.createSymbolicLink(at: base.appendingPathComponent("a"), withDestinationURL: protected)
        }
        // Existing and missing final directories, swapped between preflight and execute.
        for leaf in ["out", "missing/out"] {
            let output = base.appendingPathComponent("a/\(leaf)")
            if leaf == "out" { try fm.createDirectory(at: output, withIntermediateDirectories: true) }
            let plan = try QAScenarioRunner.makePlan(options(["--simulate-monitoring-scope", "--qa-scenario", "account-a-b-a", "--qa-output", output.path]))
            try swapAncestor()
            await #expect(throws: (any Error).self, "\(leaf)") { _ = try await execute(plan) }
            #expect(try fm.contentsOfDirectory(atPath: protected.path).isEmpty, "nothing reaches the link target (\(leaf))")
            try fm.removeItem(at: base.appendingPathComponent("a"))
            try fm.moveItem(at: base.appendingPathComponent("a-moved"), to: base.appendingPathComponent("a"))
        }
        // A not-yet-existing output under a symlinked system directory (/tmp -> /private/tmp) resolves.
        let viaTmp = "/tmp/qa-runner-tests-\(UUID().uuidString)/out"
        #expect(try QAScenarioRunner.checkOutput(viaTmp).path == "/private" + viaTmp)
        // An existing directory under /private/var opens as-is (no remapping to the /var symlink).
        let existing = temporaryDirectory()
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        #expect(existing.path.hasPrefix("/private/"))
        let opened = try QAOutputDirectory(QAScenarioRunner.checkOutput(existing.path))
        #expect(opened.resolvedPath == existing.path)
        // Direct: any symlinked ancestor is refused; missing components are created without following links.
        try swapAncestor()
        #expect(throws: QAOutputDirectory.Failure.self) { _ = try QAOutputDirectory(base.appendingPathComponent("a/new")) }
        #expect(try fm.contentsOfDirectory(atPath: protected.path).isEmpty)
        let created = try QAOutputDirectory(base.appendingPathComponent("a-moved/x/y"))
        try created.write(Data("ok".utf8), name: "runner.json")
        #expect(try String(contentsOf: base.appendingPathComponent("a-moved/x/y/runner.json"), encoding: .utf8) == "ok")
    }

    @Test func onlyDecodablePNGsAreAccepted() throws {
        #expect(throws: QAOutputDirectory.Failure.self) { try QAOutputDirectory.validatedPNG(nil) }
        #expect(throws: QAOutputDirectory.Failure.self) { try QAOutputDirectory.validatedPNG(Data()) }
        #expect(throws: QAOutputDirectory.Failure.self) { try QAOutputDirectory.validatedPNG(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])) }
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        #expect(try QAOutputDirectory.validatedPNG(png) == png)
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
