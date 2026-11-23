import CoreGraphics
import Foundation
import ImageIO

// Schema v2 (#138): held poses, clips and accessories on a loaded pack.

extension MascotPackManifest {
    /// Held drag/doze states (v2 only; a v1 manifest's extra states are ignored as before).
    public func heldSpec(_ id: MascotClipID) -> StateSpec? {
        guard isV2, MascotClipID.heldStates.contains(id) else { return nil }
        return states[id.rawValue]
    }

    public func clipSpec(_ id: MascotClipID) -> ClipSpec? { isV2 ? clips?[id.rawValue] : nil }

    public func accessorySpec(_ id: MascotAccessoryID) -> AccessorySpec? { isV2 ? accessories?[id.rawValue] : nil }

    /// Images the v2 additions reference, in a stable order.
    public var v2ImagePaths: [String] {
        guard isV2 else { return [] }
        var paths: [String] = []
        for id in MascotClipID.heldStates { if let spec = states[id.rawValue] { paths += spec.frames + [spec.staticFallback] } }
        for (_, spec) in (clips ?? [:]).sorted(by: { $0.key < $1.key }) { paths += spec.frames + (spec.staticFallback.map { [$0] } ?? []) }
        for (_, spec) in (accessories ?? [:]).sorted(by: { $0.key < $1.key }) { paths.append(spec.image) }
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    /// Every distinct image the pack uses.
    public var imagePaths: [String] {
        var seen: Set<String> = []
        let core = MascotState.allCases.flatMap { state in
            states[state.rawValue].map { $0.frames + [$0.staticFallback] } ?? []
        }
        return (core + v2ImagePaths).filter { seen.insert($0).inserted }
    }
}

extension ArtProfile {
    /// Bounding box of the covered pixels: columns and rows, top row first.
    public var bounds: (minX: Int, maxX: Int, top: Int, bottom: Int)? {
        let spans = rows.compactMap { $0 }
        guard let top, let bottom, let minX = spans.map(\.lowerBound).min(), let maxX = spans.map(\.upperBound).max()
        else { return nil }
        return (minX, maxX, top, bottom)
    }
}

/// What a pack offers the animator: clip and held-pose timings and which accessories it can draw.
public struct ClipLibrary: Equatable, Sendable {
    public var durationsMs: [MascotClipID: [Int]] = [:]
    public var hidesAccessories: Set<MascotClipID> = []
    public var accessories: Set<MascotAccessoryID> = []

    public init() {}
    public static let none = ClipLibrary()

    public init(pack: MascotPack?) {
        guard let manifest = pack?.manifest, manifest.isV2 else { return }
        for id in MascotClipID.heldStates { if let spec = manifest.heldSpec(id) { durationsMs[id] = spec.durationMs } }
        for (name, spec) in manifest.clips ?? [:] {
            durationsMs[MascotClipID(name)] = spec.durationMs
            if spec.accessories == .hide { hidesAccessories.insert(MascotClipID(name)) }
        }
        accessories = Set((manifest.accessories ?? [:]).keys.map { MascotClipID($0) })
    }

    public func has(_ id: MascotClipID) -> Bool { durationsMs[id] != nil }

    /// A one-shot clip's length, or nil if the pack doesn't have it.
    public func duration(_ id: MascotClipID) -> TimeInterval? {
        durationsMs[id].map { Double(MascotPack.saturatingSum($0)) / 1000 }
    }
}

extension MascotPack {
    /// The image a pose draws: a clip or held frame (or its static fallback), else the state's.
    public func imagePath(for pose: MascotPose) -> String? {
        if let clip = pose.clip {
            let spec: (frames: [String], fallback: String?)?
            if let held = manifest.heldSpec(clip.id) { spec = (held.frames, held.staticFallback) }
            else if let one = manifest.clipSpec(clip.id) { spec = (one.frames, one.staticFallback) }
            else { spec = nil }
            if let spec {
                if let frame = clip.frame, spec.frames.indices.contains(frame) { return spec.frames[frame] }
                if clip.frame == nil, let fallback = spec.fallback { return fallback }
            }
        }
        guard let spec = manifest.states[pose.state.rawValue] else { return nil }
        if pose.clip == nil, let frame = pose.frame { return spec.frames.indices.contains(frame) ? spec.frames[frame] : nil }
        return spec.staticFallback
    }

    /// The pack's default head point (manifest `points.head`, else the top centre of the idle art).
    public var headPoint: CGPoint {
        if let head = manifest.points?.head, head.count == 2 { return CGPoint(x: head[0], y: head[1]) }
        let idle = artProfiles[.idle]
        let top = idle?.top ?? 40
        var near: [Int] = []
        for (column, columnTop) in (idle?.columnTops ?? []).enumerated() {
            if let columnTop, columnTop <= top + 6 { near.append(column) }
        }
        let x = near.isEmpty ? 128.0 : Double(near.reduce(0, +)) / Double(near.count)
        return CGPoint(x: x, y: Double(top) + 24)
    }

    /// Where the hat moves for this frame: its `framePoints` head minus the default head.
    public func headOffset(for path: String?) -> CGPoint {
        guard let path, let head = manifest.framePoints?[path]?.head, head.count == 2 else { return .zero }
        let base = headPoint
        return CGPoint(x: Double(head[0]) - base.x, y: Double(head[1]) - base.y)
    }

    public func head(for path: String?) -> CGPoint {
        let offset = headOffset(for: path), base = headPoint
        return CGPoint(x: base.x + offset.x, y: base.y + offset.y)
    }

    /// The spray emitter for incident-end's frame, if the pack names one.
    public func nozzle(for path: String?) -> CGPoint? {
        let point = path.flatMap { manifest.framePoints?[$0]?.nozzle } ?? manifest.points?.nozzle
        guard let point, point.count == 2 else { return nil }
        return CGPoint(x: point[0], y: point[1])
    }

    /// Contour of a clip or held pose with any accessory it wears, rotated by the pose's lean.
    func clipContour(for pose: MascotPose) -> [Int?]? {
        guard let path = imagePath(for: pose), let art = extraOutlines[path] else { return nil }
        let hats: [(ArtProfile, CGPoint)] = pose.accessories.compactMap { id in
            manifest.accessorySpec(id).flatMap { extraOutlines[$0.image] }.map { ($0, headOffset(for: path)) }
        }
        if pose.angle != 0 {
            let points = art.outlinePoints + hats.flatMap { hat, offset in
                hat.outlinePoints.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
            }
            return ArtProfile.rotatedContour(points, canvas: Self.canvasSize, from: pose.angle, to: pose.angle,
                                             pivot: AttentionGesture.pivot, margin: 0)
        }
        var tops = art.columnTops
        for (hat, offset) in hats { tops = Self.merge(tops, Self.shifted(hat.columnTops, by: offset)) }
        return tops
    }

    static func shifted(_ tops: [Int?], by offset: CGPoint) -> [Int?] {
        let dx = Int(offset.x.rounded()), dy = Int(offset.y.rounded())
        return tops.indices.map { column in
            let source = column - dx
            return tops.indices.contains(source) ? tops[source].map { max(0, $0 + dy) } : nil
        }
    }

    static func merge(_ a: [Int?], _ b: [Int?]) -> [Int?] {
        zip(a, b).map { x, y in
            switch (x, y) {
            case let (x?, y?): return min(x, y)
            default: return x ?? y
            }
        }
    }

    /// Measures v2 images: their outlines, the contours they add, and the hard rule that each one
    /// (and the hat at every head point it is drawn at) stays inside the three states' art.
    mutating func measureClips() -> [MascotPackError] {
        let v2Paths = manifest.v2ImagePaths
        guard !v2Paths.isEmpty else { return [] }
        let core = MascotState.allCases.flatMap { poseOutlines[$0] ?? [] }
        guard let union = ArtProfile.union(core), let limit = union.bounds else { return [] }
        var errors: [MascotPackError] = []
        extraOutlines = [:]
        for path in manifest.imagePaths {
            if let data = imageData[path], let outline = ArtProfile(png: data, alphaThreshold: 0) { extraOutlines[path] = outline }
        }
        func inside(_ outline: ArtProfile, _ offset: CGPoint = .zero) -> Bool {
            guard let box = outline.bounds else { return true }
            let dx = Int(offset.x.rounded()), dy = Int(offset.y.rounded())
            return box.minX + dx >= limit.minX && box.maxX + dx <= limit.maxX && box.top + dy >= limit.top
                && box.bottom + dy < Self.canvasSize
        }
        let hatPaths = Set((manifest.accessories ?? [:]).values.map(\.image))
        var contours: [[Int?]] = []
        for path in v2Paths where !hatPaths.contains(path) {
            guard let outline = extraOutlines[path] else { continue }
            if !inside(outline) { errors.append(.outsideArt(path)) }
            contours.append(outline.columnTops)
        }
        // Drag frames over the whole lean, as the attention frames are (#29).
        if let drag = manifest.heldSpec(.drag) {
            let lean = DragLean.maxDegrees
            for path in Set(drag.frames + [drag.staticFallback]).sorted() {
                guard let points = extraOutlines[path]?.outlinePoints else { continue }
                contours += stride(from: -lean, to: lean, by: 1).map {
                    ArtProfile.rotatedContour(points, canvas: Self.canvasSize, from: $0, to: $0 + 1,
                                              pivot: AttentionGesture.pivot, step: 0.05)
                }
            }
        }
        // The hat at the default head point and every per-frame head point.
        let offsets = [CGPoint.zero] + manifest.imagePaths.map { headOffset(for: $0) }.filter { $0 != .zero }
        for path in hatPaths.sorted() {
            guard let hat = extraOutlines[path] else { continue }
            if offsets.contains(where: { !inside(hat, $0) }) { errors.append(.outsideArt(path)) }
            contours += offsets.map { Self.shifted(hat.columnTops, by: $0) }
        }
        extraContours = contours
        return errors
    }

    /// The pack with every design-v1 clip, held pose and the hat it lacks synthesized from its own
    /// frames (design note: reuse idle/attention/urgent paths), each recorded in `placeholderClips`
    /// so the renderer tags it "PH". The hat is drawn in code inside the art. Never used for a
    /// normal launch's bundled art; render-check and `--placeholder-clips` only.
    public func withPlaceholderClips() -> MascotPack {
        var pack = self
        var manifest = self.manifest
        manifest.schemaVersion = max(manifest.schemaVersion, 2)
        var clips = self.manifest.isV2 ? (manifest.clips ?? [:]) : [:]
        if !self.manifest.isV2 { manifest.accessories = nil; manifest.points = nil; manifest.framePoints = nil }
        func frames(_ state: MascotState, _ indices: [Int]) -> [String]? {
            guard let spec = manifest.states[state.rawValue], !spec.frames.isEmpty else { return nil }
            return indices.map { spec.frames[min(max($0, 0), spec.frames.count - 1)] }
        }
        for policy in ClipCatalog.v1.ordered where clips[policy.id.rawValue] == nil {
            guard let paths = frames(policy.placeholder.state, policy.placeholder.frames) else { continue }
            let hides = policy.id == .incidentStart || policy.id == .incidentEnd
            clips[policy.id.rawValue] = .init(frames: paths, durationMs: policy.placeholder.durationMs,
                                              accessories: hides ? .hide : nil)
            pack.placeholderClips.insert(policy.id)
        }
        manifest.clips = clips
        for (id, recipe) in ClipCatalog.heldPlaceholders.sorted(by: { $0.key < $1.key })
        where !self.manifest.isV2 || manifest.states[id.rawValue] == nil {
            guard let paths = frames(recipe.state, recipe.frames), let base = manifest.states[recipe.state.rawValue] else { continue }
            manifest.states[id.rawValue] = .init(frames: paths, durationMs: recipe.durationMs, loop: true,
                                                 staticFallback: id == .doze ? paths[0] : base.staticFallback)
            pack.placeholderClips.insert(id)
        }
        if manifest.accessories?[AccessoryPolicy.firefighterHat.rawValue] == nil,
           let union = ArtProfile.union(MascotState.allCases.flatMap { poseOutlines[$0] ?? [] }),
           let limit = union.bounds, let hat = Self.placeholderHat(head: headPoint, limit: limit) {
            let path = "placeholder/firefighter-hat.png"
            pack.imageData[path] = hat
            var accessories = manifest.accessories ?? [:]
            accessories[AccessoryPolicy.firefighterHat.rawValue] = .init(image: path)
            manifest.accessories = accessories
            pack.placeholderClips.insert(AccessoryPolicy.firefighterHat)
        }
        pack.manifest = manifest
        _ = pack.measureClips()
        return pack
    }

    /// A code-drawn helmet sitting on the head, inside the art's bounds.
    static func placeholderHat(head: CGPoint, limit: (minX: Int, maxX: Int, top: Int, bottom: Int)) -> Data? {
        let side = canvasSize, halfWidth = 30.0
        let centre = min(max(head.x, Double(limit.minX) + halfWidth + 2), Double(limit.maxX) - halfWidth - 2)
        let top = max(head.y - 24, Double(limit.top) + 1)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CoreGraphics is bottom-up; canvas rows are top-down.
        func y(_ row: Double) -> Double { Double(side) - row }
        context.setFillColor(CGColor(red: 0.85, green: 0.18, blue: 0.12, alpha: 1))
        context.fillEllipse(in: CGRect(x: centre - halfWidth + 4, y: y(top + 30), width: (halfWidth - 4) * 2, height: 30))
        context.fill(CGRect(x: centre - halfWidth, y: y(top + 26), width: halfWidth * 2, height: 6))
        context.setFillColor(CGColor(red: 1, green: 0.84, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: centre - 5, y: y(top + 20), width: 10, height: 14))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
