import AppKit
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

/// Never touches SMAppService: these launches look normal to AppModel, so a fake is injected.
private final class InertLoginBackend: LoginItemBackend, @unchecked Sendable {
    private(set) var calls = 0
    var status: LoginItemStatus { calls += 1; return .disabled }
    func register() throws { calls += 1 }
    func unregister() throws { calls += 1 }
}

/// What the run could have written outside its in-memory defaults: dev.github-pet preference files.
/// (Writes to the real standard domain are excluded by TestDefaultsSourceTests, not read here.)
private struct WriteGuard {
    let defaults: EphemeralDefaults
    let loginBackend: InertLoginBackend
    let preferenceFiles: Set<String>

    static func preferenceFiles() -> Set<String> {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("dev.github-pet") })
    }
}

/// #41: the real mascot window controller's object lifetimes and popover dismissal.
/// Fixtures only (no gh, no network). The defaults are in memory (EphemeralDefaults), so no
/// preferences file is created; the relaunch baseline (#12) a fixtures launch saves lands there too.
@Suite(.serialized) @MainActor struct MascotWindowLifetimeTests {
    private func model() -> (AppModel, WriteGuard) {
        let defaults = EphemeralDefaults(name: "dev.github-pet.tests.mascot-window.\(UUID().uuidString)")
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--fixtures"], environment: [:])
        options.forcePlaceholder = true
        options.userDefaultsOverride = defaults
        _ = NSApplication.shared
        let backend = InertLoginBackend()
        let guarded = WriteGuard(defaults: defaults, loginBackend: backend,
                                 preferenceFiles: WriteGuard.preferenceFiles())
        return (AppModel(options: options, runtime: AppModel.Runtime(loginItemBackend: backend)), guarded)
    }
    private func assertNothingWritten(_ guarded: WriteGuard) {
        #expect(guarded.defaults.object(forKey: SettingsStore.key) == nil, "the test must not persist settings")
        #expect(WriteGuard.preferenceFiles().subtracting(guarded.preferenceFiles).isEmpty,
                "no dev.github-pet preferences file appears")
        #expect(guarded.loginBackend.calls == 0, "the window tests never consult a login item")
    }

    @Test func droppedControllerFreesItsPanelAndContainer() async throws {
        let (app, suite) = model()
        defer { assertNothingWritten(suite) }
        #expect(app.settings.mascotVisible, "default settings show the mascot")
        weak var weakPanel: NSPanel?
        weak var weakContainer: NSView?
        autoreleasepool {
            var controller: MascotWindowController? = MascotWindowController(model: app)
            let panel = try? #require(controller?.panelWindow)
            weakPanel = panel
            weakContainer = panel?.contentView
            #expect(weakContainer is MascotContainerView)
            panel?.orderOut(nil)
            controller = nil
            _ = controller
        }
        // Let any AppKit work queued by ordering out finish before checking.
        for _ in 0..<5 { await Task.yield() }
        #expect(weakContainer == nil, "the hover closure must not keep its container (and the hosting view and model) alive")
        #expect(weakPanel == nil, "the panel goes with its controller")
    }

    /// A popover that macOS dismissed itself (click outside, Esc, a Space change) must not be
    /// re-shown by a later model change while the pointer is elsewhere.
    @Test func systemDismissedSummaryIsNotReopenedByALaterModelChange() async throws {
        let (app, suite) = model()
        defer { assertNothingWritten(suite) }
        let controller = MascotWindowController(model: app)
        defer { controller.panelWindow?.orderOut(nil) }
        controller.showSummaryNow()
        let popover = try #require(controller.summaryPopover)
        #expect(popover.isShown)
        // The dismissal AppKit performs for a semitransient popover: not through hideSummary().
        // Closing may animate, or not under Reduce Motion: wait for the closed state itself.
        popover.close()
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while popover.isShown && ContinuousClock.now < end { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!popover.isShown)
        #expect(controller.summaryPopover == nil, "the controller's state follows the dismissal")
        // A change that alters the summary's content and placement inputs (one new row).
        app.injectEntitlementEvent()
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000) // RunLoop.main delivery of objectWillChange
        #expect(!(controller.summaryPopover?.isShown ?? false), "a dismissed summary stays closed")
        #expect(controller.summaryPopover == nil)
        // Hovering again still opens it.
        controller.showSummaryNow()
        #expect(controller.summaryPopover?.isShown == true)
        controller.summaryPopover?.close()
    }

    /// Re-hovering replaces the summary; the replaced popover's late (animated) close must not
    /// clear the one now shown.
    @Test func replacedSummarysLateCloseKeepsTheCurrentOne() async throws {
        let (app, suite) = model()
        defer { assertNothingWritten(suite) }
        let controller = MascotWindowController(model: app)
        defer { controller.panelWindow?.orderOut(nil) }
        controller.showSummaryNow()
        let first = try #require(controller.summaryPopover)
        controller.showSummaryNow()
        let second = try #require(controller.summaryPopover)
        #expect(first !== second)
        // Deliver the replaced popover's close explicitly, after its successor is installed: with
        // Reduce Motion (or no animation) AppKit closes it at once, while it is still current, so
        // waiting for the real callback would not exercise the identity guard (Copilot, #54).
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: first))
        #expect(controller.summaryPopover === second && second.isShown)
        second.close()
    }
}

/// A real (cfprefsd-backed) domain would leave this file behind; in-memory defaults never do.
func preferencesFileExists(_ domain: String) -> Bool {
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(domain).plist")
    return FileManager.default.fileExists(atPath: file.path)
}
