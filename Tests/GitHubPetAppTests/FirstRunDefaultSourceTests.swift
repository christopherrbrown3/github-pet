import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

/// #96: a fresh install starts on the gh source. With gh missing it must show the #52 setup
/// state, never an empty inbox and never silent Demo data. The gh locator is pointed at a
/// non-existent path, so nothing real runs.
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct FirstRunDefaultSourceTests {
    @Test func freshInstallWithoutGhShowsSetupNotEmptyOrDemo() async throws {
        let key = GhLocator.overrideVariable
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "/nonexistent/github-pet-test/gh", 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }

        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--placeholder"], environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "firstrun.tests.\(UUID().uuidString)")
        let app = AppModel(options: options, runtime: AppModel.Runtime(schedulesTimers: false))
        #expect(app.settings.dataSource == .githubCLI)
        #expect(!app.usingFixtures)
        await app.repositoryPollSettled()
        #expect(app.dataState == .ghMissing)
        #expect(app.items.isEmpty)
        #expect(!GhSetup.links(for: app.dataState).isEmpty, "setup guidance is offered")
        #expect(app.dataState != .empty && app.dataState != .ready)
    }

    @Test func storedFixturesChoiceStaysDemo() throws {
        let defaults = EphemeralDefaults(name: "firstrun.stored.\(UUID().uuidString)")
        var saved = PetSettings()
        saved.dataSource = .fixtures
        SettingsStore(defaults: defaults).save(saved)
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--placeholder"], environment: [:])
        options.userDefaultsOverride = defaults
        let app = AppModel(options: options, runtime: AppModel.Runtime(schedulesTimers: false))
        #expect(app.settings.dataSource == .fixtures && app.usingFixtures)
    }
}
