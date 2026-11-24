import CoreGraphics
import Foundation

// Schema v3 (#138): the cutout rig on a loaded pack. States stay baked frames; rig clips replace frame
// clips of the same name, and their contours come from transformed part outlines, not pixels.

extension MascotPack {
    /// The rig clip a pose plays, if this pack has one for it.
    public func rigClip(for pose: MascotPose) -> (rig: RigSpec, clip: RigSpec.Clip, ms: Double)? {
        guard manifest.isV3, let rig = manifest.rig, let frame = pose.clip, let clip = rig.clip(frame.id) else { return nil }
        return (rig, RigSpec.wearing(clip, !pose.accessories.isEmpty), min(max(frame.elapsed * 1000, 0), Double(clip.durationMs)))
    }

    /// Pixel sizes of the rig's images, from their measured outlines.
    public var rigImageSizes: [String: CGSize] { rigOutlines.mapValues(\.size) }

    /// The placed parts for a rig clip pose (its lean included), or nil when the pose isn't one.
    public func rigPose(for pose: MascotPose) -> RigPose? {
        guard let (rig, clip, ms) = rigClip(for: pose) else { return nil }
        return RigEvaluator.pose(rig, clip: clip, at: ms, lean: pose.angle, blendFrom: pose.rigBlendFrom, sizes: rigImageSizes)
    }

    /// The rig channels of what a pose shows: a rig clip mid-motion, else the rig's still pose for the
    /// held state or mood the frame was baked from (rest if the rig names none). Nil for a non-rig pack.
    public func rigChannels(showing pose: MascotPose) -> [String: Double]? {
        guard manifest.isV3, let rig = manifest.rig else { return nil }
        if let (_, clip, ms) = rigClip(for: pose) { return RigEvaluator.showing(rig, clip: clip, at: ms, blendFrom: pose.rigBlendFrom) }
        let name = pose.clip.map(\.id.rawValue) ?? pose.state.rawValue
        return rig.poses?[name]?.channels ?? [:]
    }

    /// Accessory outline points carried by the rig's head bone at this pose.
    func rigAccessoryPoints(_ accessories: [MascotAccessoryID], rig: RigSpec, pose: RigPose) -> [CGPoint] {
        guard !accessories.isEmpty, let motion = RigEvaluator.headMotion(rig, pose: pose) else { return [] }
        return accessories.compactMap { manifest.accessorySpec($0).flatMap { extraOutlines[$0.image] } }
            .flatMap { $0.outlinePoints.map { $0.applying(motion) } }
    }

    func rigContour(for pose: MascotPose) -> [Int?]? {
        guard let (rig, _, _) = rigClip(for: pose), let placed = rigPose(for: pose) else { return nil }
        return placed.contour(outlines: rigOutlines, unitScale: rig.unitScale,
                              extra: rigAccessoryPoints(pose.accessories, rig: rig, pose: placed))
    }

    /// Measures every rig clip sampled at 60 Hz (design section 7.5): one merged upright contour per
    /// clip for the lane and the count's range, and (bundled) the rule that every sample, with the hat
    /// where worn, stays inside the three states' art. A custom rig drawing outside widens the hover
    /// outline instead.
    mutating func measureRig(enforcingBounds: Bool) -> [MascotPackError] {
        guard manifest.isV3, let rig = manifest.rig else { return [] }
        rigOutlines = [:]
        for path in rig.imagePaths { if let data = imageData[path], let outline = RigOutline(png: data) { rigOutlines[path] = outline } }
        let core = MascotState.allCases.flatMap { poseOutlines[$0] ?? [] }
        guard let union = ArtProfile.union(core), let states = union.bounds else { return [] }
        let limit = rig.reserve.map { (minX: $0[0], maxX: $0[2], top: $0[1]) } ?? (minX: states.minX, maxX: states.maxX, top: states.top)
        let hats = (manifest.accessories ?? [:]).keys.sorted().map { MascotAccessoryID($0) }
        var errors: [MascotPackError] = []
        var outside: [ArtProfile] = []
        // Each clip as played bare and, when it keeps accessories, with the hat (and its `worn` tracks).
        let plays = (rig.clips ?? [:]).sorted(by: { $0.key < $1.key }).flatMap { name, clip in
            [(name, clip, [MascotAccessoryID]())] + (clip.accessories == .hide || hats.isEmpty ? [] : [(name, RigSpec.wearing(clip, true), hats)])
        }
        for (name, clip, worn) in plays {
            var merged = [Int?](repeating: nil, count: Self.canvasSize)
            var escaped = false
            for ms in Self.rigSamples(clip) {
                let placed = RigEvaluator.pose(rig, clip: clip, at: ms, sizes: rigImageSizes)
                let extra = rigAccessoryPoints(worn, rig: rig, pose: placed)
                merged = Self.merge(merged, placed.contour(outlines: rigOutlines, unitScale: rig.unitScale, extra: extra))
                let box = placed.bounds(outlines: rigOutlines, unitScale: rig.unitScale, extra: extra)
                guard !box.isNull else { continue }
                if box.minX < Double(limit.minX) || box.maxX > Double(limit.maxX + 1) || box.minY < Double(limit.top)
                    || box.maxY > Double(Self.canvasSize) {
                    escaped = true
                }
                // Hover keeps clear of every sample, inside the reserve or not.
                outside.append(ArtProfile(canvas: Self.canvasSize, rows: placed.rows(outlines: rigOutlines, unitScale: rig.unitScale)))
            }
            extraUprightContours.append(merged)
            if escaped, !errors.contains(.outsideArt("rig clip \(name)")) { errors.append(.outsideArt("rig clip \(name)")) }
        }
        if let swept = ArtProfile.union(outside) {
            for state in MascotState.allCases { artProfiles[state] = ArtProfile.union([artProfiles[state]].compactMap { $0 } + [swept]) }
        }
        return enforcingBounds ? errors : []
    }

    /// Sample instants over a clip: every 1/60 s and its last millisecond.
    static func rigSamples(_ clip: RigSpec.Clip) -> [Double] {
        let duration = Double(clip.durationMs)
        return Array(stride(from: 0, to: duration, by: 1000 / RigLimits.sampleHz)) + [duration]
    }
}

/// Preemption blend (#138, design section 5.2): when a rig clip starts, what was showing at that
/// instant (a preempted clip mid-motion, or the mood's frame) as rig channels, for the new clip's first
/// 120 ms to blend from. Keyed to the clip it belongs to, so it never leaks into a later clip.
public struct RigHandoff: Equatable, Sendable {
    public var clip: MascotClipID
    public var start: Date
    public var channels: [String: Double]

    public init(clip: MascotClipID, start: Date, channels: [String: Double]) {
        self.clip = clip
        self.start = start
        self.channels = channels
    }

    /// The hand-off when the pose shown at `date` changes from `before` to `after`: only when `after`
    /// is a rig clip that has just started (a different clip or start than `before`).
    public static func between(_ before: MascotPose, _ after: MascotPose, at date: Date, pack: MascotPack?) -> RigHandoff? {
        guard let pack, let next = after.clip, pack.rigClip(for: after) != nil, next.elapsed < RigEvaluator.blendInMs / 1000,
              let channels = pack.rigChannels(showing: before) else { return nil }
        let start = date.addingTimeInterval(-next.elapsed)
        if let previous = before.clip, previous.id == next.id,
           abs(date.addingTimeInterval(-previous.elapsed).timeIntervalSince(start)) < 0.001 { return nil }
        return RigHandoff(clip: next.id, start: start, channels: channels)
    }

    /// `pose` with this blend, when it is the clip the hand-off was recorded for.
    public func apply(to pose: MascotPose, at date: Date) -> MascotPose {
        guard let frame = pose.clip, frame.id == clip,
              abs(date.addingTimeInterval(-frame.elapsed).timeIntervalSince(start)) < 0.05 else { return pose }
        var pose = pose
        pose.rigBlendFrom = channels
        return pose
    }
}
