import Foundation
import Testing
@testable import GitHubPet
@testable import GitHubPetCore

@MainActor @Suite(.serialized) struct SettingsPaneTests {
    @Test func suppressionScenarioParsesAndKeepsPollingAndInboxUpdates() async throws {
        #expect(QAScenarioRunner.settingsScenarios["settings-suppression-keeps-monitoring"] != nil)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("qa-suppress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        var plan = try QAScenarioRunner.makePlan(LaunchOptions.parse(
            arguments: ["GitHubPet", "--simulate-monitoring-scope", "--qa-scenario", "settings-suppression-keeps-monitoring",
                        "--qa-output", output.path], environment: [:]))
        plan.rendersPNGs = false
        plan.settleLimit = .seconds(600)
        let clock = plan.clock
        var launch = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        launch.forcePlaceholder = true
        let model = AppModel(options: launch, runtime: AppModel.Runtime(
            now: { clock.now() }, systemReducedMotion: { false }, schedulesTimers: false, scopeSimulationHoldLimit: nil))
        defer { model.cleanupScopeSimulation() }
        _ = try await QAScenarioRunner.execute(plan, model: model)
        let records = try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.hasPrefix("step-") && $0.hasSuffix(".json") }.sorted()
            .map { try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent($0))) as! [String: Any] }
        func block(_ label: String) throws -> [String: Any] {
            let record = try #require(records.first { $0["label"] as? String == label })
            return try #require(record["suppression"] as? [String: Any])
        }
        let snoozed = try block("snoozed"), row = try block("row-while-snoozed"), poll = try block("poll-while-snoozed")
        #expect(snoozed["snoozed"] as? Bool == true && snoozed["alertsAllowed"] as? Bool == false)
        #expect(snoozed["showsAlertIcon"] as? Bool == false)
        #expect((row["inboxRowCount"] as! Int) > (snoozed["inboxRowCount"] as! Int))
        #expect((poll["pollsRequested"] as! Int) > (row["pollsRequested"] as! Int))
        let quiet = try block("quiet-hours-cover-now"), quietPoll = try block("poll-during-quiet-hours")
        #expect(quiet["snoozed"] as? Bool == false && quiet["quietHoursActive"] as? Bool == true)
        #expect(quiet["interruptionsSuppressed"] as? Bool == true)
        #expect((quietPoll["pollsRequested"] as! Int) > (quiet["pollsRequested"] as! Int))
        #expect((quietPoll["inboxRowCount"] as! Int) > (quiet["inboxRowCount"] as! Int))
    }

    @Test func skinCardsLoadTheRealBundledPacks() {
        // In-memory defaults: this test must never touch the real preferences.
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--fixtures", "--defaults-suite", "settings-pane-tests"], environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "settings-pane.tests.\(UUID().uuidString)")
        let model = AppModel(options: options, runtime: AppModel.Runtime(schedulesTimers: false))
        for skin in MascotSkin.allCases {
            let artwork = model.artwork(for: skin)
            #expect(artwork.source == .builtIn(skin) || artwork.source == .placeholder)
        }
    }
}
