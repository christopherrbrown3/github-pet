import CoreGraphics
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
        // A sequence pack draws the helmet itself and has no hat overlay: the incident still plays the loop.
        var drawn = library()
        drawn.accessories = []
        let loop = pose(drawn, at: 0.35)
        #expect(loop.clip?.id == .incidentIdle && loop.accessories.isEmpty)
        #expect(pose(drawn, at: 0.35, reduced: true).clip?.id == .incidentIdle)
        #expect(pose(drawn, at: 0.35, mood: .attention).accessories.isEmpty, "no overlay anywhere")
        // A pack without the loop keeps idle plus the hat overlay.
        let overlay = pose(library(incidentIdle: nil), at: 0.35)
        #expect(overlay.clip == nil && overlay.accessories == hat)
        // Attention and urgent wear it too (Chris's incident rule).
        #expect(pose(library(), at: 0.35, mood: .attention).clip?.id == .incidentIdle)
        // Reduce Motion: the loop's still pose, no overlay.
        let still = pose(library(), at: 0.35, reduced: true)
        #expect(still.clip?.id == .incidentIdle && still.clip?.frame == nil && still.accessories.isEmpty)
    }

    @Test func duringAnIncidentTheHelmetLoopStandsInForEveryMoodAndSuppressedClip() {
        var lib = library()
        lib.accessories = []
        for id in [MascotClipID.itemCleared, .inboxZero, .idleLook, .drop, .dizzy] { lib.durationsMs[id] = Array(repeating: 70, count: 16) }
        lib.durationsMs[.drag] = [200, 200, 200, 200]
        func scheduled(_ id: MascotClipID) -> ClipStage {
            let policy = ClipCatalog.v1[id]!
            return ClipStage(scheduled: .init(id: id, tier: policy.tier, priority: policy.priority, gate: policy.gate,
                                              startedAt: t0, endsAt: t0 + 1.12))
        }
        for mood in MascotState.allCases {
            #expect(pose(lib, at: 0.2, mood: mood).clip?.id == .incidentIdle, "\(mood) wears the helmet")
            #expect(pose(lib, at: 0.2, reduced: true, mood: mood).clip?.id == .incidentIdle, "\(mood) still, Reduce Motion")
        }
        for id in [MascotClipID.itemCleared, .inboxZero, .idleLook] {
            #expect(pose(lib, at: 0.2, stage: scheduled(id)).clip?.id == .incidentIdle, "\(id) suppressed")
        }
        for id in [MascotClipID.poke, .drop, .dizzy] {
            #expect(pose(lib, at: 0.2, stage: scheduled(id)).clip?.id == id, "\(id) still plays")
        }
        #expect(pose(lib, at: 0.2, stage: ClipStage(dragStart: t0)).clip?.id == .drag)
        // Without an incident the clips play as before.
        #expect(pose(lib, at: 0.2, accessories: [], stage: scheduled(.itemCleared)).clip?.id == .itemCleared)
        // A pack without the loop keeps v1 behaviour: the clips play and the overlay is drawn.
        var v1 = library(incidentIdle: nil)
        v1.durationsMs[.itemCleared] = [200, 200]
        #expect(pose(v1, at: 0.2, stage: scheduled(.itemCleared)).clip?.id == .itemCleared)
    }

    @Test func reactionsWearTheHelmetWhenThePackDrawsAVariant() {
        var lib = library()
        lib.accessories = []
        lib.durationsMs[.drag] = [200, 200]
        lib.durationsMs[IncidentRule.variant(of: .poke)] = Array(repeating: 70, count: 16)
        lib.durationsMs[IncidentRule.variant(of: .drag)] = [200, 200, 200, 200]
        let policy = ClipCatalog.v1[.poke]!
        let poke = ClipStage(scheduled: .init(id: .poke, tier: policy.tier, priority: policy.priority, gate: policy.gate,
                                              startedAt: t0, endsAt: t0 + 1.12))
        #expect(pose(lib, at: 0.2, stage: poke).clip?.id == "poke-incident")
        #expect(pose(lib, at: 0.2, accessories: [], stage: poke).clip?.id == .poke, "no incident: the plain clip")
        #expect(pose(lib, at: 0.5, stage: ClipStage(dragStart: t0)).clip?.id == "drag-incident")
        #expect(pose(lib, at: 0.5, reduced: true, stage: ClipStage(dragStart: t0)).clip?.id == "drag-incident",
                "Reduce Motion: the helmet drag still")
        #expect(IncidentRule.base(of: "dizzy-incident") == .dizzy && IncidentRule.base(of: "new-item-incident") == nil)
        // A variant validates under its clip's rules; an unknown one doesn't.
        let frames = (0..<16).map { "frames/poke-incident-\($0).png" }
        var manifest = MascotPackManifest(
            schemaVersion: 2, id: "x", name: "x", canvas: .init(width: 256, height: 256), anchor: MascotPack.anchor, states: [:],
            clips: ["poke-incident": .init(frames: frames, durationMs: Array(repeating: 70, count: 16))])
        #expect(MascotPack.validateV2Structure(manifest, budget: .bundled).isEmpty)
        manifest.clips?["new-item-incident"] = .init(frames: frames, durationMs: Array(repeating: 70, count: 16))
        #expect(MascotPack.validateV2Structure(manifest, budget: .bundled).contains(.unknownClip("new-item-incident")))
        manifest.clips = nil
        manifest.states["drag-incident"] = .init(frames: ["frames/a.png"], durationMs: [200], loop: true, staticFallback: "frames/a.png")
        #expect(MascotPack.validateV2Structure(manifest, budget: .bundled).isEmpty)
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

    @Test func theMistFollowsTheClipsNozzleFrames() {
        let nozzle = CGPoint(x: 60, y: 200)
        // Spraying 0.14–0.56 s: puffs from the start of the window, none before it.
        #expect(ClipEffects.particles(clip: .incidentEnd, elapsed: 0.10, head: .zero, nozzle: nozzle, hand: .zero,
                                      sprayWindow: 0.14...0.56).isEmpty)
        #expect(!ClipEffects.particles(clip: .incidentEnd, elapsed: 0.20, head: .zero, nozzle: nozzle, hand: .zero,
                                       sprayWindow: 0.14...0.56).isEmpty)
        // Still drifting just after the window, gone half a second later.
        #expect(!ClipEffects.particles(clip: .incidentEnd, elapsed: 0.70, head: .zero, nozzle: nozzle, hand: .zero,
                                       sprayWindow: 0.14...0.56).isEmpty)
        #expect(ClipEffects.particles(clip: .incidentEnd, elapsed: 1.10, head: .zero, nozzle: nozzle, hand: .zero,
                                      sprayWindow: 0.14...0.56).isEmpty)
        // v1 timing without a window.
        #expect(ClipEffects.particles(clip: .incidentEnd, elapsed: 0.20, head: .zero, nozzle: nozzle, hand: .zero).isEmpty)
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
