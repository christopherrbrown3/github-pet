import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private struct Refused: LocalizedError { var errorDescription: String? { "Operation not permitted" } }

/// Injected stand-in for SMAppService: no real login item is ever registered or read.
private final class FakeLoginBackend: LoginItemBackend, @unchecked Sendable {
    var status: LoginItemStatus
    var statusAfterRegister: LoginItemStatus = .enabled
    var registerError: Error?
    private(set) var calls: [String] = []
    init(_ status: LoginItemStatus) { self.status = status }
    func register() throws {
        calls.append("register")
        if let registerError { throw registerError }
        status = statusAfterRegister
    }
    func unregister() throws { calls.append("unregister"); status = .disabled }
}

@Suite @MainActor struct LoginItemSettingsTests {
    @Test func showsTheSystemStateOnlyAfterReadingItAndNeverWritesWhileReading() {
        let backend = FakeLoginBackend(.enabled)
        let settings = LoginItemSettings(backend: backend)
        #expect(settings.status == nil && !settings.isOn && settings.summary == "Checking with macOS…")
        settings.refresh()
        #expect(settings.isOn && settings.summary.hasPrefix("On"))
        // The user turned it off in System Settings meanwhile: a refresh follows, read-only.
        backend.status = .disabled
        settings.refresh()
        #expect(!settings.isOn && settings.summary == "Off.")
        #expect(backend.calls.isEmpty, "showing or refreshing never registers or unregisters")
    }

    @Test func pendingApprovalIsShownOnButHonestlyPending() {
        let backend = FakeLoginBackend(.disabled)
        backend.statusAfterRegister = .requiresApproval
        let settings = LoginItemSettings(backend: backend)
        settings.refresh()
        settings.setEnabled(true)
        #expect(settings.isOn && settings.failure == nil)
        #expect(settings.summary.hasPrefix("Pending approval.") && settings.summary.contains("Login Items"))
        // Flipping it on again while pending is not another register (PR57) and not a failure.
        settings.setEnabled(true)
        #expect(backend.calls == ["register"] && settings.failure == nil)
        settings.setEnabled(false)
        #expect(!settings.isOn && backend.calls == ["register", "unregister"])
    }

    @Test func aRefusedChangeIsReportedWithTheRealStatusAndClearsWhenTheSystemChanges() {
        let backend = FakeLoginBackend(.disabled)
        backend.registerError = Refused()
        let settings = LoginItemSettings(backend: backend)
        settings.refresh()
        settings.setEnabled(true)
        #expect(!settings.isOn, "the toggle follows the system, not the click")
        #expect(settings.summary == "macOS didn't turn on open at login. Status now: Off.")
        #expect(!settings.summary.contains("Operation not permitted"), "fixed text, not the system error")
        settings.refresh()
        #expect(settings.failure != nil, "unchanged system state keeps the failure visible")
        backend.status = .enabled // approved or added in System Settings
        settings.refresh()
        #expect(settings.failure == nil && settings.summary.hasPrefix("On"))
    }

    @Test func notFoundExplainsWhereTheAppMustLive() {
        let settings = LoginItemSettings(backend: FakeLoginBackend(.notFound))
        settings.refresh()
        #expect(!settings.isOn && settings.summary.contains("Applications"))
    }

    @Test func nonNormalLaunchesHaveNoBackendAndChangeNothing() {
        let launches: [[String]] = [
            ["--simulate-monitoring-scope", "--placeholder"],
            ["--fixtures", "--defaults-suite", "dev.github-pet.tests.login.\(UUID().uuidString)", "--placeholder"],
        ]
        for arguments in launches {
            var options = LaunchOptions.parse(arguments: ["GitHubPet"] + arguments, environment: [:])
            options.forcePlaceholder = true
            // The custom suite is what makes this launch non-normal; keep it in memory, since the
            // relaunch baseline (#12) would otherwise leave a preferences file behind.
            if !options.simulatesMonitoringScope, let suite = options.defaultsSuite {
                options.userDefaultsOverride = EphemeralDefaults(name: suite)
            }
            let app = AppModel(options: options, runtime: AppModel.Runtime(schedulesTimers: false, scopeSimulationHoldLimit: nil))
            defer { app.cleanupScopeSimulation() }
            let settings = app.loginItem
            #expect(!settings.isAvailable, "\(arguments)")
            settings.refresh(); settings.setEnabled(true)
            #expect(settings.status == nil && !settings.isOn && settings.summary.hasPrefix("Not available"))
            if let suite = options.defaultsSuite { #expect(!preferencesFileExists(suite), "no preferences file on disk") }
        }
    }

    @Test func anInjectedBackendIsWhatTheModelUses() {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        let backend = FakeLoginBackend(.disabled)
        let app = AppModel(options: options, runtime: AppModel.Runtime(schedulesTimers: false, scopeSimulationHoldLimit: nil,
                                                                       loginItemBackend: backend))
        defer { app.cleanupScopeSimulation() }
        app.loginItem.refresh()
        app.loginItem.setEnabled(true)
        #expect(backend.calls == ["register"] && app.loginItem.isOn)
    }
}
