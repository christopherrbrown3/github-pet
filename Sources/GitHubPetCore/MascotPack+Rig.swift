import CoreGraphics
import Foundation

// Schema v3 (#138): the cutout rig on a loaded pack. States stay baked frames; rig clips replace frame
// clips of the same name, and their contours come from transformed part outlines, not pixels.

extension MascotPack {
    /// The rig clip a pose plays, if this pack has one for it.
    public func rigClip(for pose: MascotPose) -> (rig: RigSpec, clip: RigSpec.Clip, ms: Double)? {
        guard manifest.isV3, let rig = manifest.rig, let frame = pose.clip, let clip = rig.clip(frame.id) else { return nil }
        return (rig, clip, min(max(frame.elapsed * 1000, 0), Double(clip.durationMs)))
    }

    /// Pixel sizes of the rig's images, from their measured outlines.
    public var rigImageSizes: [String: CGSize] { rigOutlines.mapValues(\.size) }

    /// The placed parts for a rig clip pose (its lean included), or nil when the pose isn't one.
    public func rigPose(for pose: MascotPose) -> RigPose? {
        guard let (rig, clip, ms) = rigClip(for: pose) else { return nil }
        return RigEvaluator.pose(rig, clip: clip, at: ms, lean: pose.angle, sizes: rigImageSizes)
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
        for (name, clip) in (rig.clips ?? [:]).sorted(by: { $0.key < $1.key }) {
            let worn = clip.accessories == .hide ? [] : hats
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
            if escaped { errors.append(.outsideArt("rig clip \(name)")) }
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
