import Foundation
import AppKit
import GitHubPetCore
import Testing
@testable import GitHubPet

/// Never starts Sparkle or reaches the network. Shared with the accessibility tests.
@MainActor
final class FakeUpdater: UpdaterBackend {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var lastUpdateCheckDate: Date? = Date(timeIntervalSince1970: 1_800_000_000)
    var updateCheckInterval: TimeInterval = 21_600
    var checks = 0
    var backgroundChecks = 0
    func checkForUpdates() { checks += 1 }
    func checkForUpdatesInBackground() { backgroundChecks += 1 }

    /// A configured controller (valid feed and key) on this fake, with in-memory defaults.
    static func controller(_ fake: FakeUpdater? = nil, defaults: UserDefaults? = nil,
                           now: @escaping () -> Date = Date.init) -> UpdateController {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "214", "SUAllowsAutomaticUpdates": true,
                                   "SUFeedURL": "https://example.com/appcast.xml",
                                   "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString()]
        let controller = UpdateController(installed: InstalledBuild(infoDictionary: info), configuration: UpdateConfiguration(infoDictionary: info),
                                          defaults: defaults ?? EphemeralDefaults.named("dev.github-pet.tests.update-\(UUID().uuidString)"),
                                          backend: fake ?? FakeUpdater(), now: now)
        controller.announce = { _ in }
        return controller
    }
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

    @Test func sparklesFirstRunPromptCannotTurnOnSilentInstall() {
        // The prompt writes automaticallyDownloadsUpdates itself; only Settings' toggle may keep it on.
        let fake = FakeUpdater()
        let store = defaults()
        let model = UpdateController.make(infoDictionary: info(configured: true), bundleURL: appURL, normalLaunch: true,
                                          defaults: store, backend: fake)
        fake.automaticallyDownloadsUpdates = true
        model.refresh()
        #expect(!fake.automaticallyDownloadsUpdates && !model.automaticInstall)
        model.setAutomaticInstall(true)
        model.refresh()
        #expect(fake.automaticallyDownloadsUpdates && model.automaticInstall)
        // The explicit choice survives a relaunch; turning it off is honoured too.
        let relaunched = UpdateController.make(infoDictionary: info(configured: true), bundleURL: appURL, normalLaunch: true,
                                               defaults: store, backend: fake)
        #expect(relaunched.automaticInstall)
        relaunched.setAutomaticInstall(false)
        #expect(!fake.automaticallyDownloadsUpdates)
    }

    @Test func aStagedSilentUpdateIsShownQuietly() {
        let model = UpdateController.make(infoDictionary: info(configured: true), bundleURL: appURL, normalLaunch: true,
                                          defaults: defaults(), backend: FakeUpdater())
        #expect(model.readyVersion == nil)
        model.ready("0.1.0-beta.4")
        #expect(model.readyVersion == "0.1.0-beta.4")
    }

    // MARK: #149 proactive checks and the indicator

    @Test func backgroundCheckRunsOnlyWhenOverdueAllowedAndIdle() {
        let fake = FakeUpdater()
        let start = fake.lastUpdateCheckDate!
        var clock = start.addingTimeInterval(3_600)
        let model = FakeUpdater.controller(fake, now: { clock })
        // Automatic checks off (the user's choice): never.
        #expect(!model.checkInBackgroundIfOverdue())
        fake.automaticallyChecksForUpdates = true
        // Within the interval: not yet.
        #expect(!model.checkInBackgroundIfOverdue())
        clock = start.addingTimeInterval(21_600)
        // Sparkle busy (a session or download in progress): not now.
        fake.canCheckForUpdates = false
        #expect(!model.checkInBackgroundIfOverdue())
        fake.canCheckForUpdates = true
        #expect(model.checkInBackgroundIfOverdue())
        // Never the user-initiated (windowed) check, and never a setting change.
        #expect(fake.backgroundChecks == 1 && fake.checks == 0)
        #expect(fake.automaticallyChecksForUpdates && !fake.automaticallyDownloadsUpdates)
        fake.lastUpdateCheckDate = nil
        #expect(model.checkInBackgroundIfOverdue(), "a never-checked install checks soon after launch")
    }

    @Test func launchAndWakeScheduleOneBackgroundCheck() async throws {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        fake.lastUpdateCheckDate = nil
        let center = NotificationCenter()
        let model = FakeUpdater.controller(fake)
        model.scheduleProactiveChecks(wakeCenter: center, launchDelay: .milliseconds(10), wakeDelay: .milliseconds(10))
        try await waitUntil { fake.backgroundChecks == 1 }
        // Several wakes in a row collapse into one check.
        for _ in 0..<3 { center.post(name: NSWorkspace.didWakeNotification, object: nil) }
        try await waitUntil { fake.backgroundChecks == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.backgroundChecks == 2)
        // Checked just now: a wake does nothing.
        fake.lastUpdateCheckDate = Date()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.backgroundChecks == 2)
    }

    @Test func noProactiveChecksWithoutAnUpdater() async throws {
        let model = UpdateController.make(infoDictionary: info(configured: false), bundleURL: appURL, normalLaunch: true,
                                          defaults: defaults(), backend: FakeUpdater())
        model.scheduleProactiveChecks(wakeCenter: NotificationCenter(), launchDelay: .zero, wakeDelay: .zero)
        #expect(!model.checkInBackgroundIfOverdue())
    }

    @Test func indicatorFollowsAFoundUpdateAndIsAnnouncedOnce() {
        let model = FakeUpdater.controller()
        var announced: [String] = []
        model.announce = { announced.append($0) }
        #expect(model.indicatorVersion == nil && model.indicatorAccessibilityText == nil)
        model.found("0.1.0-beta.7")
        model.found("0.1.0-beta.7")
        #expect(model.indicatorVersion == "0.1.0-beta.7")
        #expect(model.indicatorAccessibilityText == "update available: version 0.1.0-beta.7")
        #expect(announced == ["Update available: version 0.1.0-beta.7"])
        // "Update…" hands over to Sparkle's normal (consent-asking) flow and clears the indicator.
        model.checkForUpdates()
        #expect(model.indicatorVersion == nil && model.pendingVersion == nil)
        // A staged silent install is not "available": the quiet menu line covers it.
        model.ready("0.1.0-beta.7")
        #expect(model.indicatorVersion == nil)
    }

    @Test func laterHidesThisVersionForADayAndSurvivesRelaunch() {
        let store = defaults()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = start
        let model = FakeUpdater.controller(defaults: store, now: { clock })
        model.found("0.1.0-beta.7")
        model.dismissIndicator()
        #expect(model.indicatorVersion == nil)
        // The quiet menu/Settings line still says so.
        #expect(model.pendingVersion == "0.1.0-beta.7")
        #expect(model.indicatorVersion == nil, "the footer's quiet line shows again once the banner is hidden")
        let relaunched = FakeUpdater.controller(defaults: store, now: { clock })
        relaunched.found("0.1.0-beta.7")
        #expect(relaunched.indicatorVersion == nil)
        // A newer version shows at once.
        relaunched.found("0.1.0-beta.8")
        #expect(relaunched.indicatorVersion == "0.1.0-beta.8")
        // The same version comes back after 24 hours.
        clock = start.addingTimeInterval(86_400)
        model.updateIndicator()
        #expect(model.indicatorVersion == "0.1.0-beta.7")
    }

    @Test func indicatorNeverTouchesTheInboxBadge() throws {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--render-snapshots", "/tmp/unused-updates", "--placeholder"],
                                          environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "dev.github-pet.tests.update-badge.\(UUID().uuidString)")
        let app = AppModel(options: options, runtime: AppModel.Runtime(systemReducedMotion: { true }, schedulesTimers: false))
        app.showFixtureItemsForSnapshot(SnapshotRenderer.inbox87Items(4))
        let before = (app.badge, app.mascotBadge, app.statusAccessibilityLabel, app.showsAlertIcon)
        app.updates.found("0.1.0-beta.7")
        #expect(app.badge == before.0 && app.mascotBadge == before.1)
        #expect(app.statusAccessibilityLabel == before.2 && app.showsAlertIcon == before.3)
        #expect(app.updates.indicatorVersion == "0.1.0-beta.7")
        #expect(MenuBarLabel.accessibilityLabel(model: app, updates: app.updates)
                == "\(before.2), update available: version 0.1.0-beta.7")
        app.updates.found(nil)
    }

    @Test func menuBarIconGainsADotOnlyWithAnUpdate() {
        let plain = MenuBarIcon.image(symbol: "pawprint", dot: false)
        let dotted = MenuBarIcon.image(symbol: "pawprint", dot: true)
        #expect(plain.isTemplate && dotted.isTemplate)
        // Same canvas: the menu-bar item keeps its width and baseline when the dot appears.
        #expect(dotted.size == plain.size)
        func ink(_ image: NSImage) -> Int {
            guard let rep = image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)) else { return 0 }
            var count = 0
            for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { count += 1 } }
            return count
        }
        #expect(ink(dotted) != ink(plain), "the dot changes the drawn image")
    }

    @Test func menuBarCountKeepsOneCanvasAcrossCountsAndTheDot() {
        let counts: [String?] = [nil, "1", "9", "99+", "?"]
        for dot in [false, true] {
            let sizes = counts.map { MenuBarIcon.image(symbol: "pawprint", dot: dot, count: $0, showsCount: true).size }
            #expect(Set(sizes.map(\.width)).count == 1 && Set(sizes.map(\.height)).count == 1)
        }
        let bare = MenuBarIcon.image(symbol: "pawprint", dot: false)
        let slot = MenuBarIcon.image(symbol: "pawprint", dot: false, count: nil, showsCount: true)
        #expect(slot.size.width > bare.size.width && slot.size.height == bare.size.height)
        #expect(MenuBarIcon.image(symbol: "pawprint", dot: true).size == bare.size)
        #expect(slot.isTemplate)
    }

    @Test func menuBarCountDrawsOnlyWhenThereIsOne() {
        func ink(_ image: NSImage) -> Int {
            guard let rep = image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)) else { return 0 }
            var count = 0
            for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { count += 1 } }
            return count
        }
        for dot in [false, true] {
            let empty = ink(MenuBarIcon.image(symbol: "pawprint", dot: dot, count: nil, showsCount: true))
            for text in ["1", "9", "99+", "?"] {
                #expect(ink(MenuBarIcon.image(symbol: "pawprint", dot: dot, count: text, showsCount: true)) > empty, "\(text) dot=\(dot)")
            }
            // A count without a reserved slot is never drawn.
            #expect(ink(MenuBarIcon.image(symbol: "pawprint", dot: dot, count: "9")) == ink(MenuBarIcon.image(symbol: "pawprint", dot: dot)))
        }
    }

    @Test func menuBarShowsThePetsBadgeOnlyWhileThePetIsHidden() {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--render-snapshots", "/tmp/unused-menubar", "--placeholder"],
                                          environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "dev.github-pet.tests.menubar-count.\(UUID().uuidString)")
        let app = AppModel(options: options, runtime: AppModel.Runtime(systemReducedMotion: { true }, schedulesTimers: false))
        app.showFixtureItemsForSnapshot(SnapshotRenderer.inbox87Items(4))
        app.settings.mascotVisible = true
        #expect(app.menuBarCount == nil && !app.showsMenuBarCount)
        app.settings.mascotVisible = false
        #expect(app.showsMenuBarCount && app.menuBarCount == app.mascotBadge && app.menuBarCount == "4")
        #expect(MenuBarLabel.accessibilityLabel(model: app, updates: app.updates).contains("4 items"))
        app.showFixtureItemsForSnapshot([])
        #expect(app.showsMenuBarCount && app.menuBarCount == app.mascotBadge)
        app.markStale()
        #expect(app.menuBarCount == "?")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }
}
