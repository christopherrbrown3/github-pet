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
        for (_, spec) in (clips ?? [:]).sorted(by: { $0.key < $1.key }) { paths += spec.frames }
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
    /// Largest drag/dizzy lean the pack's layout has room for.
    public var leanLimit: Double = MascotPack.attentionLeanDegrees

    public init() {}
    public static let empty = ClipLibrary()

    public init(pack: MascotPack?) {
        guard let manifest = pack?.manifest, manifest.isV2 else { return }
        for id in MascotClipID.heldStates { if let spec = manifest.heldSpec(id) { durationsMs[id] = spec.durationMs } }
        for (name, spec) in manifest.clips ?? [:] {
            durationsMs[MascotClipID(name)] = spec.durationMs
            if spec.accessories == .hide { hidesAccessories.insert(MascotClipID(name)) }
        }
        // v3: a rig clip plays instead of a frame clip of the same name (one timeline "frame").
        if manifest.isV3 {
            for (name, clip) in manifest.rig?.clips ?? [:] {
                let id = MascotClipID(name)
                durationsMs[id] = [clip.durationMs]
                if clip.accessories == .hide { hidesAccessories.insert(id) } else { hidesAccessories.remove(id) }
            }
        }
        accessories = Set((manifest.accessories ?? [:]).keys.map { MascotClipID($0) })
        leanLimit = pack?.clipLeanLimit ?? leanLimit
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
            if let held = manifest.heldSpec(clip.id) {
                guard let frame = clip.frame else { return held.staticFallback }
                if held.frames.indices.contains(frame) { return held.frames[frame] }
            } else if let one = manifest.clipSpec(clip.id), let frame = clip.frame, one.frames.indices.contains(frame) {
                return one.frames[frame]
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

    /// item-cleared's sparkle point: the frame's `hand`, else the head plus [60, 50].
    public func hand(for path: String?) -> CGPoint {
        let point = path.flatMap { manifest.framePoints?[$0]?.hand } ?? manifest.points?.hand
        guard let point, point.count == 2 else { return ClipEffects.hand(head: head(for: path)) }
        return CGPoint(x: point[0], y: point[1])
    }

    /// The spray emitter for incident-end's frame, if the pack names one.
    public func nozzle(for path: String?) -> CGPoint? {
        let point = path.flatMap { manifest.framePoints?[$0]?.nozzle } ?? manifest.points?.nozzle
        guard let point, point.count == 2 else { return nil }
        return CGPoint(x: point[0], y: point[1])
    }

    /// Contour of a clip or held pose with any accessory it wears, rotated by the pose's lean.
    func clipContour(for pose: MascotPose) -> [Int?]? {
        if let contour = rigContour(for: pose) { return contour }
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

    /// Measures v2 images: their outlines, the upright and leaning contours they add (hat composites
    /// included), the lean the layout has room for, and (bundled) the rule that every clip, held and
    /// hat pixel stays inside the three states' art. A custom pack drawing outside it is accepted with
    /// a taller lane and wider hover outline instead.
    mutating func measureClips(enforcingBounds: Bool = true) -> [MascotPackError] {
        let v2Paths = manifest.v2ImagePaths
        guard !v2Paths.isEmpty else { return [] }
        let core = MascotState.allCases.flatMap { poseOutlines[$0] ?? [] }
        guard let union = ArtProfile.union(core), var limit = union.bounds else { return [] }
        // v3: a rig's reserve is the skin's layout box (its rest pose is scaled down to leave headroom,
        // which the worn hat uses), so the hat is checked against it rather than the baked states.
        if manifest.isV3, let reserve = manifest.rig?.reserve, reserve.count == 3 {
            limit = (minX: reserve[0], maxX: reserve[2], top: reserve[1], bottom: limit.bottom)
        }
        let baseTop = (MascotState.allCases.flatMap(poseContours) + leaningContours).flatMap { $0.compactMap { $0 } }.min() ?? 0
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
        let hats = (manifest.accessories ?? [:]).values.map(\.image).sorted()
        let hatPaths = Set(hats)
        var outside: [ArtProfile] = []
        for path in v2Paths where !hatPaths.contains(path) {
            guard let outline = extraOutlines[path], !inside(outline) else { continue }
            errors.append(.outsideArt(path))
            outside.append(outline)
        }
        // Frames that can wear the hat: every state and held frame, and clips that keep accessories.
        var wearing = Set(MascotState.allCases.flatMap { manifest.states[$0.rawValue].map { $0.frames + [$0.staticFallback] } ?? [] })
        for id in MascotClipID.heldStates { if let spec = manifest.heldSpec(id) { wearing.formUnion(spec.frames + [spec.staticFallback]) } }
        for (_, spec) in manifest.clips ?? [:] where spec.accessories != .hide { wearing.formUnion(spec.frames) }
        var upright = v2Paths.filter { !hatPaths.contains($0) }.compactMap { extraOutlines[$0]?.columnTops }
        for hatPath in hats {
            guard let hat = extraOutlines[hatPath] else { continue }
            var reported = false
            for path in wearing.sorted() {
                let offset = headOffset(for: path)
                if !inside(hat, offset) && !reported { errors.append(.outsideArt(hatPath)); reported = true; outside.append(hat) }
                let shifted = Self.shifted(hat.columnTops, by: offset)
                upright.append(extraOutlines[path].map { Self.merge($0.columnTops, shifted) } ?? shifted)
            }
        }
        extraUprightContours = upright
        // Drag and dizzy lean (#138): swept like the attention frames (#29), with the hat where worn,
        // at the largest angle whose sweep needs no taller lane.
        let leaning = Set((manifest.heldSpec(.drag).map { $0.frames + [$0.staticFallback] } ?? [])
                          + (manifest.clipSpec(.dizzy)?.frames ?? [])).sorted()
        let pointSets: [[CGPoint]] = leaning.compactMap { path in
            guard let art = extraOutlines[path] else { return nil }
            let hatPoints = hats.filter { _ in wearing.contains(path) && manifest.heldSpec(.drag)?.frames.contains(path) == true }
                .compactMap { extraOutlines[$0] }.flatMap { hat -> [CGPoint] in
                    let offset = headOffset(for: path)
                    return hat.outlinePoints.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
                }
            return art.outlinePoints + hatPoints
        }
        // In 1° bands like the attention frames, the same contours the lane is measured from.
        func sweep(_ lean: Double) -> [[Int?]] {
            guard lean > 0 else { return [] }
            return pointSets.flatMap { points in
                stride(from: -lean, to: lean, by: 1).map {
                    ArtProfile.rotatedContour(points, canvas: Self.canvasSize, from: $0, to: min($0 + 1, lean),
                                              pivot: AttentionGesture.pivot, step: 0.05)
                }
            }
        }
        // The largest 0.5° step whose whole ±range keeps every rotated point (with the sweep's 1 px
        // margin) at or below the states' top: point math only, then one sweep at that limit.
        let pivot = AttentionGesture.pivot
        func highestRow(_ degrees: Double) -> Double {
            let angle = degrees * .pi / 180, c = cos(angle), s = sin(angle)
            var top = Double.infinity
            for points in pointSets {
                for point in points {
                    top = min(top, (pivot.y + (point.x - pivot.x) * s + (point.y - pivot.y) * c).rounded(.down) - 1)
                }
            }
            return max(top, 0)
        }
        var lean = 0.0
        scan: for half in 1...Int(Self.attentionLeanDegrees * 2) {
            let limit = Double(half) / 2
            for step in stride(from: limit - 0.5, through: limit, by: 0.05) where step > 0 {
                if highestRow(step) < Double(baseTop) || highestRow(-step) < Double(baseTop) { break scan }
            }
            lean = limit
        }
        clipLeanLimit = lean
        let contours = sweep(lean)
        // The sweep's own sampling can still reach a row the scan missed; never let it grow the lane.
        if contours.flatMap({ $0.compactMap { $0 } }).min().map({ $0 < baseTop }) == true, lean > 0 {
            clipLeanLimit = max(0, lean - 0.5)
            extraLeaningContours = sweep(clipLeanLimit)
        } else {
            extraLeaningContours = contours
        }
        // A custom pack drawing outside the states' art widens the hover outline instead (#138).
        if !enforcingBounds, !outside.isEmpty {
            for state in MascotState.allCases {
                artProfiles[state] = ArtProfile.union([artProfiles[state]].compactMap { $0 } + outside)
            }
            return []
        }
        return enforcingBounds ? errors : []
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
        if manifest.accessories?[AccessoryPolicy.firefighterHat.rawValue] == nil, manifest.points?.head == nil,
           let union = ArtProfile.union(MascotState.allCases.flatMap { poseOutlines[$0] ?? [] }),
           let limit = union.bounds, let hat = Self.placeholderHat(head: headPoint, limit: limit) {
            let path = "placeholder/firefighter-hat.png"
            pack.imageData[path] = hat
            var accessories = manifest.accessories ?? [:]
            accessories[AccessoryPolicy.firefighterHat.rawValue] = .init(image: path)
            manifest.accessories = accessories
            let head = headPoint
            // Mist from low on the left, where the extinguisher would be.
            manifest.points = .init(head: [Int(head.x.rounded()), Int(head.y.rounded())], nozzle: [limit.minX + 12, 196])
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
