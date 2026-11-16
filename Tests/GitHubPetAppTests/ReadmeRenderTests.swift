import AppKit
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

/// Counts every call; README renders must never consult the model's own login item backend.
private final class CountingLoginBackend: LoginItemBackend, @unchecked Sendable {
    private(set) var calls = 0
    var status: LoginItemStatus { calls += 1; return .enabled }
    func register() throws { calls += 1 }
    func unregister() throws { calls += 1 }
}

/// #61: the README presentation (no Simulator menu, neutral Startup, privacy off, a Demo
/// entitlement repository) exists only inside the offscreen renderer. Normal launches keep
/// their behaviour, and the renderer leaves the model exactly as it found it.
@Suite(.serialized) @MainActor struct ReadmeRenderTests {
    private func model(_ backend: CountingLoginBackend) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--fixtures"], environment: [:])
        options.forcePlaceholder = true
        options.userDefaultsOverride = EphemeralDefaults(name: "dev.github-pet.tests.readme.\(UUID().uuidString)")
        _ = NSApplication.shared
        return AppModel(options: options, runtime: AppModel.Runtime(schedulesTimers: false, loginItemBackend: backend))
    }

    @Test func normalViewsKeepTheirControls() {
        let app = model(CountingLoginBackend())
        #expect(InboxView(model: app).showsSimulator, "the Simulator menu stays in every real inbox")
        #expect(InboxView(model: app).showsWindowButton && InboxView(model: app).marksSeenOnClose)
    }

    @Test func readmeRendersRestoreTheModelAndNeverTouchItsLoginItem() async throws {
        let backend = CountingLoginBackend()
        let app = model(backend)
        app.refresh()
        let settings = app.settings, items = app.items
        #expect(settings.privacyMode && settings.entitlementRepositories.isEmpty, "defaults before the render")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = await SnapshotRenderer.readmeRenders(model: app, directory: directory)

        #expect(report.first == "## readme")
        for name in ["readme-inbox", "readme-hover", "readme-settings-scope", "readme-settings-general"] {
            for suffix in ["", "-dark"] {
                #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name)\(suffix).png").path),
                        "\(name)\(suffix).png")
            }
        }
        #expect(app.settings == settings, "privacy, entitlement list and every other setting are restored")
        #expect(app.items == items, "rows are back to their source kinds")
        #expect(backend.calls == 0, "the README Startup state comes from an inert stand-in, not the app's backend")
    }
}
