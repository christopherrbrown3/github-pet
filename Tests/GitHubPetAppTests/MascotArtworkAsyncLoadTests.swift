import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GitHubPet
@testable import GitHubPetCore

/// A pack directory lookup that can be held on the background thread until the test releases it.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private(set) var entered = DispatchSemaphore(value: 0)
    func wait() { entered.signal(); semaphore.wait() }
    func open() { semaphore.signal() }
}

/// #41: packs load off the main thread; a stale load never overwrites a newer choice.
@Suite @MainActor struct MascotArtworkAsyncLoadTests {
    private func makePack(_ root: URL, id: String) throws {
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 64))
        let png = try #require(CGImageDestinationCreateWithURL(folder.appendingPathComponent("frames/pose.png") as CFURL,
                                                               "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(png, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(png))
        let states: [String: Any] = Dictionary(uniqueKeysWithValues: MascotState.allCases.map { state in
            (state.rawValue, ["frames": ["frames/pose.png"], "durationMs": [400], "loop": state == .idle,
                              "staticFallback": "frames/pose.png"])
        })
        let manifest: [String: Any] = ["schemaVersion": 1, "id": id, "name": id,
                                       "canvas": ["width": 256, "height": 256], "anchor": [128, 232], "states": states]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
    }

    private func newRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("async-pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try makePack(root, id: MascotSkin.mona.rawValue)
        try makePack(root, id: MascotSkin.littleChris.rawValue)
        return root
    }

    private func model(_ root: URL, gates: [MascotSkin: Gate] = [:], override: URL? = nil,
                       skin: MascotSkin = .mona) -> AppModel {
        let environment = override.map { ["GITHUB_PET_PACK_DIR": $0.path] } ?? [:]
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--fixtures", "--defaults-suite", "async-pack-tests"],
                                          environment: environment)
        let defaults = EphemeralDefaults(name: "async-pack.tests.\(UUID().uuidString)")
        var settings = PetSettings()
        settings.mascotSkin = skin
        SettingsStore(defaults: defaults).save(settings)
        options.userDefaultsOverride = defaults
        return AppModel(options: options, runtime: AppModel.Runtime(
            now: { Date(timeIntervalSince1970: 1_790_000_000) }, systemReducedMotion: { false }, schedulesTimers: false,
            mascotPackDirectory: { gates[$0]?.wait(); return root.appendingPathComponent($0.rawValue) },
            loadsMascotArtworkAsync: true))
    }

    @Test func launchDoesNotWaitForThePackAndThenShowsIt() async throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        let app = model(root, gates: [.mona: gate])
        // The loader is parked on the background thread, yet the model was built and is usable.
        #expect(app.mascotArtworkLoading)
        #expect(app.mascotArtwork.source == .placeholder && app.pack == nil)
        #expect(app.mascotArtwork.notice == "Loading the mascot…")
        gate.open()
        await app.mascotArtworkSettled()
        #expect(!app.mascotArtworkLoading)
        #expect(app.mascotArtwork.source == .builtIn(.mona) && app.pack != nil)
    }

    @Test func aStaleLoadNeverOverwritesANewerChoice() async throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let slow = Gate()
        let app = model(root, gates: [.littleChris: slow])
        await app.mascotArtworkSettled()
        #expect(app.mascotArtwork.source == .builtIn(.mona))
        app.settings.mascotSkin = .littleChris        // parked on the background thread
        app.settings.mascotSkin = .mona               // newer choice
        await Task.detached { slow.entered.wait() }.value
        slow.open()                                   // the older load finishes after the newer request
        await app.mascotArtworkSettled()
        #expect(app.mascotArtwork.source == .builtIn(.mona))
        #expect(app.settings.mascotSkin == .mona)
        #expect(!app.mascotArtworkLoading)
    }

    @Test func theLastPackStaysOnScreenWhileTheNextLoads() async throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        let app = model(root, gates: [.littleChris: gate])
        await app.mascotArtworkSettled()
        let before = app.layout(128)
        app.settings.mascotSkin = .littleChris
        #expect(app.mascotArtworkLoading)
        #expect(app.mascotArtwork.source == .builtIn(.mona) && app.layout(128) == before)
        gate.open()
        await app.mascotArtworkSettled()
        #expect(app.mascotArtwork.source == .builtIn(.littleChris) && !app.mascotArtworkLoading)
    }

    @Test func aLaunchOverrideKeepsThePickerLockedFromTheStartAndIgnoresSkinChanges() async throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("no-such-pack")
        let app = model(root, override: missing)
        #expect(app.mascotArtwork.locksPicker)
        await app.mascotArtworkSettled()
        #expect(app.mascotArtwork.source == .placeholder && app.mascotArtwork.locksPicker && !app.mascotArtwork.errors.isEmpty)
        app.settings.mascotSkin = .littleChris
        #expect(!app.mascotArtworkLoading && app.mascotArtwork.source == .placeholder)
    }

    @Test func switchingBackToALoadedSkinReusesItsVerifiedResult() async throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = model(root)
        app.settings.mascotSkin = .littleChris
        await app.mascotArtworkSettled()
        try FileManager.default.removeItem(at: root.appendingPathComponent(MascotSkin.mona.rawValue))
        app.settings.mascotSkin = .mona
        await app.mascotArtworkSettled()
        #expect(app.mascotArtwork.source == .builtIn(.mona), "served from the cache, not reread from disk")
    }
}
