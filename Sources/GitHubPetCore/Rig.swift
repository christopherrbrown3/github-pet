import CoreGraphics
import Foundation
import ImageIO

// Cutout rig (#138, docs/design/animation-v2-rig.md): a few painted parts on a bone tree, moved by
// keyframed, eased channels. Everything here is a pure function of (clip, elapsed ms), so the single
// app clock drives it and tests can pin any instant.

/// The manifest's `rig` section (schema v3).
public struct RigSpec: Codable, Equatable, Sendable {
    public struct Bone: Codable, Equatable, Sendable {
        public var parent: String?
        /// Pivot in canvas units (rest pose, before `restScale`).
        public var pivot: [Double]
        /// Allowed rotation offset in degrees, [min, max]; keys outside it are rejected.
        public var rot: [Double]?

        public init(parent: String? = nil, pivot: [Double], rot: [Double]? = nil) {
            self.parent = parent
            self.pivot = pivot
            self.rot = rot
        }
    }

    /// One painted image on a bone. `parts` is in draw order, back to front.
    public struct Part: Codable, Equatable, Sendable {
        public var name: String
        public var image: String
        public var bone: String
        /// Where the image's top-left sits in the rest pose, canvas units.
        public var origin: [Double]
        /// Swappable images with the same placement (face layers, tip and hand variants).
        /// "default" (the part's own image) and "hide" are reserved swap names.
        public var variants: [String: String]?
        /// Not drawn until a clip swaps it in (props).
        public var hidden: Bool?
        /// Other places the part can ride (a prop held in a hand, then worn on the head): a clip moves
        /// it with a `mounts` key. `bone` and `origin` are the part's default mount.
        public var mounts: [String: Mount]?

        public init(name: String, image: String, bone: String, origin: [Double], variants: [String: String]? = nil,
                    hidden: Bool? = nil, mounts: [String: Mount]? = nil) {
            self.name = name
            self.image = image
            self.bone = bone
            self.origin = origin
            self.variants = variants
            self.hidden = hidden
            self.mounts = mounts
        }
    }

    public struct Mount: Codable, Equatable, Sendable {
        public var bone: String
        /// The image's top-left in the rest pose when riding this bone, canvas units.
        public var origin: [Double]

        public init(bone: String, origin: [Double]) {
            self.bone = bone
            self.origin = origin
        }
    }

    /// From `at`, the part rides `mount` ("default" is its own bone), easing over `blendMs` from where
    /// it was so the hand-over never jumps.
    public struct MountKey: Codable, Equatable, Sendable {
        public var at: Double
        public var part: String
        public var mount: String
        public var blendMs: Double?

        public init(at: Double, part: String, mount: String, blendMs: Double? = nil) {
            self.at = at
            self.part = part
            self.mount = mount
            self.blendMs = blendMs
        }
    }

    /// From `at`, the face shows the named preset (a group of swaps).
    public struct FaceKey: Codable, Equatable, Sendable {
        public var at: Double
        public var preset: String

        public init(at: Double, preset: String) {
            self.at = at
            self.preset = preset
        }
    }

    /// A still pose: channel values and a face preset. The builder bakes states from these, and clips
    /// blend in from and out to them.
    public struct Pose: Codable, Equatable, Sendable {
        public var channels: [String: Double]
        public var face: String?

        public init(channels: [String: Double] = [:], face: String? = nil) {
            self.channels = channels
            self.face = face
        }
    }

    /// `[ms, value]` or `[ms, value, "ease"]`: the ease shapes the approach to this key.
    public struct Key: Codable, Equatable, Sendable {
        public var ms: Double
        public var value: Double
        public var ease: RigEase

        public init(_ ms: Double, _ value: Double, _ ease: RigEase = .inOut) {
            self.ms = ms
            self.value = value
            self.ease = ease
        }

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            ms = try container.decode(Double.self)
            value = try container.decode(Double.self)
            ease = container.isAtEnd ? .inOut : try container.decode(RigEase.self)
            guard container.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "a key is [ms, value, ease?]")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(ms)
            try container.encode(value)
            try container.encode(ease)
        }
    }

    /// Overlap: the bone's rotation lags `of`'s by `delayMs`, scaled by `gain`.
    public struct Follow: Codable, Equatable, Sendable {
        public var bone: String
        public var of: String
        public var delayMs: Double
        public var gain: Double

        public init(bone: String, of: String, delayMs: Double, gain: Double) {
            self.bone = bone
            self.of = of
            self.delayMs = delayMs
            self.gain = gain
        }
    }

    /// Secondary motion: a damped sine on each bone's rotation, phase-shifted bone to bone.
    public struct Sway: Codable, Equatable, Sendable {
        public var bones: [String]
        public var amp: Double
        public var periodMs: Double
        public var phaseStepMs: Double?

        public init(bones: [String], amp: Double, periodMs: Double, phaseStepMs: Double? = nil) {
            self.bones = bones
            self.amp = amp
            self.periodMs = periodMs
            self.phaseStepMs = phaseStepMs
        }
    }

    /// From `at` ms the part shows `variant` (a key of its `variants`, or "default").
    public struct Swap: Codable, Equatable, Sendable {
        public var at: Double
        public var part: String
        public var variant: String

        public init(at: Double, part: String, variant: String) {
            self.at = at
            self.part = part
            self.variant = variant
        }
    }

    public struct Clip: Codable, Equatable, Sendable {
        public var durationMs: Int
        /// "bone.channel" → keys. Channels: x, y, rot (offsets), sx, sy, opacity (absolute).
        public var tracks: [String: [Key]]
        public var follow: [Follow]?
        public var sway: [Sway]?
        public var swaps: [Swap]?
        public var faces: [FaceKey]?
        public var mounts: [MountKey]?
        /// The pose (a `poses` key) the clip's last 150 ms blend into; rest when nil.
        public var endsOn: String?
        /// Tracks that replace `tracks` while an accessory (the incident hat) is worn: the hat uses the
        /// rest pose's headroom, so hops and stretches must be smaller then.
        public var worn: [String: [Key]]?
        public var accessories: AccessoryVisibility?

        public init(durationMs: Int, tracks: [String: [Key]], follow: [Follow]? = nil, sway: [Sway]? = nil,
                    swaps: [Swap]? = nil, faces: [FaceKey]? = nil, mounts: [MountKey]? = nil, endsOn: String? = nil,
                    worn: [String: [Key]]? = nil, accessories: AccessoryVisibility? = nil) {
            self.worn = worn
            self.durationMs = durationMs
            self.tracks = tracks
            self.follow = follow
            self.sway = sway
            self.swaps = swaps
            self.faces = faces
            self.mounts = mounts
            self.endsOn = endsOn
            self.accessories = accessories
        }
    }

    /// Part images are authored at this many pixels per canvas unit.
    public var unitScale: Double
    /// The rest pose is the authored pose scaled by this about the anchor (headroom for hops).
    public var restScale: Double?
    public var bones: [String: Bone]
    public var parts: [Part]
    public var clips: [String: Clip]?
    /// The box `[minX, top, maxX]` (canvas units) every clip sample must stay inside: the skin's
    /// layout union. Without it, the baked states' own outline.
    public var reserve: [Int]?
    /// Face presets: name → part → variant (design section 3).
    public var faces: [String: [String: String]]?
    /// Named still poses: the states the builder bakes (`idle`, `attention`, `urgent`, …) and clip ends.
    public var poses: [String: Pose]?

    public init(unitScale: Double, restScale: Double? = nil, bones: [String: Bone], parts: [Part],
                clips: [String: Clip]? = nil, reserve: [Int]? = nil, faces: [String: [String: String]]? = nil,
                poses: [String: Pose]? = nil) {
        self.unitScale = unitScale
        self.restScale = restScale
        self.bones = bones
        self.parts = parts
        self.clips = clips
        self.reserve = reserve
        self.faces = faces
        self.poses = poses
    }

    /// The clip as played while an accessory is worn (its `worn` tracks replace the plain ones).
    public static func wearing(_ clip: Clip, _ worn: Bool) -> Clip {
        guard worn, let overrides = clip.worn else { return clip }
        var result = clip
        result.tracks.merge(overrides) { _, override in override }
        return result
    }

    /// A face preset as swaps at `at`.
    public func faceSwaps(_ preset: String?, at: Double = 0) -> [Swap] {
        guard let preset, let parts = faces?[preset] else { return [] }
        return parts.sorted { $0.key < $1.key }.map { Swap(at: at, part: $0.key, variant: $0.value) }
    }

    /// A clip's swaps with its face keys expanded; at the same instant an explicit swap wins.
    public func swaps(of clip: Clip) -> [Swap] {
        (clip.faces ?? []).flatMap { faceSwaps($0.preset, at: $0.at) } + (clip.swaps ?? [])
    }

    /// Every image the rig references, in a stable order.
    public var imagePaths: [String] {
        var seen: Set<String> = []
        return parts.flatMap { [$0.image] + ($0.variants ?? [:]).sorted { $0.key < $1.key }.map(\.value) }
            .filter { seen.insert($0).inserted }
    }

    public func clip(_ id: MascotClipID) -> Clip? { clips?[id.rawValue] }
}

/// The motion language's curves (design section 5.1), as closed forms of normalized time.
public enum RigEase: String, Codable, Sendable, CaseIterable {
    case linear, hold, inOut, out, `in`, back, spring

    public func apply(_ u: Double) -> Double {
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        switch self {
        case .linear: return u
        case .hold: return u < 1 ? 0 : 1
        case .inOut: return Self.bezier(u, 0.45, 0, 0.55, 1)
        case .out: return Self.bezier(u, 0.22, 1, 0.36, 1)
        case .in: return Self.bezier(u, 0.55, 0, 1, 0.45)
        case .back:
            let s = 1.4, v = u - 1
            return 1 + (s + 1) * v * v * v + s * v * v
        case .spring:
            // Two visible wobbles, nudged so it lands exactly on 1.
            func raw(_ u: Double) -> Double { 1 - exp(-5 * u) * cos(1.5 * 2 * .pi * u) }
            return raw(u) + u * (1 - raw(1))
        }
    }

    /// CSS-style cubic-bezier(x1, y1, x2, y2) at x = u.
    static func bezier(_ u: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func coordinate(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let m = 1 - t
            return 3 * m * m * t * a + 3 * m * t * t * b + t * t * t
        }
        var low = 0.0, high = 1.0, t = u
        for _ in 0..<40 {
            t = (low + high) / 2
            if coordinate(t, x1, x2) < u { low = t } else { high = t }
        }
        return coordinate(t, y1, y2)
    }
}

public enum RigChannel: String, CaseIterable, Sendable {
    case x, y, rot, sx, sy, opacity

    public var rest: Double {
        switch self {
        case .x, .y, .rot: return 0
        case .sx, .sy, .opacity: return 1
        }
    }
}

/// A part placed for one instant: draw `image` into `rect` (canvas units) under `transform`.
public struct RigPlacedPart: Equatable, Sendable {
    public var part: String
    public var image: String
    public var rect: CGRect
    public var transform: CGAffineTransform
    public var opacity: Double
    /// Placed by a mount key (its transform already includes the mount's origin).
    public var mounted = false
}

public struct RigPose: Equatable, Sendable {
    public var parts: [RigPlacedPart]
    /// World transforms by bone; `head` (if the rig has one) moves accessories.
    public var bones: [String: CGAffineTransform]
}

public enum RigEvaluator {
    /// Transition in from the pose that was showing, and out to rest (design section 5.2).
    public static let blendInMs = 120.0
    public static let blendOutMs = 150.0

    /// Channel values ("bone.channel") of `clip` at `ms`, before blends; unanimated channels are absent.
    public static func channels(_ clip: RigSpec.Clip, at ms: Double) -> [String: Double] {
        var values: [String: Double] = [:]
        for (name, keys) in clip.tracks { values[name] = sample(keys, at: ms) }
        // Squash rule: a bone whose sy moves and sx doesn't keeps its area roughly.
        for (name, sy) in values where name.hasSuffix(".sy") {
            let sx = String(name.dropLast(3)) + ".sx"
            if clip.tracks[sx] == nil, sy > 0 { values[sx] = 1 / sy.squareRoot() }
        }
        for follow in clip.follow ?? [] {
            let of = clip.tracks[follow.of + ".rot"].map { keys in
                sample(keys, at: max(0, ms - follow.delayMs)) - sample(keys, at: ms)
            } ?? 0
            values[follow.bone + ".rot", default: 0] += follow.gain * of
        }
        let duration = Double(clip.durationMs)
        for sway in clip.sway ?? [] where sway.periodMs > 0 {
            let envelope = min(1, max(0, ms / 200)) * min(1, max(0, (duration - ms) / 300))
            for (index, bone) in sway.bones.enumerated() {
                let phase = Double(index) * (sway.phaseStepMs ?? 0)
                values[bone + ".rot", default: 0] += sway.amp * sin(2 * .pi * (ms - phase) / sway.periodMs) * envelope
            }
        }
        return values
    }

    /// Value of one track at `ms`: holds before the first key and after the last.
    public static func sample(_ keys: [RigSpec.Key], at ms: Double) -> Double {
        guard let first = keys.first else { return 0 }
        if ms <= first.ms { return first.value }
        for (previous, key) in zip(keys, keys.dropFirst()) where ms < key.ms {
            let span = key.ms - previous.ms
            guard span > 0 else { return key.value }
            return previous.value + (key.value - previous.value) * key.ease.apply((ms - previous.ms) / span)
        }
        return keys.last!.value
    }

    /// The clip's channels with the edge blends: in from `from` (rest when nil) and out to rest.
    public static func blendedChannels(_ clip: RigSpec.Clip, at ms: Double, from: [String: Double]? = nil,
                                       to end: [String: Double]? = nil) -> [String: Double] {
        var values = channels(clip, at: ms)
        func blend(toward other: [String: Double], weight: Double) {
            for name in Set(values.keys).union(other.keys) {
                let fallback = channelRest(name)
                let a = values[name] ?? fallback, b = other[name] ?? fallback
                values[name] = b + (a - b) * weight
            }
        }
        let duration = Double(clip.durationMs)
        if ms < blendInMs { blend(toward: from ?? [:], weight: RigEase.inOut.apply(ms / blendInMs)) }
        if ms > duration - blendOutMs { blend(toward: end ?? [:], weight: RigEase.inOut.apply((duration - ms) / blendOutMs)) }
        return values
    }

    static func channelRest(_ name: String) -> Double {
        name.split(separator: ".").last.flatMap { RigChannel(rawValue: String($0)) }?.rest ?? 0
    }

    /// Places every part. `lean` adds a root rotation (the drag spring, a dizzy wobble).
    public static func pose(_ rig: RigSpec, channels values: [String: Double], swaps: [RigSpec.Swap] = [],
                            mounts: [RigSpec.MountKey] = [], at ms: Double = 0, lean: Double = 0) -> RigPose {
        var world: [String: CGAffineTransform] = [:]
        func value(_ bone: String, _ channel: RigChannel) -> Double { values[bone + "." + channel.rawValue] ?? channel.rest }
        func transform(_ name: String, depth: Int = 0) -> CGAffineTransform {
            if let known = world[name] { return known }
            guard let bone = rig.bones[name], depth < RigLimits.maxDepth + 1 else { return .identity }
            let pivot = CGPoint(x: bone.pivot.first ?? 0, y: bone.pivot.dropFirst().first ?? 0)
            var sx = value(name, .sx), sy = value(name, .sy), rot = value(name, .rot)
            if bone.parent == nil {
                let rest = rig.restScale ?? 1
                sx *= rest
                sy *= rest
                rot += lean
            }
            // Scale and rotate about the pivot, then offset: applied to points in that order.
            let local = CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(rotationAngle: rot * .pi / 180))
                .concatenating(CGAffineTransform(translationX: pivot.x + value(name, .x), y: pivot.y + value(name, .y)))
            let result = bone.parent.map { local.concatenating(transform($0, depth: depth + 1)) } ?? local
            world[name] = result
            return result
        }
        func opacity(_ name: String) -> Double {
            var total = 1.0, current: String? = name, depth = 0
            while let bone = current, depth <= RigLimits.maxDepth {
                total *= value(bone, .opacity)
                current = rig.bones[bone]?.parent
                depth += 1
            }
            return min(max(total, 0), 1)
        }
        var shown: [String: String] = [:]
        // Stable by time: at one instant, later entries (explicit swaps after face presets) win.
        for swap in swaps.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }).map(\.element)
        where swap.at <= ms { shown[swap.part] = swap.variant }
        let placed = rig.parts.compactMap { part -> RigPlacedPart? in
            let variant = shown[part.name]
            if variant == "hide" || (variant == nil && part.hidden == true) { return nil }
            let image = variant.flatMap { $0 == "default" ? part.image : part.variants?[$0] } ?? part.image
            let alpha = opacity(part.bone)
            guard alpha > 0 else { return nil }
            if let mount = mountTransform(part, mounts: mounts, at: ms, transform: { transform($0) }) {
                return RigPlacedPart(part: part.name, image: image, rect: .zero, transform: mount, opacity: alpha, mounted: true)
            }
            return RigPlacedPart(part: part.name, image: image, rect: .zero, transform: transform(part.bone), opacity: alpha)
        }
        for name in rig.bones.keys { _ = transform(name) }
        return RigPose(parts: placed, bones: world)
    }

    /// Where a mounted part sits: the mount's rest origin carried by its bone, as one transform of the
    /// image's own rect at the origin, eased from the previous mount over the key's `blendMs`. Nil for a
    /// part no mount key has moved yet (it rides its own bone like any part).
    static func mountTransform(_ part: RigSpec.Part, mounts: [RigSpec.MountKey], at ms: Double,
                               transform: (String) -> CGAffineTransform) -> CGAffineTransform? {
        let keys = mounts.filter { $0.part == part.name && $0.at <= ms }.sorted { $0.at < $1.at }
        guard let current = keys.last else { return nil }
        func placement(_ name: String) -> CGAffineTransform {
            let mount = part.mounts?[name] ?? RigSpec.Mount(bone: part.bone, origin: part.origin)
            return CGAffineTransform(translationX: mount.origin.first ?? 0, y: mount.origin.dropFirst().first ?? 0)
                .concatenating(transform(mount.bone))
        }
        let target = placement(current.mount)
        let blend = current.blendMs ?? 0
        guard blend > 0, ms - current.at < blend else { return target }
        let previous = placement(keys.dropLast().last?.mount ?? "default")
        let u = RigEase.inOut.apply((ms - current.at) / blend)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * u }
        return CGAffineTransform(a: mix(previous.a, target.a), b: mix(previous.b, target.b), c: mix(previous.c, target.c),
                                 d: mix(previous.d, target.d), tx: mix(previous.tx, target.tx), ty: mix(previous.ty, target.ty))
    }

    /// The clip at `ms` (with blends: in from `blendFrom`, out to its `endsOn` pose), or the rest pose
    /// when `clip` is nil.
    public static func pose(_ rig: RigSpec, clip: RigSpec.Clip?, at ms: Double, lean: Double = 0,
                            blendFrom: [String: Double]? = nil, sizes: [String: CGSize] = [:]) -> RigPose {
        if let clip {
            let end = clip.endsOn.flatMap { rig.poses?[$0]?.channels }
            return place(rig, pose(rig, channels: blendedChannels(clip, at: ms, from: blendFrom, to: end),
                                   swaps: rig.swaps(of: clip), mounts: clip.mounts ?? [], at: ms, lean: lean), sizes: sizes)
        }
        return place(rig, pose(rig, channels: [:], lean: lean), sizes: sizes)
    }

    /// A named still pose (a state to bake), with its face.
    public static func pose(_ rig: RigSpec, still name: String, sizes: [String: CGSize] = [:],
                            swaps extra: [RigSpec.Swap] = []) -> RigPose {
        let still = rig.poses?[name]
        return place(rig, pose(rig, channels: still?.channels ?? [:], swaps: rig.faceSwaps(still?.face) + extra), sizes: sizes)
    }

    /// Fills each placed part's rect from its image size (mounted parts sit at the origin of their
    /// own transform).
    static func place(_ rig: RigSpec, _ pose: RigPose, sizes: [String: CGSize]) -> RigPose {
        var result = pose
        let origins = Dictionary(rig.parts.map { ($0.name, $0.origin) }, uniquingKeysWith: { a, _ in a })
        for index in result.parts.indices {
            let placed = result.parts[index]
            let origin = placed.mounted ? [0, 0] : origins[placed.part] ?? [0, 0]
            let size = sizes[placed.image] ?? .zero
            result.parts[index].rect = CGRect(x: origin.first ?? 0, y: origin.dropFirst().first ?? 0,
                                              width: size.width / rig.unitScale, height: size.height / rig.unitScale)
        }
        return result
    }

    /// Channels of whatever a rig pack shows for `clip` at `ms` (a preempted clip mid-motion), for the
    /// next clip to blend in from.
    public static func showing(_ rig: RigSpec, clip: RigSpec.Clip, at ms: Double, blendFrom: [String: Double]? = nil)
        -> [String: Double] {
        blendedChannels(clip, at: ms, from: blendFrom, to: clip.endsOn.flatMap { rig.poses?[$0]?.channels })
    }

    /// How an accessory authored on the rest head moves with the head bone at this pose.
    public static func headMotion(_ rig: RigSpec, pose: RigPose) -> CGAffineTransform? {
        guard let now = pose.bones["head"], let rest = self.pose(rig, channels: [:]).bones["head"] else { return nil }
        return rest.inverted().concatenating(now)
    }
}

public enum RigLimits {
    public static let maxBones = 24
    public static let maxDepth = 8
    public static let maxParts = 48
    public static let maxTracks = 40
    public static let maxKeys = 48
    public static let minClipMs = 100
    public static let channelRange: [RigChannel: ClosedRange<Double>] = [
        .x: -64...64, .y: -64...64, .rot: -180...180, .sx: 0.3...1.5, .sy: 0.3...1.5, .opacity: 0...1,
    ]
    /// Sampling rate for bounds and contours over a clip (design section 7.5).
    public static let sampleHz = 60.0

    /// Rule violations that need no files: tree shape, names, ranges, key order.
    public static func validate(_ rig: RigSpec) -> [String] {
        var errors: [String] = []
        func finite(_ values: [Double]) -> Bool { values.allSatisfy(\.isFinite) }
        if !(1...8).contains(rig.unitScale) { errors.append("unitScale must be 1–8") }
        if let rest = rig.restScale, !(0.5...1).contains(rest) { errors.append("restScale must be 0.5–1") }
        if rig.bones.count > maxBones { errors.append("more than \(maxBones) bones") }
        let roots = rig.bones.filter { $0.value.parent == nil }.map(\.key)
        if roots != ["root"] { errors.append("exactly one parentless bone, named root") }
        for (name, bone) in rig.bones.sorted(by: { $0.key < $1.key }) {
            if bone.pivot.count != 2 || !finite(bone.pivot) || bone.pivot.contains(where: { abs($0) > 512 }) {
                errors.append("bone \(name): pivot must be [x, y]")
            }
            if let parent = bone.parent, rig.bones[parent] == nil { errors.append("bone \(name): unknown parent") }
            if let rot = bone.rot, rot.count != 2 || !finite(rot) || rot[0] > rot[1] { errors.append("bone \(name): rot must be [min, max]") }
            var current = bone.parent, depth = 1
            while let next = current, depth <= maxDepth + 1 { current = rig.bones[next]?.parent; depth += 1 }
            if current != nil { errors.append("bone \(name): cycle or deeper than \(maxDepth)") }
        }
        if let reserve = rig.reserve, reserve.count != 3 || !(0..<reserve[2]).contains(reserve[0])
            || !(0..<MascotPack.canvasSize).contains(reserve[1]) || reserve[2] >= MascotPack.canvasSize {
            errors.append("reserve must be [minX, top, maxX] inside the canvas")
        }
        if rig.parts.isEmpty || rig.parts.count > maxParts { errors.append("1–\(maxParts) parts") }
        var partNames: Set<String> = []
        for part in rig.parts {
            if !partNames.insert(part.name).inserted { errors.append("part \(part.name): duplicate name") }
            if rig.bones[part.bone] == nil { errors.append("part \(part.name): unknown bone") }
            if part.origin.count != 2 || !finite(part.origin) || part.origin.contains(where: { abs($0) > 512 }) {
                errors.append("part \(part.name): origin must be [x, y]")
            }
            if (part.variants ?? [:]).keys.contains(where: { $0 == "default" || $0 == "hide" }) {
                errors.append("part \(part.name): 'default' and 'hide' are reserved")
            }
        }
        for part in rig.parts {
            for (name, mount) in (part.mounts ?? [:]).sorted(by: { $0.key < $1.key }) {
                if name == "default" || rig.bones[mount.bone] == nil || mount.origin.count != 2 || !finite(mount.origin)
                    || mount.origin.contains(where: { abs($0) > 512 }) {
                    errors.append("part \(part.name): bad mount \(name)")
                }
            }
        }
        let partsByName = Dictionary(rig.parts.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for (name, preset) in (rig.faces ?? [:]).sorted(by: { $0.key < $1.key }) {
            for (part, variant) in preset.sorted(by: { $0.key < $1.key }) {
                guard let known = partsByName[part], variant == "default" || variant == "hide" || known.variants?[variant] != nil
                else { errors.append("face \(name): bad \(part) variant"); continue }
            }
        }
        for (name, still) in (rig.poses ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let face = still.face, rig.faces?[face] == nil { errors.append("pose \(name): unknown face \(face)") }
            for (track, value) in still.channels.sorted(by: { $0.key < $1.key }) {
                let pieces = track.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard pieces.count == 2, let bone = rig.bones[pieces[0]], let channel = RigChannel(rawValue: pieces[1]) else {
                    errors.append("pose \(name): unknown channel \(track)"); continue
                }
                var range = channelRange[channel]!
                if channel == .rot, let rot = bone.rot, rot.count == 2 { range = rot[0]...rot[1] }
                if !value.isFinite || !range.contains(value) { errors.append("pose \(name): \(track) out of range") }
            }
        }
        for (name, clip) in (rig.clips ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let end = clip.endsOn, rig.poses?[end] == nil { errors.append("clip \(name): endsOn \(end) is not a pose") }
            for face in clip.faces ?? [] where rig.faces?[face.preset] == nil || !face.at.isFinite
                || !(0...Double(clip.durationMs)).contains(face.at) {
                errors.append("clip \(name): bad face \(face.preset)")
            }
            for mount in clip.mounts ?? [] {
                guard let part = partsByName[mount.part], mount.mount == "default" || part.mounts?[mount.mount] != nil,
                      mount.at.isFinite, (0...Double(clip.durationMs)).contains(mount.at),
                      (0...2000).contains(mount.blendMs ?? 0) else {
                    errors.append("clip \(name): bad mount \(mount.part)"); continue
                }
            }
            guard let policy = ClipCatalog.v1[MascotClipID(name)] else { errors.append("unknown clip \(name)"); continue }
            if clip.durationMs < minClipMs || clip.durationMs > policy.maxDurationMs {
                errors.append("clip \(name): durationMs must be \(minClipMs)–\(policy.maxDurationMs)")
            }
            if clip.tracks.count + (clip.worn?.count ?? 0) > maxTracks { errors.append("clip \(name): more than \(maxTracks) tracks") }
            for (track, keys) in (clip.tracks.sorted(by: { $0.key < $1.key }) + (clip.worn ?? [:]).sorted(by: { $0.key < $1.key })) {
                let pieces = track.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard pieces.count == 2, let bone = rig.bones[pieces[0]], let channel = RigChannel(rawValue: pieces[1]) else {
                    errors.append("clip \(name): unknown track \(track)"); continue
                }
                if keys.isEmpty || keys.count > maxKeys { errors.append("clip \(name): \(track) needs 1–\(maxKeys) keys") }
                var last = -Double.infinity
                for key in keys {
                    if !key.ms.isFinite || key.ms < last || key.ms < 0 || key.ms > Double(clip.durationMs) {
                        errors.append("clip \(name): \(track) key times must rise within the clip"); break
                    }
                    last = key.ms
                    var range = channelRange[channel]!
                    if channel == .rot, let rot = bone.rot, rot.count == 2 { range = rot[0]...rot[1] }
                    if !key.value.isFinite || !range.contains(key.value) {
                        errors.append("clip \(name): \(track) value outside \(range.lowerBound)…\(range.upperBound)"); break
                    }
                }
            }
            for follow in clip.follow ?? [] where rig.bones[follow.bone] == nil || rig.bones[follow.of] == nil
                || !(0...1000).contains(follow.delayMs) || !(-3...3).contains(follow.gain) {
                errors.append("clip \(name): bad follow \(follow.bone)")
            }
            for sway in clip.sway ?? [] where sway.bones.contains(where: { rig.bones[$0] == nil })
                || !(0...45).contains(sway.amp) || !(100...5000).contains(sway.periodMs)
                || !(0...2000).contains(sway.phaseStepMs ?? 0) {
                errors.append("clip \(name): bad sway")
            }
            for swap in clip.swaps ?? [] {
                guard let part = rig.parts.first(where: { $0.name == swap.part }),
                      swap.variant == "default" || swap.variant == "hide" || part.variants?[swap.variant] != nil,
                      swap.at.isFinite, (0...Double(clip.durationMs)).contains(swap.at) else {
                    errors.append("clip \(name): bad swap \(swap.part)"); continue
                }
            }
        }
        return errors
    }
}

/// Outline points of a part image (pixels), for contours of transformed poses without rasterizing:
/// each row's outer ends and each column's top and bottom, at pixel corners.
public struct RigOutline: Equatable, Sendable {
    public var points: [CGPoint]
    public var size: CGSize

    public init(points: [CGPoint], size: CGSize) {
        self.points = points
        self.size = size
    }

    public init?(png data: Data, alphaThreshold: UInt8 = 0) {
        guard let pixels = RigRaster.decode(data) else { return nil }
        let (width, height) = (pixels.width, pixels.height)
        var points: [CGPoint] = []
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels.bytes[(y * width + x) * 4 + 3] }
        for y in 0..<height {
            guard let first = (0..<width).first(where: { alpha($0, y) > alphaThreshold }),
                  let last = (0..<width).last(where: { alpha($0, y) > alphaThreshold }) else { continue }
            for dy in [0.0, 1.0] {
                points.append(CGPoint(x: Double(first), y: Double(y) + dy))
                points.append(CGPoint(x: Double(last + 1), y: Double(y) + dy))
            }
        }
        for x in 0..<width {
            guard let top = (0..<height).first(where: { alpha(x, $0) > alphaThreshold }),
                  let bottom = (0..<height).last(where: { alpha(x, $0) > alphaThreshold }) else { continue }
            for dx in [0.0, 1.0] {
                points.append(CGPoint(x: Double(x) + dx, y: Double(top)))
                points.append(CGPoint(x: Double(x) + dx, y: Double(bottom + 1)))
            }
        }
        self.init(points: points, size: CGSize(width: width, height: height))
    }
}

/// Pixel helpers shared by outlines, baking and the placeholder rig.
public enum RigRaster {
    public struct Pixels {
        public var width: Int
        public var height: Int
        public var bytes: [UInt8]
    }

    public static func decode(_ data: Data) -> Pixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return pixels(of: image)
    }

    public static func pixels(of image: CGImage) -> Pixels? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
    }

    public static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Draws a pose into a context whose user space is canvas units, y down.
    public static func draw(_ pose: RigPose, images: [String: CGImage], in context: CGContext) {
        for part in pose.parts {
            guard let image = images[part.image] else { continue }
            context.saveGState()
            context.concatenate(part.transform)
            context.setAlpha(part.opacity)
            // CoreGraphics draws images bottom-up: flip within the part's rect.
            context.translateBy(x: part.rect.minX, y: part.rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: part.rect.size))
            context.restoreGState()
        }
    }

    /// A pose rasterized at `side` pixels for the 256-unit canvas (baking states, render checks).
    public static func render(_ pose: RigPose, images: [String: CGImage], side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = Double(side) / Double(MascotPack.canvasSize)
        context.translateBy(x: 0, y: Double(side))
        context.scaleBy(x: scale, y: -scale)
        draw(pose, images: images, in: context)
        return context.makeImage()
    }
}

extension RigPose {
    /// Top contour over the 256 canvas columns of the placed parts' outlines (any coverage).
    public func contour(outlines: [String: RigOutline], unitScale: Double, extra: [CGPoint] = []) -> [Int?] {
        var tops = [Int](repeating: .max, count: MascotPack.canvasSize)
        forEachPoint(outlines: outlines, unitScale: unitScale, extra: extra) { point in
            let column = Int(point.x.rounded(.down)), row = max(0, Int(point.y.rounded(.down)))
            for col in (column - 1)...column where (0..<tops.count).contains(col) { tops[col] = min(tops[col], row) }
        }
        return tops.map { $0 == .max ? nil : $0 }
    }

    /// Bounding box of the placed outlines, canvas units.
    public func bounds(outlines: [String: RigOutline], unitScale: Double, extra: [CGPoint] = []) -> CGRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        forEachPoint(outlines: outlines, unitScale: unitScale, extra: extra) { point in
            minX = min(minX, point.x); maxX = max(maxX, point.x); minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return minX <= maxX ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : .null
    }

    /// Row spans of the placed outlines (for the hover outline).
    public func rows(outlines: [String: RigOutline], unitScale: Double) -> [ClosedRange<Int>?] {
        var low = [Int](repeating: .max, count: MascotPack.canvasSize), high = [Int](repeating: .min, count: MascotPack.canvasSize)
        forEachPoint(outlines: outlines, unitScale: unitScale, extra: []) { point in
            let row = Int(point.y.rounded(.down)), column = Int(point.x.rounded(.down))
            for r in (row - 1)...row where (0..<low.count).contains(r) {
                low[r] = max(0, min(low[r], column - 1))
                high[r] = min(MascotPack.canvasSize - 1, max(high[r], column))
            }
        }
        return low.indices.map { low[$0] <= high[$0] ? low[$0]...high[$0] : nil }
    }

    private func forEachPoint(outlines: [String: RigOutline], unitScale: Double, extra: [CGPoint],
                              _ body: (CGPoint) -> Void) {
        for part in parts {
            guard let outline = outlines[part.image] else { continue }
            for point in outline.points {
                let local = CGPoint(x: part.rect.minX + point.x / unitScale, y: part.rect.minY + point.y / unitScale)
                body(local.applying(part.transform))
            }
        }
        extra.forEach(body)
    }
}
