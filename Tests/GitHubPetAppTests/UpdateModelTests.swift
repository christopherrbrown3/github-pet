import Foundation
import Testing
import GitHubPetCore
@testable import GitHubPet

@MainActor @Suite struct UpdateModelTests {
    private func make(_ fixture: UpdateFixture, now: Date = Date(timeIntervalSince1970: 1_800_000_000),
                      opened: @escaping (URL) -> Void = { _ in }) -> UpdateModel {
        let defaults = EphemeralDefaults.named("dev.github-pet.tests.update-model-\(UUID().uuidString)")
        return UpdateModel(installed: UpdateFixture.installedBuild, defaults: defaults,
                           checker: UpdateModel.fixtureChecker(fixture), now: { now }, opener: opened)
    }

    @Test func failureIsNeverUpToDateAndRetryRecovers() async {
        let model = make(.offline)
        #expect(model.status == .idle)
        await model.checkNow().value
        #expect(model.status == .failed(.offline))
        #expect(nil != model.lastCheck)
        model.useFixture(.noUpdate)
        await model.checkNow().value
        #expect(model.status == .upToDate)
    }

    @Test func channelDefaultsToStableAndBetaIsAnExplicitChoice() {
        let model = make(.noUpdate)
        #expect(model.channel == .stable)
        model.channel = .beta
        #expect(model.channel == .beta)
    }

    @Test func downloadOpensOnlyTheValidatedReleasePage() async {
        var opened: [URL] = []
        let model = make(.betaAvailable) { opened.append($0) }
        model.channel = .beta
        #expect(!model.openDownloadPage())
        await model.checkNow().value
        #expect(model.openDownloadPage())
        #expect(opened.map(\.absoluteString) == ["https://github.com/christopherrbrown3/github-pet/releases/tag/v0.1.0-beta.4"])
    }

    @Test func autoCheckHonoursDailyGateAndToggle() async {
        let model = make(.noUpdate)
        model.autoCheck = false
        model.checkIfDue()
        #expect(model.status == .idle)
        model.autoCheck = true   // turning it on checks, because none has run yet
        await Task.yield()
        #expect(model.status == .checking || model.status == .upToDate)
    }

    @Test func changingChannelDropsStaleResult() async {
        let model = make(.betaAvailable)
        model.channel = .beta
        await model.checkNow().value
        guard case .available = model.status else { Issue.record("\(model.status)"); return }
        model.channel = .stable
        #expect(model.status == .idle)
    }

    @Test func runnerScenariosAllLoad() throws {
        for name in QAScenarioRunner.builtInScenarios.keys where name.hasPrefix("updates-") {
            #expect(throws: Never.self) { try QAScenarioRunner.loadScenario(name) }
        }
        #expect(QAScenarioRunner.builtInScenarios.keys.filter { $0.hasPrefix("updates-") }.count == 7)
    }
}
