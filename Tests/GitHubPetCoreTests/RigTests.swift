import CoreGraphics
import Foundation
import Testing
@testable import GitHubPetCore

// #138: the cutout rig (schema v3): curves, evaluation, pack loading, bounds and the clip path.

private typealias K = RigSpec.Key
private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func placeholderPack(edit: ((inout MascotPackManifest) -> Void)? = nil,
                             budget: PackBudget = .custom) throws -> Result<MascotPack, MascotPackErrors> {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rig-tests-\(UUID().uuidString)")
    try RigPlaceholder.write(to: directory)
    if let edit {
        let url = directory.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(MascotPackManifest.self, from: Data(contentsOf: url))
        edit(&manifest)
        try JSONEncoder().encode(manifest).write(to: url)
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    return MascotPack.load(from: directory, budget: budget)
}

private func pose(_ ms: Double, angle: Double = 0) -> MascotPose {
    MascotPose(state: .attention, frame: nil, clipElapsed: ms / 1000, angle: angle,
               clip: ClipFrame(id: .newItem, frame: 0, elapsed: ms / 1000))
}

@Suite struct RigEaseTests {
    @Test func everyCurveStartsAtZeroAndLandsExactlyOnOne() {
        for ease in RigEase.allCases {
            #expect(ease.apply(0) == 0, "\(ease)")
            #expect(ease.apply(1) == 1, "\(ease)")
        }
        #expect(abs(RigEase.inOut.apply(0.5) - 0.5) < 1e-6, "symmetric")
        #expect(RigEase.out.apply(0.3) > 0.6, "fast start, soft landing")
        #expect(RigEase.in.apply(0.3) < 0.15, "slow start")
        #expect((0...100).map { RigEase.back.apply(Double($0) / 100) }.max()! > 1.05, "overshoots before settling")
        #expect((0...100).map { RigEase.spring.apply(Double($0) / 100) }.contains { $0 > 1.1 }, "springs past the target")
        #expect(RigEase.hold.apply(0.99) == 0)
    }

    @Test func tracksInterpolateWithTheArrivingKeysEase() {
        let keys = [K(0, 0), K(100, 10, .linear), K(200, 10), K(300, 20, .hold)]
        #expect(RigEvaluator.sample(keys, at: -5) == 0)
        #expect(RigEvaluator.sample(keys, at: 50) == 5)
        #expect(RigEvaluator.sample(keys, at: 150) == 10)
        #expect(RigEvaluator.sample(keys, at: 299) == 10, "hold jumps at its key")
        #expect(RigEvaluator.sample(keys, at: 300) == 20)
        #expect(RigEvaluator.sample(keys, at: 9_999) == 20)
    }
}

@Suite struct RigEvaluatorTests {
    let rig = RigPlaceholder.rig
    let clip = RigPlaceholder.newItem

    @Test func squashKeepsAreaAndFollowLagsTheParent() {
        let squash = RigSpec.Clip(durationMs: 1000, tracks: ["root.sy": [K(0, 0.81), K(1000, 0.81)]])
        #expect(abs(RigEvaluator.channels(squash, at: 500)["root.sx"]! - 1 / 0.9) < 1e-9)
        let follow = RigSpec.Clip(durationMs: 1000, tracks: ["arm-l.rot": [K(0, 0), K(500, 100, .linear)]],
                                  follow: [.init(bone: "hand-l", of: "arm-l", delayMs: 100, gain: 1)])
        // The parent moved 20° in the last 100 ms, so the child trails by 20°.
        #expect(abs(RigEvaluator.channels(follow, at: 300)["hand-l.rot"]! + 20) < 1e-9)
    }

    @Test func clipsBlendInFromWhatWasShowingAndEndExactlyOnTheirPose() {
        let from = ["arm-r.rot": -35.0, "root.sy": 1.02]
        let start = RigEvaluator.blendedChannels(clip, at: 0, from: from)
        #expect(abs(start["arm-r.rot"]! + 35) < 1e-9)
        #expect(abs(start["root.sy"]! - 1.02) < 1e-9)
        // new-item hands back to the attention frame, so it ends exactly on the attention pose.
        let attention = rig.poses!["attention"]!.channels
        let end = RigEvaluator.showing(rig, clip: clip, at: 1900)
        for name in Set(end.keys).union(attention.keys) {
            #expect(abs((end[name] ?? RigEvaluator.channelRest(name)) - (attention[name] ?? RigEvaluator.channelRest(name))) < 1e-9, "\(name)")
        }
        // incident-start ends on rest (idle with the hat).
        let incident = RigPlaceholder.incidentStart
        let rest = RigEvaluator.pose(rig, clip: nil, at: 0), last = RigEvaluator.pose(rig, clip: incident, at: 1900)
        for (bone, transform) in rest.bones {
            let other = last.bones[bone]!
            #expect(abs(transform.tx - other.tx) < 1e-6 && abs(transform.ty - other.ty) < 1e-6
                    && abs(transform.a - other.a) < 1e-6 && abs(transform.b - other.b) < 1e-6, "\(bone)")
        }
    }

    @Test func facePresetsExpandAndAnExplicitSwapWinsAtTheSameInstant() {
        func image(_ part: String, _ ms: Double, _ clip: RigSpec.Clip) -> String? {
            RigEvaluator.pose(rig, clip: clip, at: ms).parts.first { $0.part == part }?.image
        }
        #expect(image("eyes", 600, clip) == "rig/eyes-happy.png", "joy at 460")
        #expect(image("mouth", 600, clip) == "rig/mouth-open.png")
        #expect(image("eyes", 1740, clip) == "rig/eyes-closed.png", "blink preset touches only the eyes")
        #expect(image("mouth", 1740, clip) == "rig/mouth.png", "the mouth keeps neutral's")
        var both = clip
        both.swaps = (both.swaps ?? []) + [.init(at: 460, part: "eyes", variant: "half")]
        #expect(image("eyes", 600, both) == "rig/eyes-half.png")
    }

    @Test func theHelmetRidesTheHandThenEasesOntoTheHeadWithoutAJump() {
        let incident = RigPlaceholder.incidentStart
        func helmet(_ ms: Double) -> CGPoint? {
            RigEvaluator.pose(rig, clip: incident, at: ms).parts.first { $0.part == "helmet" }
                .map { CGPoint(x: $0.rect.minX, y: $0.rect.minY).applying($0.transform) }
        }
        #expect(helmet(100) == nil, "hidden until it is brought out")
        // Held: it moves with the hand.
        let hand = RigEvaluator.pose(rig, clip: incident, at: 500).bones["hand-l"]!
        #expect(abs(helmet(500)!.x - CGPoint(x: 56, y: 176).applying(hand).x) < 1e-6)
        // The hand-over at 820 ms is continuous: the mount change itself moves nothing.
        let before = helmet(819.9)!, after = helmet(820.1)!
        #expect(hypot(after.x - before.x, after.y - before.y) < 0.5)
        // Mid-blend it is between the hand and the head.
        let mid = helmet(950)!, seated = helmet(1100)!
        #expect(hypot(mid.x - seated.x, mid.y - seated.y) > 1, "still easing at 950 ms")
        // Worn at the end exactly where the hat accessory is baked: on the rest head.
        let worn = RigEvaluator.pose(rig, still: "idle", swaps: [.init(at: 0, part: "helmet", variant: "default")])
            .parts.first { $0.part == "helmet" }!
        let end = helmet(1900)!, baked = CGPoint(x: worn.rect.minX, y: worn.rect.minY).applying(worn.transform)
        #expect(abs(end.x - baked.x) < 1e-6 && abs(end.y - baked.y) < 1e-6)
    }

    @Test func swapsShowPropsAndFacesOnTime() {
        func images(_ ms: Double) -> Set<String> { Set(RigEvaluator.pose(rig, clip: clip, at: ms).parts.map(\.image)) }
        #expect(!images(100).contains("rig/envelope.png"), "the envelope is hidden at rest")
        #expect(images(300).contains("rig/envelope.png"))
        #expect(images(600).contains("rig/eyes-happy.png"))
        #expect(images(1740).contains("rig/eyes-closed.png"), "a blink near the end")
        #expect(!images(1850).contains("rig/envelope.png"))
        #expect(!RigEvaluator.pose(rig, clip: nil, at: 0).parts.map(\.image).contains("rig/envelope.png"))
    }

    @Test func childrenRotateAboutTheirPivotWithTheParent() {
        let raised = RigEvaluator.pose(rig, channels: ["arm-l.rot": 90])
        // The shoulder pivot stays put (up to the rest scale about the anchor); the hand swings out left.
        let shoulder = CGPoint(x: 88, y: 146).applying(raised.bones["arm-l"]!)
        let rest = CGPoint(x: 88, y: 146).applying(RigEvaluator.pose(rig, channels: [:]).bones["arm-l"]!)
        #expect(abs(shoulder.x - rest.x) < 1e-6 && abs(shoulder.y - rest.y) < 1e-6)
        let hand = CGPoint(x: 86, y: 190).applying(raised.bones["hand-l"]!)
        #expect(hand.x < shoulder.x - 30 && abs(hand.y - shoulder.y) < 4, "positive rotation is clockwise: down → left")
    }
}

@Suite struct RigPackTests {
    @Test func placeholderLoadsUnderTheBundledBudgetAndBoundsRule() throws {
        let pack = try placeholderPack(budget: .bundled).get()
        #expect(pack.manifest.isV3)
        #expect(pack.rigOutlines.count == pack.manifest.rig!.imagePaths.count)
        let library = ClipLibrary(pack: pack)
        #expect(library.duration(.newItem) == 1.9, "fits the attention wave's EventClipQueue slot")
        #expect(!library.hidesAccessories.contains(.newItem))
        #expect(library.duration(.incidentStart) == 1.9)
        #expect(library.hidesAccessories.contains(.incidentStart), "the clip animates the helmet itself")
        #expect(library.accessories.contains(AccessoryPolicy.firefighterHat))
    }

    @Test func newItemPlaysOnTheExistingEventPathAndReduceMotionNeverDoes() throws {
        let pack = try placeholderPack().get()
        let library = ClipLibrary(pack: pack)
        let item = FixtureSimulator().injectEntitlementEvent()
        let clip = EventClipQueue.Clip(event: InboxEvent(item: item, severity: .actionable), startedAt: t0, kind: .newItem,
                                       duration: library.duration(.newItem))
        func at(_ seconds: Double, reduced: Bool = false) -> MascotPose {
            MascotAnimator.pose(mood: .attention, clip: clip, now: t0 + seconds, reducedMotion: reduced, idleEpoch: .distantPast,
                                library: library) { _ in [1900] }
        }
        let playing = at(0.46)
        #expect(playing.clip?.id == .newItem)
        #expect(abs((playing.clip?.elapsed ?? 0) - 0.46) < 1e-6)
        #expect(pack.rigPose(for: playing) != nil)
        #expect(at(0.46, reduced: true).clip == nil, "Reduce Motion: the static pose only")
        #expect(pack.rigPose(for: at(0.46, reduced: true)) == nil)
        #expect(at(1.95).clip == nil, "back to the mood pose when the clip ends")
    }

    @Test func theCountTracksTheMovingContour() throws {
        let pack = try placeholderPack().get()
        func top(_ ms: Double) -> Int { pack.contour(for: pose(ms))!.compactMap { $0 }.min()! }
        #expect(top(460) < top(300), "springing up raises the head above the crouch")
        // Starts on rest (the idle frame) and ends on the attention frame it hands back to.
        let idleTop = pack.poseContours(.idle)[0].compactMap { $0 }.min()!
        let attentionTop = pack.poseContours(.attention)[0].compactMap { $0 }.min()!
        #expect(abs(top(0) - idleTop) <= 2)
        #expect(abs(top(1900) - attentionTop) <= 2)
        // Every sample's contour is inside what the lane was measured from.
        let laneTop = pack.allContours.flatMap { $0.compactMap { $0 } }.min()!
        for ms in stride(from: 0.0, through: 1900, by: 1000 / 60) { #expect(top(ms) >= laneTop) }
    }

    @Test func aClipLeavingTheReserveFailsBundledAndWidensACustomPack() throws {
        func hop(_ manifest: inout MascotPackManifest) {
            manifest.rig?.clips?["new-item"]?.tracks["root.x"] = [K(0, 0), K(500, -60), K(1900, 0)]
        }
        guard case .failure(let errors) = try placeholderPack(edit: hop, budget: .bundled) else {
            Issue.record("bundled pack left its reserve"); return
        }
        #expect(errors.errors.contains(.outsideArt("rig clip new-item")))
        let custom = try placeholderPack(edit: hop).get()
        let normal = try placeholderPack().get()
        #expect(custom.artProfile!.bounds!.minX < normal.artProfile!.bounds!.minX, "hover keeps clear instead")
    }

    @Test func malformedRigsAreRejected() throws {
        func errors(_ edit: @escaping (inout MascotPackManifest) -> Void) throws -> [MascotPackError] {
            if case .failure(let errors) = try placeholderPack(edit: edit) { return errors.errors }
            return []
        }
        #expect(try !errors { $0.rig = nil }.isEmpty, "schema 3 needs a rig")
        #expect(try !errors { $0.rig?.bones["root"]?.parent = "head" }.isEmpty, "a cycle")
        #expect(try !errors { $0.rig?.clips?["new-item"]?.tracks["tail.rot"] = [K(0, 1)] }.isEmpty, "unknown bone")
        #expect(try !errors { $0.rig?.clips?["new-item"]?.tracks["head.rot"] = [K(0, 0), K(100, 90)] }.isEmpty, "outside the joint's range")
        #expect(try !errors { $0.rig?.clips?["new-item"]?.durationMs = 2500 }.isEmpty, "longer than new-item's slot")
        #expect(try !errors { $0.rig?.clips?["wave"] = RigPlaceholder.newItem }.isEmpty, "unknown clip")
        #expect(try !errors { $0.rig?.parts[0].image = "../escape.png" }.isEmpty, "unsafe path")
        #expect(try !errors { $0.rig?.clips?["new-item"]?.tracks["root.y"] = [K(500, 0), K(100, 1)] }.isEmpty, "keys out of order")
        #expect(try !errors { $0.rig?.clips?["new-item"]?.endsOn = "dance" }.isEmpty, "endsOn names no pose")
        #expect(try !errors { $0.rig?.clips?["new-item"]?.faces = [.init(at: 0, preset: "smirk")] }.isEmpty, "unknown face")
        #expect(try !errors { $0.rig?.faces?["joy"] = ["eyes": "sparkly"] }.isEmpty, "preset names no variant")
        #expect(try !errors { $0.rig?.clips?["incident-start"]?.mounts = [.init(at: 0, part: "helmet", mount: "foot")] }.isEmpty,
                "unknown mount")
        #expect(try !errors { $0.rig?.poses?["attention"]?.channels["head.rot"] = 40 }.isEmpty, "pose outside the joint")
    }

    @Test func preemptionHandsOverWhatWasShowing() throws {
        let pack = try placeholderPack().get()
        let rig = pack.manifest.rig!
        func clipPose(_ id: MascotClipID, _ ms: Double, state: MascotState = .attention) -> MascotPose {
            MascotPose(state: state, frame: nil, clipElapsed: ms / 1000, clip: ClipFrame(id: id, frame: 0, elapsed: ms / 1000))
        }
        // new-item mid-waggle is preempted by incident-start: the new clip starts from new-item's channels.
        let handoff = try #require(RigHandoff.between(clipPose(.newItem, 800), clipPose(.incidentStart, 0), at: t0, pack: pack))
        #expect(handoff.clip == .incidentStart && handoff.start == t0)
        #expect(handoff.channels == RigEvaluator.showing(rig, clip: RigPlaceholder.newItem, at: 800))
        let blended = handoff.apply(to: clipPose(.incidentStart, 0), at: t0)
        let start = pack.rigPose(for: blended)!.bones["arm-l"]!, was = pack.rigPose(for: clipPose(.newItem, 800))!.bones["arm-l"]!
        #expect(abs(start.a - was.a) < 1e-9 && abs(start.b - was.b) < 1e-9 && abs(start.tx - was.tx) < 1e-6, "no jump at the cut")
        // From the attention frame: its baked pose.
        let still = MascotPose(state: .attention, frame: nil, clipElapsed: nil)
        #expect(RigHandoff.between(still, clipPose(.newItem, 0), at: t0, pack: pack)?.channels == rig.poses!["attention"]!.channels)
        // Only for the clip it was recorded for, only at its start.
        #expect(handoff.apply(to: clipPose(.newItem, 0), at: t0).rigBlendFrom == nil)
        #expect(handoff.apply(to: clipPose(.incidentStart, 0), at: t0 + 5).rigBlendFrom == nil)
        // A clip simply continuing is not a hand-off; a frame pack never has one.
        #expect(RigHandoff.between(clipPose(.newItem, 110), clipPose(.newItem, 110), at: t0 + 0.11, pack: pack) == nil)
        #expect(RigHandoff.between(still, clipPose(.newItem, 0), at: t0, pack: nil) == nil)
    }

    @Test func olderSchemasIgnoreARigAndKeepTheirFrames() throws {
        let pack = try placeholderPack { $0.schemaVersion = 2 }.get()
        #expect(!ClipLibrary(pack: pack).has(.newItem))
        #expect(pack.rigPose(for: pose(400)) == nil)
    }
}
