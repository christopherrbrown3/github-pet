import Foundation
import Testing
@testable import GitHubPetCore

/// #138 motion layer: eased transforms and blends over a clip's key poses, on the clip clock.
@Suite struct ClipMotionTests {
    let durations = [220, 230, 380, 320, 750]
    var newItem: ClipMotion { ClipMotion.catalog[.newItem]! }

    private func bundled(_ skin: MascotSkin) throws -> MascotPack {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try MascotPack.load(from: root.appendingPathComponent("assets/mascots/\(skin.rawValue)"),
                                   expectedID: skin.rawValue, budget: .bundled).get()
    }

    @Test func transformsAreContinuousAndPeakOnTheKeys() {
        var previous = newItem.sample(durationsMs: durations, elapsedMs: 0)
        for ms in stride(from: 1.0, through: 1900, by: 1) {
            let sample = newItem.sample(durationsMs: durations, elapsedMs: ms)
            // No pops: at most a small step per millisecond in scale and lift.
            #expect(abs(sample.scaleX - previous.scaleX) < 0.004 && abs(sample.scaleY - previous.scaleY) < 0.004, "\(ms)")
            #expect(abs(sample.lift - previous.lift) < 0.2, "\(ms)")
            previous = sample
        }
        // Anticipation squash where the crouch lands, stretch where the tiptoe lands.
        let crouch = newItem.sample(durationsMs: durations, elapsedMs: 220), launch = newItem.sample(durationsMs: durations, elapsedMs: 450)
        #expect(crouch.frame == 1 && crouch.scaleY < 0.95 && crouch.scaleX > 1.03)
        #expect(launch.frame == 2 && launch.scaleY > 1.04 && launch.lift > 0)
    }

    @Test func blendsStartFromTheEntryPoseAndEndOnTheExitPose() {
        let start = newItem.sample(durationsMs: durations, elapsedMs: 0)
        #expect(start.partner == .entry && start.partnerWeight == 1)
        #expect(start.matchTo == .entry && start.matchWeight == 1)
        let end = newItem.sample(durationsMs: durations, elapsedMs: 1900)
        #expect(end.partner == .exit && end.partnerWeight == 1)
        // The waggle swap (close silhouettes) dissolves; the others are hidden by motion peaks only.
        let waggle = newItem.sample(durationsMs: durations, elapsedMs: 830)
        #expect(waggle.partner == .frame(2) && abs(waggle.partnerWeight - 0.5) < 0.01)
        #expect(newItem.sample(durationsMs: durations, elapsedMs: 450).partner == nil)
        // An incoming pose starts at the outgoing pose's height.
        let swap = newItem.sample(durationsMs: durations, elapsedMs: 220)
        #expect(swap.matchTo == .frame(0) && swap.matchWeight == 1)
    }

    @Test func littleChrisNewItemStaysInsideItsArtWithoutPopping() throws {
        let pack = try bundled(.littleChris)
        let spec = try #require(pack.manifest.clipSpec(.newItem))
        let limit = pack.artLimit
        let entry = pack.manifest.states["idle"]?.staticFallback, exit = pack.manifest.states["attention"]?.staticFallback
        var previousTop: Double?
        for ms in stride(from: 0.0, through: Double(spec.durationMs.reduce(0, +)), by: 1000.0 / 30) {
            let pose = MascotPose(state: .attention, frame: nil, clipElapsed: ms / 1000,
                                  clip: ClipFrame(id: .newItem, frame: nil, elapsed: ms / 1000))
            let motion = try #require(pack.motion(for: pose, entryPath: entry, exitPath: exit))
            var drawnTop = Double.infinity
            for layer in motion.layers {
                let box = try #require(pack.extraOutlines[layer.path]?.bounds)
                let top = ResolvedMotion.apply(layer, x: 128, y: Double(box.top)).y
                let left = ResolvedMotion.apply(layer, x: Double(box.minX), y: 0).x
                let right = ResolvedMotion.apply(layer, x: Double(box.maxX), y: 0).x
                #expect(top >= Double(min(limit[2], box.top)) - 0.001, "top at \(ms) ms")
                #expect(left >= Double(min(limit[0], box.minX)) - 0.001 && right <= Double(max(limit[1], box.maxX)) + 0.001, "sides at \(ms) ms")
                if layer.opacity >= 1 { drawnTop = min(drawnTop, top) }
            }
            // No pops: the silhouette's top moves at most 8 canvas px (2 pt at 64 pt) per 30 fps frame.
            if let previousTop, drawnTop.isFinite { #expect(abs(drawnTop - previousTop) <= 8, "jump at \(ms) ms") }
            if drawnTop.isFinite { previousTop = drawnTop }
            // The count tracks the moving art.
            #expect(pack.contour(for: pose, motion: motion) != nil)
        }
    }

    @Test func clipsWithoutMotionAndReducedMotionAreUnchanged() throws {
        let pack = try bundled(.littleChris)
        let now = Date(timeIntervalSince1970: 1_000)
        let doze = MascotPose(state: .idle, frame: nil, clipElapsed: nil, clip: ClipFrame(id: .doze, frame: 0, elapsed: 1))
        #expect(pack.motion(for: doze, entryPath: nil, exitPath: nil) == nil)
        // Reduce Motion never plays a clip, so there is never a motion layer.
        let clip = EventClipQueue.Clip(event: InboxEvent(item: InboxItem(id: "review:motion", kind: .reviewRequest, repository: "example/pet-demo",
                                                                  title: "Motion", url: nil, updatedAt: now, isDemo: true),
                                                  severity: .actionable),
                                       startedAt: now, origin: .repository, kind: .newItem)
        let library = ClipLibrary(pack: pack)
        let playing = MascotAnimator.pose(mood: .attention, clip: clip, now: now.addingTimeInterval(0.5), reducedMotion: false,
                                          idleEpoch: .distantPast, library: library) { _ in [300] }
        #expect(playing.clip?.id == .newItem && pack.motion(for: playing, entryPath: nil, exitPath: nil) != nil)
        let reduced = MascotAnimator.pose(mood: .attention, clip: clip, now: now.addingTimeInterval(0.5), reducedMotion: true,
                                          idleEpoch: .distantPast, library: library) { _ in [300] }
        #expect(reduced.clip == nil && pack.motion(for: reduced, entryPath: nil, exitPath: nil) == nil)
    }
}
