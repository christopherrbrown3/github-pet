import CoreGraphics
import Foundation

// #138 motion layer: eased whole-figure transforms over a clip's key poses, sampled from the clip's
// own elapsed time on the app clock (no timers). Key poses alone are 3–5 held drawings with hard cuts;
// the motion layer adds the in-betweens a drawing can't: anticipation, squash and stretch on the
// ground anchor, a small hop with overshoot, and a settle. Pose swaps sit on motion peaks (where the
// eye expects change), the incoming pose starts at the outgoing pose's height and eases to its own,
// and a short dissolve covers only swaps whose silhouettes are close. A clip without a motion entry
// plays exactly as before. Reduce Motion never plays a clip, so it never moves.

/// One clip's choreography (see animation-v1.md, "Motion model").
public struct ClipMotion: Equatable, Sendable {
    /// A transform peak at `ms` from the clip start. Scale is about the ground anchor [128, 232];
    /// `lift` raises the figure (canvas px, positive is up). Values between keys ease in and out.
    public struct Key: Equatable, Sendable {
        public var ms: Double
        public var scaleX: Double
        public var scaleY: Double
        public var lift: Double

        public init(_ ms: Double, _ scaleX: Double, _ scaleY: Double, lift: Double = 0) {
            self.ms = ms; self.scaleX = scaleX; self.scaleY = scaleY; self.lift = lift
        }
    }

    /// What the motion blends with: another frame of the clip, the pose before it, or the pose after it.
    public enum Partner: Equatable, Sendable {
        case frame(Int), entry, exit
    }

    public var keys: [Key]
    /// Frame index i → a dissolve from frame i−1 into i, centred on frame i's start (close silhouettes only).
    public var dissolveMs: [Int: Double]
    /// A dissolve from the pose before the clip, and into the pose after it.
    public var entryMs: Double
    public var exitMs: Double
    /// How long an incoming pose takes to ease from the outgoing pose's height to its own.
    public var matchMs: Double
    /// How long the last pose takes to reach the mood pose's height; longer than `exitMs`, so the
    /// heights already agree when the dissolve begins.
    public var exitMatchMs: Double

    public init(keys: [Key], dissolveMs: [Int: Double] = [:], entryMs: Double = 0, exitMs: Double = 0, matchMs: Double = 0,
                exitMatchMs: Double = 0) {
        self.keys = keys.sorted { $0.ms < $1.ms }
        self.dissolveMs = dissolveMs
        self.entryMs = entryMs
        self.exitMs = exitMs
        self.matchMs = matchMs
        self.exitMatchMs = exitMatchMs
    }

    /// The transform and blends at one instant, before the pack fits them to its art.
    public struct Sample: Equatable, Sendable {
        public var frame: Int
        public var scaleX = 1.0
        public var scaleY = 1.0
        public var lift = 0.0
        /// The image to blend with and its share (0…1).
        public var partner: Partner?
        public var partnerWeight = 0.0
        /// Scale the current pose toward this pose's height by `matchWeight` (0 = its own height).
        public var matchTo: Partner?
        public var matchWeight = 0.0
    }

    /// Clips with a motion layer. New-item first (#138): perk, anticipation crouch, hop with the
    /// envelope, waggle, landing settle. Frame starts (ms): 0, 220, 450, 830, 1150; end 1900.
    public static let catalog: [MascotClipID: ClipMotion] = [
        .newItem: ClipMotion(keys: [
            Key(0, 1.00, 1.00),
            Key(100, 0.98, 1.03),             // perk: stretch up out of idle
            Key(220, 1.045, 0.94),            // anticipation squash; the crouch pose lands here
            Key(330, 1.02, 0.97),
            Key(450, 0.965, 1.05, lift: 3),   // launch stretch; the tiptoe pose lands here
            Key(570, 0.99, 1.02, lift: 8),    // top of the hop
            Key(690, 1.035, 0.955),           // landing squash
            Key(780, 0.995, 1.015),           // overshoot
            Key(830, 1.00, 1.00),             // waggle (dissolve: same silhouette, envelope tilted)
            Key(990, 1.01, 0.99),
            Key(1150, 1.035, 0.95),           // settle: drop to the chest-held envelope
            Key(1290, 0.99, 1.02),            // overshoot
            Key(1420, 1.005, 0.995),
            Key(1540, 1.00, 1.00),
            Key(1820, 1.00, 1.00),
            Key(1900, 1.015, 0.98),           // small beat into the mood pose
        ], dissolveMs: [3: 140], entryMs: 110, exitMs: 150, matchMs: 130, exitMatchMs: 360),
    ]

    /// Smoothstep between keys: zero velocity at every key, so peaks read as peaks.
    static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    public func sample(durationsMs: [Int], elapsedMs t: Double) -> Sample {
        let starts = durationsMs.indices.map { index in Double(durationsMs.prefix(index).reduce(0, +)) }
        let total = Double(durationsMs.reduce(0, +))
        let frame = starts.lastIndex { $0 <= t } ?? 0
        var sample = Sample(frame: frame)
        if let next = keys.firstIndex(where: { $0.ms > t }) {
            if next == 0 {
                (sample.scaleX, sample.scaleY, sample.lift) = (keys[0].scaleX, keys[0].scaleY, keys[0].lift)
            } else {
                let a = keys[next - 1], b = keys[next], k = Self.ease((t - a.ms) / (b.ms - a.ms))
                sample.scaleX = a.scaleX + (b.scaleX - a.scaleX) * k
                sample.scaleY = a.scaleY + (b.scaleY - a.scaleY) * k
                sample.lift = a.lift + (b.lift - a.lift) * k
            }
        } else if let last = keys.last {
            (sample.scaleX, sample.scaleY, sample.lift) = (last.scaleX, last.scaleY, last.lift)
        }
        // Blends: entry, exit, then any close-silhouette dissolve around a frame start.
        if entryMs > 0, t < entryMs {
            sample.partner = .entry
            sample.partnerWeight = 1 - Self.ease(t / entryMs)
        } else if exitMs > 0, t > total - exitMs {
            sample.partner = .exit
            sample.partnerWeight = Self.ease((t - (total - exitMs)) / exitMs)
        } else {
            for (index, duration) in dissolveMs where starts.indices.contains(index) && index > 0 {
                let p = (t - (starts[index] - duration / 2)) / duration
                guard p >= 0, p < 1 else { continue }
                sample.partner = .frame(frame == index ? index - 1 : index)
                sample.partnerWeight = frame == index ? 1 - Self.ease(p) : Self.ease(p)
            }
        }
        // Height match: the incoming pose starts at the outgoing pose's height and eases to its own;
        // the last pose eases toward the mood pose's height before the clip ends.
        if exitMatchMs > 0, t > total - exitMatchMs {
            sample.matchTo = .exit
            sample.matchWeight = Self.ease((t - (total - exitMatchMs)) / exitMatchMs)
        } else if matchMs > 0 {
            if t < matchMs {
                sample.matchTo = .entry
                sample.matchWeight = 1 - Self.ease(t / matchMs)
            } else if frame > 0, t - starts[frame] < matchMs {
                sample.matchTo = .frame(frame - 1)
                sample.matchWeight = 1 - Self.ease((t - starts[frame]) / matchMs)
            }
        }
        return sample
    }
}

/// A motion sample fitted to a pack's art: the drawn transform for the current image and the blend.
public struct ResolvedMotion: Equatable, Sendable {
    public struct Layer: Equatable, Sendable {
        public var path: String
        public var scaleX: Double
        public var scaleY: Double
        /// Canvas px, positive is up.
        public var lift: Double
        public var opacity: Double
    }

    /// Drawn bottom to top: the partner (if any) under the current image.
    public var layers: [Layer]

    /// Maps a canvas point of the untransformed art to where this layer draws it.
    public static func apply(_ layer: Layer, x: Double, y: Double) -> (x: Double, y: Double) {
        let anchor = MascotPack.anchor
        return (Double(anchor[0]) + (x - Double(anchor[0])) * layer.scaleX,
                Double(anchor[1]) + (y - Double(anchor[1])) * layer.scaleY - layer.lift)
    }

    /// A column-top contour (canvas rows, nil = empty column) as this layer draws it.
    public static func transform(_ tops: [Int?], by layer: Layer) -> [Int?] {
        let anchor = MascotPack.anchor
        return tops.indices.map { column in
            let source = Int((Double(anchor[0]) + (Double(column) - Double(anchor[0])) / layer.scaleX).rounded())
            guard tops.indices.contains(source), let top = tops[source] else { return nil }
            return max(0, Int(apply(layer, x: Double(source), y: Double(top)).y.rounded(.down)))
        }
    }
}

extension MascotPack {
    /// Fits a clip's motion to this pack's art (#138). The height match uses each pose's measured
    /// height, and no transform takes art beyond the states' art (`artLimit`) or, where a frame
    /// already reaches further, beyond that frame's own bounds, so motion never grows the layout.
    /// `entryPath` and `exitPath` are the images shown just before and after the clip.
    public func motion(for pose: MascotPose, entryPath: String?, exitPath: String?) -> ResolvedMotion? {
        // Only drawn art moves: placeholder stand-ins (QA) keep their plain key poses.
        guard let clip = pose.clip, !placeholderClips.contains(clip.id), let motion = ClipMotion.catalog[clip.id],
              manifest.heldSpec(clip.id) == nil,
              let spec = manifest.clipSpec(clip.id) else { return nil }
        let sample = motion.sample(durationsMs: spec.durationMs, elapsedMs: clip.elapsed * 1000)
        guard spec.frames.indices.contains(sample.frame) else { return nil }
        func path(_ partner: ClipMotion.Partner) -> String? {
            switch partner {
            case .frame(let index): return spec.frames.indices.contains(index) ? spec.frames[index] : nil
            case .entry: return entryPath
            case .exit: return exitPath
            }
        }
        let current = spec.frames[sample.frame]
        var scaleX = sample.scaleX, scaleY = sample.scaleY
        if let target = sample.matchTo.flatMap(path), let ratio = heightRatio(target, to: current) {
            let factor = 1 + (ratio - 1) * sample.matchWeight
            scaleY *= factor
            scaleX *= 1 + (factor - 1) / 2
        }
        var layers: [ResolvedMotion.Layer] = []
        let weight = sample.partner.flatMap(path) == nil ? 0 : sample.partnerWeight
        // Both layers stay fully opaque through the middle of a dissolve, so overlapping art never
        // turns see-through; each one's own pixels fade over its half.
        if weight > 0, let partner = sample.partner.flatMap(path) {
            layers.append(fit(partner, scaleX: sample.scaleX, scaleY: sample.scaleY, lift: sample.lift, opacity: min(1, 2 * weight)))
        }
        layers.append(fit(current, scaleX: scaleX, scaleY: scaleY, lift: sample.lift, opacity: min(1, 2 * (1 - weight))))
        return ResolvedMotion(layers: layers)
    }

    /// Height above the ground anchor of `other` over that of `path`.
    func heightRatio(_ other: String, to path: String) -> Double? {
        guard let a = extraOutlines[other]?.top, let b = extraOutlines[path]?.top, b < Self.anchor[1] else { return nil }
        return Double(Self.anchor[1] - a) / Double(Self.anchor[1] - b)
    }

    func fit(_ path: String, scaleX: Double, scaleY: Double, lift: Double, opacity: Double) -> ResolvedMotion.Layer {
        var layer = ResolvedMotion.Layer(path: path, scaleX: scaleX, scaleY: scaleY, lift: lift, opacity: opacity)
        guard let box = extraOutlines[path]?.bounds, artLimit.count == 3 else { return layer }
        let anchorX = Double(Self.anchor[0]), ground = Double(Self.anchor[1])
        let top = Double(min(artLimit[2], box.top)), minX = Double(min(artLimit[0], box.minX)), maxX = Double(max(artLimit[1], box.maxX))
        let height = ground - Double(box.top)
        // Vertical: give up lift first, then stretch.
        if height > 0, ground - height * layer.scaleY - layer.lift < top {
            layer.lift = max(0, ground - height * layer.scaleY - top)
            if ground - height * layer.scaleY < top { layer.scaleY = (ground - top) / height }
        }
        if Double(box.minX) < anchorX, anchorX - (anchorX - Double(box.minX)) * layer.scaleX < minX {
            layer.scaleX = (anchorX - minX) / (anchorX - Double(box.minX))
        }
        if Double(box.maxX) > anchorX, anchorX + (Double(box.maxX) - anchorX) * layer.scaleX > maxX {
            layer.scaleX = (maxX - anchorX) / (Double(box.maxX) - anchorX)
        }
        return layer
    }

    /// The pose's contour as drawn with its motion: every visible layer, transformed.
    public func contour(for pose: MascotPose, motion: ResolvedMotion?) -> [Int?]? {
        guard let motion else { return contour(for: pose) }
        let tops = motion.layers.filter { $0.opacity > 0 }.compactMap { layer in
            extraOutlines[layer.path].map { ResolvedMotion.transform($0.columnTops, by: layer) }
        }
        return tops.reduce(nil) { merged, next in merged.map { Self.merge($0, next) } ?? next }
    }

    /// Every contour a clip's motion can draw, sampled at 30 fps, so the lane and hover account for it.
    func motionContours() -> [[Int?]] {
        let entry = manifest.states[MascotState.idle.rawValue]?.staticFallback
        let exit = manifest.states[MascotState.attention.rawValue]?.staticFallback
        var contours: [[Int?]] = []
        for (id, _) in ClipMotion.catalog.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let spec = manifest.clipSpec(id), manifest.heldSpec(id) == nil else { continue }
            let total = Double(spec.durationMs.reduce(0, +)) / 1000
            for elapsed in stride(from: 0, through: total, by: 1.0 / 30) {
                let pose = MascotPose(state: .attention, frame: nil, clipElapsed: elapsed,
                                      clip: ClipFrame(id: id, frame: nil, elapsed: elapsed))
                if let motion = motion(for: pose, entryPath: entry, exitPath: exit), let tops = contour(for: pose, motion: motion) {
                    contours.append(tops)
                }
            }
        }
        return contours
    }
}
