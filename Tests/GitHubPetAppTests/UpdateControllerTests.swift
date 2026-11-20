import Foundation
import GitHubPetCore
import Testing
@testable import GitHubPet

@MainActor
private final class FakeUpdater: UpdaterBackend {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var lastUpdateCheckDate: Date? = Date(timeIntervalSince1970: 1_800_000_000)
    var checks = 0
    func checkForUpdates() { checks += 1 }
}

@MainActor @Suite struct UpdateControllerTests {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private func info(configured: Bool, release: String? = "0.1.0") -> [String: Any] {
        var info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "214", "SUAllowsAutomaticUpdates": true,
                                   "SUFeedURL": "https://example.com/appcast.xml"]
        if configured { info["SUPublicEDKey"] = key }
        if let release { info["GitHubPetReleaseVersion"] = release }
        return info
    }
    private func defaults() -> UserDefaults { EphemeralDefaults.named("dev.github-pet.tests.update-controller-\(UUID().uuidString)") }
    private let appURL = URL(fileURLWithPath: "/Applications/GitHubPet.app")

    @Test func configuredBuildUsesTheBackend() {
        let fake = FakeUpdater()
        let model = UpdateController.make(infoDictionary: info(configured: true), bundleURL: appURL, normalLaunch: true,
                                          defaults: defaults(), backend: fake)
        #expect(model.isAvailable && model.state == .configured && model.canCheck)
        #expect(model.lastCheck == fake.lastUpdateCheckDate)
        model.checkForUpdates()
        #expect(fake.checks == 1)
    }

    @Test func unconfiguredBuildDisablesTheUpdaterEvenWithABackend() {
        let fake = FakeUpdater()
        let model = UpdateController.make(infoDictionary: info(configured: false), bundleURL: appURL, normalLaunch: true,
                                          defaults: defaults(), backend: fake)
        #expect(!model.isAvailable && !model.canCheck)
        guard case .notConfigured(let reason) = model.state else { Issue.record("expected not configured"); return }
        #expect(reason.contains("signing key"))
        model.checkForUpdates()
        #expect(fake.checks == 0)
    }

    @Test func noUpdaterStartsOutsideANormalAppLaunch() {
        // No injected backend: tests, `swift run` and non-normal launches must not start Sparkle.
        for (normal, url) in [(false, appURL), (true, URL(fileURLWithPath: "/tmp/xctest")), (true, URL(fileURLWithPath: "/tmp/.build/debug"))] {
            let model = UpdateController.make(infoDictionary: info(configured: true), bundleURL: url, normalLaunch: normal, defaults: defaults())
            #expect(!model.isAvailable)
            #expect(model.state == .notConfigured("Update checks are off in this launch mode."))
        }
    }

    @Test func automaticInstallNeedsTheBuildToAllowIt() {
        let fake = FakeUpdater()
        var plist = info(configured: true)
        plist["SUAllowsAutomaticUpdates"] = false
        let model = UpdateController.make(infoDictionary: plist, bundleURL: appURL, normalLaunch: true, defaults: defaults(), backend: fake)
        model.setAutomaticInstall(true)
        #expect(!fake.automaticallyDownloadsUpdates)
        let allowed = UpdateController.make(infoDictionary: info(configured: true), bundleURL: appURL, normalLaunch: true,
                                            defaults: defaults(), backend: fake)
        allowed.setAutomaticInstall(true)
        #expect(fake.automaticallyDownloadsUpdates && allowed.automaticInstall)
    }

    @Test func automaticChecksToggleReachesTheBackend() {
        let fake = FakeUpdater()
        let model = UpdateController.make(infoDictionary: info(configured: true), bundleURL: appURL, normalLaunch: true,
                                          defaults: defaults(), backend: fake)
        model.setAutomaticChecks(true)
        #expect(fake.automaticallyChecksForUpdates && model.automaticChecks)
    }

    @Test func channelSelection() {
        let store = defaults()
        let stable = UpdateController.make(infoDictionary: info(configured: true), bundleURL: appURL, normalLaunch: true,
                                           defaults: store, backend: FakeUpdater())
        #expect(stable.allowedChannels.isEmpty && !stable.betaForced)
        stable.betaOptIn = true
        #expect(stable.allowedChannels == ["beta"])
        // The opt-in persists for the next launch.
        let relaunched = UpdateController.make(infoDictionary: info(configured: true), bundleURL: appURL, normalLaunch: true,
                                               defaults: store, backend: FakeUpdater())
        #expect(relaunched.betaOptIn && relaunched.allowedChannels == ["beta"])
        let beta = UpdateController.make(infoDictionary: info(configured: true, release: "0.1.0-beta.4"), bundleURL: appURL,
                                         normalLaunch: true, defaults: defaults(), backend: FakeUpdater())
        #expect(beta.betaForced && beta.allowedChannels == ["beta"])
    }

    @Test func checkIsRefusedWhileSparkleCannotCheck() {
        let fake = FakeUpdater()
        fake.canCheckForUpdates = false
        let model = UpdateController.make(infoDictionary: info(configured: true), bundleURL: appURL, normalLaunch: true,
                                          defaults: defaults(), backend: fake)
        model.checkForUpdates()
        #expect(fake.checks == 0)
    }
}
