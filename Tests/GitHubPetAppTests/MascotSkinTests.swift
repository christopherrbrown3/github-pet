import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GitHubPet
@testable import GitHubPetCore

@Suite @MainActor struct MascotSkinTests {
    private func newFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    /// A temporary geometric fixture makes stale contours detectable without using a shipped skin.
    private func makePack(_ root: URL, id: String, artY: CGFloat) throws -> URL {
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: artY, width: 256, height: 64))
        let frame = "frames/pose.png"
        let image = try #require(context.makeImage())
        let png = try #require(CGImageDestinationCreateWithURL(folder.appendingPathComponent(frame) as CFURL,
                                                               "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(png, image, nil)
        try #require(CGImageDestinationFinalize(png))
        let states: [String: Any] = Dictionary(uniqueKeysWithValues: MascotState.allCases.map { state in
            (state.rawValue, ["frames": [frame], "durationMs": [400], "loop": state == .idle, "staticFallback": frame])
        })
        let manifest: [String: Any] = ["schemaVersion": 1, "id": id, "name": id,
                                       "canvas": ["width": 256, "height": 256], "anchor": [128, 232], "states": states]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }

    private func model(_ root: URL, defaults: EphemeralDefaults, override: URL? = nil,
                       placeholder: Bool = false) -> AppModel {
        let environment = override.map { ["GITHUB_PET_PACK_DIR": $0.path] } ?? [:]
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--fixtures", "--defaults-suite", "skin-tests"], environment: environment)
        options.forcePlaceholder = placeholder
        options.userDefaultsOverride = defaults
        return AppModel(options: options, runtime: AppModel.Runtime(
            now: { Date(timeIntervalSince1970: 1_790_000_000) }, systemReducedMotion: { false }, schedulesTimers: false,
            mascotPackDirectory: { root.appendingPathComponent($0.rawValue) }))
    }

    @Test func liveChangeKeepsPositionInboxAndAttentionAndRelaunchUsesItsSavedSkin() throws {
        let root = try newFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makePack(root, id: MascotSkin.mona.rawValue, artY: 0)
        _ = try makePack(root, id: MascotSkin.littleChris.rawValue, artY: 192)
        let defaults = EphemeralDefaults(name: "skin-live.tests.\(UUID().uuidString)")
        let app = model(root, defaults: defaults)
        #expect(app.mascotArtwork.source == .builtIn(.mona))
        app.settings.mascotOriginX = 118
        app.settings.mascotOriginY = 141
        let context = try #require(app.inboxDismissalContext)
        let dismissed = try #require(app.items.first { $0.kind == .reviewRequest })
        app.dismissInboxItem(dismissed.id, in: context)
        app.injectEntitlementEvent()
        let baseline = defaults.data(forKey: EventBaselineStore.key)
        let clip = try #require(app.activeClip)
        let rows = app.items, unread = app.unseen, lastSuccess = app.lastSuccess
        let previousLayout = app.layout(128)
        #expect(app.dismissedInboxRows.count == 1)

        app.settings.mascotSkin = .littleChris
        #expect(app.mascotArtwork.source == .builtIn(.littleChris))
        let nextLayout = app.layout(128)
        #expect(previousLayout.laneHeight != nextLayout.laneHeight && previousLayout.ground == nextLayout.ground)
        #expect(app.settings.mascotOriginX == 118 && app.settings.mascotOriginY == 141)
        #expect(app.items == rows && app.unseen == unread && app.activeClip == clip && app.lastSuccess == lastSuccess)
        #expect(app.dismissedInboxRows.count == 1 && defaults.data(forKey: EventBaselineStore.key) == baseline)
        app.replaySnapshot()
        #expect(app.unseen == unread && app.activeClip == clip)

        let relaunched = model(root, defaults: defaults)
        #expect(relaunched.mascotArtwork.source == .builtIn(.littleChris) && relaunched.unseenCount == 0)
        #expect(relaunched.settings.mascotOriginX == 118 && relaunched.settings.mascotOriginY == 141)
        app.settings.mascotSkin = .mona
        #expect(app.mascotArtwork.source == .builtIn(.mona) && app.activeClip == clip)
        #expect(app.layout(128) == previousLayout)
    }

    @Test func rejectedBuiltInFallsBackWithoutRewritingSelection() throws {
        let root = try newFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makePack(root, id: MascotSkin.mona.rawValue, artY: 0)
        let unexpected = try makePack(root, id: "another-pack", artY: 64)
        try FileManager.default.moveItem(at: unexpected, to: root.appendingPathComponent(MascotSkin.littleChris.rawValue))
        let defaults = EphemeralDefaults(name: "skin-fallback.tests.\(UUID().uuidString)")
        let app = model(root, defaults: defaults)
        app.settings.mascotSkin = .littleChris
        #expect(app.mascotArtwork.source == .builtIn(.mona))
        #expect(app.mascotArtwork.notice == "Little Chris is unavailable. Showing Mona.")
        #expect(app.mascotArtwork.errors == [.unexpectedID("another-pack", expected: MascotSkin.littleChris.rawValue)])
        #expect(SettingsStore(defaults: defaults).load().mascotSkin == .littleChris)
    }

    @Test func launchOverridesKeepLegacyValidationAndSavedChoice() throws {
        let root = try newFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makePack(root, id: MascotSkin.mona.rawValue, artY: 0)
        let custom = try makePack(root, id: "terminal-pack", artY: 64)
        let defaults = EphemeralDefaults(name: "skin-override.tests.\(UUID().uuidString)")
        var settings = PetSettings()
        settings.mascotSkin = .littleChris
        SettingsStore(defaults: defaults).save(settings)
        let override = model(root, defaults: defaults, override: custom)
        #expect(override.mascotArtwork.source == .custom && override.mascotArtwork.locksPicker)
        #expect(override.pack?.manifest.id == "terminal-pack")
        let forced = model(root, defaults: defaults, override: custom, placeholder: true)
        #expect(forced.mascotArtwork.source == .placeholder && forced.mascotArtwork.errors.isEmpty)
        let rejected = model(root, defaults: defaults, override: root.appendingPathComponent("missing"))
        #expect(rejected.mascotArtwork.source == .placeholder && rejected.mascotArtwork.locksPicker)
        #expect(rejected.mascotArtwork.errors == [.unreadableManifest])
        #expect(SettingsStore(defaults: defaults).load().mascotSkin == .littleChris)
    }
}
