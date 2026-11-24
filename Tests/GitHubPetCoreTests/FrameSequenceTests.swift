import Foundation
import Testing
@testable import GitHubPetCore

// #138 frame sequences: 16-frame clips at ~70 ms, and the helmet-wearing incident idle loop.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let hat = [AccessoryPolicy.firefighterHat]

private func library(incidentIdle: [Int]? = [150, 150, 150, 150], poke: [Int]? = Array(repeating: 70, count: 16)) -> ClipLibrary {
    var library = ClipLibrary()
    library.accessories = Set(hat)
    if let incidentIdle {
        library.durationsMs[.incidentIdle] = incidentIdle
        library.hidesAccessories.insert(.incidentIdle)
    }
    if let poke { library.durationsMs[.poke] = poke }
    return library
}

private func pose(_ library: ClipLibrary, at seconds: Double, accessories: [MascotAccessoryID] = hat, reduced: Bool = false,
                  stage: ClipStage = .empty, mood: MascotState = .idle) -> MascotPose {
    MascotAnimator.pose(mood: mood, clip: nil, now: t0 + seconds, reducedMotion: reduced, idleEpoch: t0, stage: stage,
                        library: library, accessories: accessories) { _ in [2000, 125, 125, 2000] }
}

@Suite struct FrameSequenceTests {
    @Test func duringAnIncidentTheHelmetIdleLoopReplacesIdleAndTheOverlay() {
        let playing = pose(library(), at: 0.35)
        #expect(playing.clip?.id == .incidentIdle)
        #expect(playing.clip?.frame == 2, "150 ms frames from the idle epoch")
        #expect(playing.accessories.isEmpty, "the loop draws its own helmet")
        // No incident: the ordinary idle loop.
        #expect(pose(library(), at: 0.35, accessories: []).clip == nil)
        // A pack without the loop keeps idle plus the hat overlay.
        let overlay = pose(library(incidentIdle: nil), at: 0.35)
        #expect(overlay.clip == nil && overlay.accessories == hat)
        // Attention and urgent keep their poses.
        #expect(pose(library(), at: 0.35, mood: .attention).clip == nil)
        // Reduce Motion: the loop's still pose, no overlay.
        let still = pose(library(), at: 0.35, reduced: true)
        #expect(still.clip?.id == .incidentIdle && still.clip?.frame == nil && still.accessories.isEmpty)
    }

    @Test func clipFramesFasterThanStateFramesKeepTheirTiming() {
        let stage = ClipStage(scheduled: .init(id: .poke, tier: .reaction, priority: ClipPriority.poke, gate: .always,
                                               startedAt: t0, endsAt: t0 + 1.12))
        #expect(pose(library(), at: 0.15, accessories: [], stage: stage).clip?.frame == 2, "70 ms frames, not clamped to 125")
        #expect(pose(library(), at: 1.10, accessories: [], stage: stage).clip?.frame == 15)
        #expect(library().hasFastClips)
        #expect(!library(poke: [200, 200]).hasFastClips)
        #expect(!library(poke: nil).hasFastClips, "the incident loop alone does not need 60 fps")
    }

    @Test func sixteenFrameClipsValidateAndStatesKeepTheirMinimum() {
        let frames = (0..<16).map { "frames/poke-\($0).png" }
        var manifest = MascotPackManifest(
            schemaVersion: 2, id: "x", name: "x", canvas: .init(width: 256, height: 256), anchor: MascotPack.anchor,
            states: [:], clips: ["poke": .init(frames: frames, durationMs: Array(repeating: 70, count: 16))])
        #expect(MascotPack.validateV2Structure(manifest, budget: .bundled).isEmpty)
        manifest.states["incident-idle"] = .init(frames: ["frames/a.png", "frames/b.png"], durationMs: [150, 150], loop: true,
                                                 staticFallback: "frames/a.png")
        #expect(MascotPack.validateV2Structure(manifest, budget: .bundled).isEmpty, "the incident idle is a known loop")
        manifest.clips?["poke"] = .init(frames: frames + ["frames/x.png"], durationMs: Array(repeating: 70, count: 17))
        #expect(MascotPack.validateV2Structure(manifest, budget: .bundled).contains(.frameCount("poke")))
        manifest.clips?["poke"] = .init(frames: ["frames/a.png"], durationMs: [30])
        #expect(MascotPack.validateV2Structure(manifest, budget: .bundled).contains(.durationOutOfRange("poke", 30)))
    }
}
