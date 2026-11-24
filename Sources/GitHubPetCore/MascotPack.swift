import CryptoKit
import Foundation
import ImageIO

/// Mascot pack manifest, schema v1 (agreed with design):
/// `<pack>/manifest.json` with 256×256 RGBA PNG frames per state, anchor at the bottom-centre
/// ground point, per-frame durations and a static fallback used for reduced motion.
///
/// Schema v2 (#138, docs/design/animation-v1.md) adds, all optional: held `drag` and `doze` states
/// (loop), one-shot `clips`, `accessories` drawn over the art, a default `head` point and per-frame
/// `framePoints`. A v1 manifest loads exactly as before; v2 keys in a v1 manifest are ignored.
public struct MascotPackManifest: Codable, Equatable, Sendable {
    public struct Canvas: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public struct StateSpec: Codable, Equatable, Sendable {
        public var frames: [String]
        public var durationMs: [Int]
        public var loop: Bool
        public var staticFallback: String

        public init(frames: [String], durationMs: [Int], loop: Bool, staticFallback: String) {
            self.frames = frames
            self.durationMs = durationMs
            self.loop = loop
            self.staticFallback = staticFallback
        }
    }

    /// A one-shot clip (v2): plays once and holds its last frame until it ends. No static fallback:
    /// no clip ever plays under Reduce Motion.
    public struct ClipSpec: Codable, Equatable, Sendable {
        public var frames: [String]
        public var durationMs: [Int]
        public var loop: Bool?
        /// Whether the incident hat stays on during the clip (default keep).
        public var accessories: AccessoryVisibility?

        public init(frames: [String], durationMs: [Int], loop: Bool? = nil, accessories: AccessoryVisibility? = nil) {
            self.frames = frames
            self.durationMs = durationMs
            self.loop = loop
            self.accessories = accessories
        }
    }

    /// An overlay image (v2): a 256×256 canvas authored aligned to the pack's default head point.
    public struct AccessorySpec: Codable, Equatable, Sendable {
        public var image: String
        public var attach: String

        public init(image: String, attach: String = "head") {
            self.image = image
            self.attach = attach
        }
    }

    /// Named canvas points: `head` places the hat, `nozzle` emits incident-end's spray and `hand`
    /// places item-cleared's sparkle.
    public struct Points: Codable, Equatable, Sendable {
        public var head: [Int]?
        public var nozzle: [Int]?
        public var hand: [Int]?

        public init(head: [Int]? = nil, nozzle: [Int]? = nil, hand: [Int]? = nil) {
            self.head = head
            self.nozzle = nozzle
            self.hand = hand
        }
    }

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var canvas: Canvas
    public var anchor: [Int]
    public var states: [String: StateSpec]
    public var frameSha256: [String: String]?
    public var clips: [String: ClipSpec]?
    public var accessories: [String: AccessorySpec]?
    public var points: Points?
    public var framePoints: [String: Points]?
    /// Schema v3 (#138, docs/design/animation-v2-rig.md): a cutout rig whose clips play instead of
    /// frame clips of the same name. States stay baked frames, so idle draws exactly as before.
    public var rig: RigSpec?

    public init(schemaVersion: Int, id: String, name: String, canvas: Canvas, anchor: [Int], states: [String: StateSpec],
                frameSha256: [String: String]? = nil, clips: [String: ClipSpec]? = nil, accessories: [String: AccessorySpec]? = nil,
                points: Points? = nil, framePoints: [String: Points]? = nil, rig: RigSpec? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.canvas = canvas
        self.anchor = anchor
        self.states = states
        self.frameSha256 = frameSha256
        self.clips = clips
        self.accessories = accessories
        self.points = points
        self.framePoints = framePoints
        self.rig = rig
    }

    /// Whether the v2 additions apply (a v1 manifest ignores them).
    public var isV2: Bool { schemaVersion >= 2 }
    /// Whether the rig applies (an older manifest's `rig` is ignored).
    public var isV3: Bool { schemaVersion >= 3 }
}

/// Display-only sanitizing for strings a pack author controls (manifest `id`/`name`, state names
/// and file paths echoed in errors). Never applied to the stored values used for matching.
public enum PackLabel {
    /// Longest label shown, in grapheme clusters; longer input is cut and ends with "…".
    public static let maxGraphemes = 48
    /// Scalar cap applied first so a single enormous grapheme (stacked combining marks) stays bounded.
    public static let maxScalars = 256
    public static let fallbackID = "(unnamed pack)"
    /// Paths get a larger cap, cut in the middle so the identifying tail stays visible.
    public static let maxPathGraphemes = 160
    /// Leading graphemes kept when a path is cut in the middle (enough for e.g. "/Users/name").
    static let pathHeadGraphemes = 24
    /// Scalar cap for paths: well above any real path, still bounded.
    public static let maxPathScalars = 2048
    /// Hex digits of the path digest shown when a path is elided (#60): two paths that differ only
    /// in the cut part stay distinguishable.
    static let pathDigestDigits = 8
    /// Errors listed in a joined caption before "+N more", and the cap on the whole caption.
    public static let maxListedErrors = 5
    public static let maxJoinedGraphemes = 600

    /// Control characters (C0, DEL, C1, line/paragraph separators) become a space, invisible format
    /// characters (zero-width, bidi overrides/isolates and marks, BOM, soft hyphen) are dropped,
    /// runs of spaces collapse, and the result is trimmed and bounded. Empty results give `fallback`.
    public static func sanitize(_ raw: String, fallback: String = fallbackID) -> String {
        let (text, truncated) = clean(raw, scalarCap: maxScalars)
        guard !text.isEmpty else { return fallback }
        guard text.count > maxGraphemes else { return truncated ? text + "…" : text }
        return String(text.prefix(maxGraphemes)) + "…"
    }

    /// Same cleaning for a file-system path, bounded at `maxPathGraphemes`. A longer path keeps its
    /// first `pathHeadGraphemes` and its tail (starting at a component boundary when one is near),
    /// joined by "…", so the pack directory's own name is never the part cut off.
    public static func sanitizePath(_ raw: String, fallback: String = "(unknown path)") -> String {
        let (text, truncated) = clean(raw, scalarCap: maxPathScalars)
        guard !text.isEmpty else { return fallback }
        let characters = Array(text)
        // A path cut at the scalar cap also loses its tail, so it is tagged like a middle cut.
        guard characters.count > maxPathGraphemes || truncated else { return text }
        let digest = SHA256.hash(data: Data(raw.utf8)).prefix(pathDigestDigits / 2)
            .map { String(format: "%02x", $0) }.joined()
        let marker = "…#\(digest)…"
        let head = String(characters.prefix(pathHeadGraphemes))
        let room = max(0, maxPathGraphemes - pathHeadGraphemes - marker.count)
        var tail = Array(characters.suffix(room))
        if let slash = tail.prefix(32).firstIndex(of: "/") { tail.removeFirst(slash) }
        return head + marker + String(tail)
    }

    /// Rejection errors as one caption: at most `maxListedErrors` entries, then "+N more", and never
    /// longer than `maxJoinedGraphemes` however long the entries are.
    public static func joined(_ errors: [MascotPackError], separator: String) -> String {
        var text = errors.prefix(maxListedErrors).map(\.description).joined(separator: separator)
        if errors.count > maxListedErrors { text += "\(separator)+\(errors.count - maxListedErrors) more" }
        guard text.count > maxJoinedGraphemes else { return text }
        return String(text.prefix(maxJoinedGraphemes - 1)) + "…"
    }

    private static func clean(_ raw: String, scalarCap maxScalars: Int) -> (text: String, truncated: Bool) {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        var truncated = false
        scan: for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                pendingSpace = !scalars.isEmpty
            case .format, .surrogate, .privateUse, .unassigned:
                continue
            default:
                // A pending separator and this scalar must fit together; never leave a
                // trailing space or exceed the content cap when the buffer has one slot left.
                if scalars.count + (pendingSpace ? 1 : 0) >= maxScalars { truncated = true; break scan }
                if pendingSpace { scalars.append(" "); pendingSpace = false }
                scalars.append(scalar)
            }
        }
        return (String(scalars), truncated)
    }
}

extension MascotPackManifest {
    /// Safe to show or log; `id` and `name` themselves stay untouched.
    public var displayID: String { PackLabel.sanitize(id) }
    public var displayName: String { PackLabel.sanitize(name, fallback: displayID) }
}

public enum MascotPackError: Error, Equatable, CustomStringConvertible {
    case unreadableManifest
    case unexpectedID(String, expected: String)
    case unsupportedSchema(Int)
    case wrongLoopFlag(String, expected: Bool)
    case badCanvas
    case badAnchor
    case missingState(String)
    case frameCount(String)
    case durationMismatch(String)
    case durationOutOfRange(String, Int)
    case unsafePath(String)
    case missingFile(String)
    case notPNG(String)
    case wrongSize(String, Int, Int)
    case checksumMismatch(String)
    case tooLarge(String)
    case undecodable(String)
    case notRegularFile(String)
    case clipTooLong(String, Int, Int)
    case packTooLarge(Int)
    case tooManyFrames(Int)
    // Schema v2 (#138).
    case unknownState(String)
    case unknownClip(String)
    case unknownAccessory(String)
    case badAccessory(String)
    case badPoint(String)
    case tooManyImages(Int, limit: Int)
    case outsideArt(String)
    // Schema v3 (#138).
    case badRig(String)

    public var description: String {
        func q(_ value: String) -> String { PackLabel.sanitize(value, fallback: "(invalid)") }
        func path(_ value: String) -> String { PackLabel.sanitizePath(value, fallback: "(invalid)") }
        switch self {
        case .unreadableManifest: return "manifest.json missing or not valid JSON"
        case .unexpectedID(let id, let expected): return "pack ID '\(q(id))' must be '\(q(expected))'"
        case .unsupportedSchema(let v): return "unsupported schemaVersion \(v)"
        case .wrongLoopFlag(let s, let expected):
            guard !MascotClipID.heldStates.contains(MascotClipID(s)), ClipCatalog.v1[MascotClipID(s)] == nil else {
                return "'\(q(s))' must declare \"loop\": \(expected) (drag and doze loop; clips play once)"
            }
            return "state '\(q(s))' must declare \"loop\": \(expected) (idle loops; attention and urgent play once)"
        case .badCanvas: return "canvas must be 256×256"
        case .badAnchor: return "anchor must be [128, 232], the v1 ground point the renderer uses"
        case .missingState(let s): return "required state '\(q(s))' missing"
        case .frameCount(let s): return "state or clip '\(q(s))' needs 1–\(MascotPack.maxFrames) frames"
        case .durationMismatch(let s): return "state '\(q(s))' durationMs count differs from frames"
        case .durationOutOfRange(let s, let d): return "state '\(q(s))' duration \(d)ms outside 125–2000"
        case .unsafePath(let p): return "unsafe path '\(path(p))'"
        case .missingFile(let p): return "file not found '\(path(p))'"
        case .notPNG(let p): return "not a PNG '\(path(p))'"
        case .wrongSize(let p, let w, let h): return "'\(path(p))' is \(w)×\(h), expected canvas size"
        case .checksumMismatch(let p): return "SHA-256 mismatch for '\(path(p))'"
        case .tooLarge(let p): return "'\(path(p))' exceeds the size limit"
        case .undecodable(let p): return "'\(path(p))' is not a decodable RGBA PNG"
        case .notRegularFile(let p): return "'\(path(p))' is not a regular file"
        case .clipTooLong(let s, let total, let limit):
            return "state '\(q(s))' plays \(total)ms once, longer than its \(limit)ms event clip"
        case .tooManyFrames(let total):
            return "pack has \(total) frames; at most \(MascotPack.maxPackFrames) in total (\(MascotPack.maxFrames) per state)"
        case .unknownState(let s): return "unknown state '\(q(s))' (schema v2 adds only drag and doze)"
        case .unknownClip(let s): return "unknown clip '\(q(s))'"
        case .unknownAccessory(let s): return "unknown accessory '\(q(s))'"
        case .badAccessory(let s): return "accessory '\(q(s))' must attach to \"head\""
        case .badPoint(let s): return "point '\(path(s))' must be [x, y] inside the 256×256 canvas, for a frame the pack uses"
        case .tooManyImages(let total, let limit):
            return "pack has \(total) distinct images; at most \(limit) (\(MascotPack.maxFrames) frames per state or clip)"
        case .outsideArt(let p):
            return "'\(path(p))' draws outside the idle, attention and urgent art; clips and accessories must stay inside it"
        case .badRig(let message): return "rig: \(q(message))"
        case .packTooLarge(let limit):
            return "pack images total more than \(limit / (1024 * 1024)) MiB (each image at most \(MascotPack.maxImageBytes / (1024 * 1024)) MiB, 256×256, up to \(MascotPack.maxFrames) frames per state)"
        }
    }
}

public struct MascotPackErrors: Error, Equatable {
    public var errors: [MascotPackError]

    public init(errors: [MascotPackError]) { self.errors = errors }
}

/// A validated pack: every referenced path resolved to a file inside the pack directory.
/// Image limits for a pack. Custom packs keep #123's per-image and total byte caps with v2's larger
/// image count; bundled packs have the tighter design budget (#138), so the app download stays small.
public struct PackBudget: Equatable, Sendable {
    /// Distinct images (frames, fallbacks, accessories) in a v2 pack. State frames keep the 24 rule.
    public var maxImages: Int
    public var maxBytes: Int
    public var maxImageBytes: Int
    /// Frames per state or clip.
    public var maxSequenceFrames: Int
    /// Bundled art must keep every clip, held and hat pixel inside the three states' art, so the
    /// layout never changes. A custom pack that draws outside gets a taller lane instead.
    public var enforcesArtBounds: Bool

    public static let custom = PackBudget(maxImages: 256, maxBytes: MascotPack.maxPackBytes,
                                          maxImageBytes: MascotPack.maxImageBytes, maxSequenceFrames: MascotPack.maxFrames,
                                          enforcesArtBounds: false)
    // Frame sequences (#138): up to 16 frames for each of ~13 clips and loops per skin.
    public static let bundled = PackBudget(maxImages: 256, maxBytes: 16 * 1024 * 1024, maxImageBytes: 96 * 1024,
                                           maxSequenceFrames: 16, enforcesArtBounds: true)
}

public struct MascotPack: Equatable, Sendable {
    public static let schemaVersion = 1
    /// Newest manifest schema this build reads (#138); every older one still loads.
    public static let latestSchemaVersion = 3
    /// Pack bundled with the app (`assets/mascots/<id>` in the repository).
    public static let defaultPackID = MascotSkin.mona.rawValue
    public static let canvasSize = 256
    /// The only supported ground anchor (schema v1), in canvas pixels.
    public static let anchor = [128, 232]
    /// Frames per state or clip: a generated 4 × 4 sequence sheet is 16 (#138).
    public static let maxFrames = 16
    /// Frames across all states (bundled packs use 9 and 12). Checked before any file is opened.
    public static let maxPackFrames = 24
    public static let durationRange = 125...2000
    /// Clip frames (#138 frame sequences) play at about 14 fps: shorter than a state frame may be.
    public static let clipDurationRange = 40...2000
    /// Read limits, enforced before decoding or hashing.
    public static let maxManifestBytes = 256 * 1024
    public static let maxImageBytes = 4 * 1024 * 1024
    /// All distinct images of one pack together (the bundled packs' referenced images are about
    /// 0.5 MiB). Reading stops once the running total passes it, so a pack of many large images
    /// can't stall or exhaust memory. An image over `maxImageBytes` is rejected on its own
    /// (`tooLarge`) and is not added to the total: it is already an error and is never retained.
    public static let maxPackBytes = 16 * 1024 * 1024
    /// Largest rig part image edge (v3): a 2× part of the whole canvas is 512.
    public static let maxPartSide = 1024
    /// Largest attention lean (design storyboard #29), about the ground anchor.
    public static let attentionLeanDegrees = 5.0

    public var directory: URL
    public var manifest: MascotPackManifest
    /// The exact bytes validated for each image, keyed by manifest path. Everything after
    /// validation (outlines, rendering) uses these; image paths are never reopened, so a custom
    /// pack edited after loading (a FIFO, an oversized file) can't stall or exhaust the app.
    public var imageData: [String: Data] = [:]
    /// v2 (#138): outline (any coverage) of every held-pose, clip and accessory image, by path.
    public var extraOutlines: [String: ArtProfile] = [:]
    /// Upright contours of v2 poses: every clip and held frame, and every frame that can wear the
    /// hat composited with it (#138). Part of `uprightContours`, so the count tracks them.
    public var extraUprightContours: [[Int?]] = []
    /// Drag and dizzy frames (with the hat where worn) over their whole lean.
    public var extraLeaningContours: [[Int?]] = []
    /// Largest drag/dizzy lean (≤ the #29 lean) whose swept outline stays inside the lane the states
    /// already need, so a lean never changes the layout.
    public var clipLeanLimit: Double = MascotPack.attentionLeanDegrees
    /// Clips and held poses synthesized from existing frames until the art lands (render-check and
    /// `--placeholder-clips` only); the renderer tags them "PH".
    public var placeholderClips: Set<MascotClipID> = []
    /// v3 (#138): outline points and pixel size of every rig image, by path.
    public var rigOutlines: [String: RigOutline] = [:]

    /// Validated bytes of a state's frames, in order.
    public func frameData(for state: MascotState) -> [Data] {
        (manifest.states[state.rawValue]?.frames ?? []).compactMap { imageData[$0] }
    }

    /// Validated bytes of a state's static pose.
    public func staticFallbackData(for state: MascotState) -> Data? {
        manifest.states[state.rawValue].flatMap { imageData[$0.staticFallback] }
    }
    /// Visible outline of each state (its static pose and every animation frame), so UI such
    /// as the hover summary can sit right beside the character without covering any frame.
    public var artProfiles: [MascotState: ArtProfile] = [:]
    /// Visible outline of each state's static pose (what the mascot holds between clips),
    /// followed by each of its animation frames.
    public var poseProfiles: [MascotState: [ArtProfile]] = [:]
    /// The same poses counting any coverage (alpha > 0).
    public var poseOutlines: [MascotState: [ArtProfile]] = [:]

    /// Attention's outline swept over its ±5° lean about the ground anchor (#29), for placing
    /// UI while that clip plays.
    public var sweptAttentionProfile: ArtProfile? {
        artProfiles[.attention]?.swept(degrees: Self.attentionLeanDegrees, pivot: CGPoint(x: 128, y: 232))
    }

    /// Top contour (any coverage) of each state's poses, static pose first: what the count label
    /// tracks to stay near-touching the art (#28).
    public func poseContours(_ state: MascotState) -> [[Int?]] {
        (poseOutlines[state] ?? []).map(\.columnTops)
    }

    /// The attention gesture, when this pack's attention state has the frames it uses.
    public var attentionGesture: AttentionGesture? {
        // Counted from the manifest, not `frameURLs`: the view asks on every frame it draws (#166).
        (manifest.states[MascotState.attention.rawValue]?.frames.count ?? 0) >= AttentionGesture.friendlyDoubleWave.frameCount
            ? AttentionGesture.friendlyDoubleWave : nil
    }

    /// Outline points of the attention frames the gesture leans (precomputed at load; rotating
    /// them for a drawn pose is point math, not pixel work).
    public var leaningOutlines: [[CGPoint]] = []

    /// Every leaning frame's contour over the whole ±lean range: for the fixed lane height and the
    /// count's movement range.
    public var leaningContours: [[Int?]] = []

    /// Contour of a drawn pose: upright from `poseContours`, or the leaning attention frame
    /// rotated by exactly the pose's angle (callers add `MascotLayout.leanReserve` for it).
    public func contour(for pose: MascotPose) -> [Int?]? {
        if pose.clip != nil || !pose.accessories.isEmpty { return clipContour(for: pose) }
        if pose.angle != 0, pose.state == .attention, let frame = pose.frame, leaningOutlines.indices.contains(frame) {
            return ArtProfile.rotatedContour(leaningOutlines[frame], canvas: MascotPack.canvasSize, from: pose.angle,
                                             to: pose.angle, pivot: AttentionGesture.pivot, margin: 0)
        }
        let contours = poseContours(pose.state)
        let index = pose.frame.map { $0 + 1 } ?? 0
        return contours.indices.contains(index) ? contours[index] : nil
    }

    /// Every upright pose's contour (static and frames of every state): where the head is (#116).
    public var uprightContours: [[Int?]] { MascotState.allCases.flatMap(poseContours) + extraUprightContours }

    /// Every pose's contour, upright and leaning, for the fixed lane height and the count's range.
    public var allContours: [[Int?]] { uprightContours + leaningContours + extraLeaningContours }

    /// Outline across every state.
    public var artProfile: ArtProfile? { ArtProfile.union(MascotState.allCases.compactMap { artProfiles[$0] }) }

    /// Canvas pixels above the highest visible pixel in any state.
    public var artTopInset: Int { artProfile?.top ?? 0 }

    public func frameURLs(for state: MascotState) -> [URL] {
        manifest.states[state.rawValue]?.frames.map { directory.appendingPathComponent($0) } ?? []
    }

    public func staticFallbackURL(for state: MascotState) -> URL? {
        manifest.states[state.rawValue].map { directory.appendingPathComponent($0.staticFallback) }
    }

    /// Load and validate. A built-in pack must match its expected ID before any frames are read.
    public static func load(from directory: URL, expectedID: String? = nil,
                            budget: PackBudget = .custom) -> Result<MascotPack, MascotPackErrors> {
        // Everything is read relative to one descriptor for the pack directory, never following a
        // symlink below it, so files can't be swapped for links out of the pack between a check
        // and the read: what is validated is what is read.
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { return .failure(MascotPackErrors(errors: [.unreadableManifest])) }
        defer { close(root) }
        guard let data = try? readInPack(root: root, path: "manifest.json", limit: maxManifestBytes),
              let manifest = try? JSONDecoder().decode(MascotPackManifest.self, from: data) else {
            return .failure(MascotPackErrors(errors: [.unreadableManifest]))
        }
        if let expectedID, manifest.id != expectedID {
            return .failure(MascotPackErrors(errors: [.unexpectedID(manifest.id, expected: expectedID)]))
        }
        let (errors, validated) = validateReading(manifest, root: root, budget: budget)
        guard errors.isEmpty else { return .failure(MascotPackErrors(errors: errors)) }
        var pack = MascotPack(directory: directory, manifest: manifest)
        pack.imageData = validated
        for state in MascotState.allCases {
            let images = [pack.staticFallbackData(for: state)].compactMap { $0 } + pack.frameData(for: state)
            pack.poseProfiles[state] = images.compactMap { ArtProfile(png: $0) }
            // The no-overlap outline counts any coverage. Upright frames only (PM decision for
            // #27): the #29 lean will re-aim once at clip start/end using `sweptAttentionProfile`.
            pack.poseOutlines[state] = images.compactMap { ArtProfile(png: $0, alphaThreshold: 0) }
            pack.artProfiles[state] = ArtProfile.union(pack.poseOutlines[state] ?? [])
            if state == .attention, let gesture = pack.attentionGesture {
                // poseOutlines are static first, then frames.
                let frames = Array((pack.poseOutlines[.attention] ?? []).dropFirst().prefix(gesture.frameCount))
                pack.leaningOutlines = frames.map(\.outlinePoints)
                // Each leaning frame swept over the whole lean, in 1° bands so the lane height and the
                // count's range are known without a full sweep per angle.
                // Plus exact contours every 0.25°, so the count's lowest tracked position is known too.
                pack.leaningContours = pack.leaningOutlines.flatMap { points in
                    stride(from: -gesture.maxAngle, to: gesture.maxAngle, by: 1).map {
                        ArtProfile.rotatedContour(points, canvas: canvasSize, from: $0, to: $0 + 1,
                                                  pivot: AttentionGesture.pivot, step: 0.05)
                    } + stride(from: -gesture.maxAngle, through: gesture.maxAngle, by: 0.25).map {
                        ArtProfile.rotatedContour(points, canvas: canvasSize, from: $0, to: $0, pivot: AttentionGesture.pivot)
                    }
                }
            }
        }
        // v2: every clip, held and accessory pixel stays inside the three states' art (#138), so the
        // label lane and hover placement never change.
        let artErrors = pack.measureClips(enforcingBounds: budget.enforcesArtBounds)
            + pack.measureRig(enforcingBounds: budget.enforcesArtBounds)
        guard artErrors.isEmpty else { return .failure(MascotPackErrors(errors: artErrors)) }
        return .success(pack)
    }

    /// Rows from the top of the image down to the first visible row, or nil if the image is
    /// undecodable or fully transparent.
    public static func opaqueTopInset(_ data: Data) -> Int? {
        ArtProfile(png: data)?.top
    }

    public static func validate(_ manifest: MascotPackManifest, in directory: URL) -> [MascotPackError] {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { return [.unreadableManifest] }
        defer { close(root) }
        return validateReading(manifest, root: root, budget: .custom).errors
    }

    /// Validates the manifest and every image, returning the errors and the bytes that passed.
    static func validateReading(_ manifest: MascotPackManifest, root: Int32, budget: PackBudget)
        -> (errors: [MascotPackError], data: [String: Data]) {
        var errors: [MascotPackError] = []
        var validated: [String: Data] = [:]
        guard (schemaVersion...latestSchemaVersion).contains(manifest.schemaVersion) else {
            return ([.unsupportedSchema(manifest.schemaVersion)], [:])
        }
        if manifest.canvas.width != canvasSize || manifest.canvas.height != canvasSize { errors.append(.badCanvas) }
        // Rendering, the attention lean and ground-preserving resizes all use the v1 ground point;
        // a pack declaring another one would be drawn and resized wrongly, so it is rejected.
        if manifest.anchor != anchor { errors.append(.badAnchor) }
        // A state over its own limit gets that state's more specific error below.
        if manifest.isV2 {
            let v2Errors = validateV2Structure(manifest, budget: budget)
            if !v2Errors.isEmpty { return (errors + v2Errors, [:]) }
            if manifest.isV3 {
                guard let rig = manifest.rig else { return (errors + [.badRig("schema 3 needs a rig section")], [:]) }
                let rigErrors = RigLimits.validate(rig).map(MascotPackError.badRig)
                if !rigErrors.isEmpty { return (errors + rigErrors, [:]) }
            }
            let images = manifest.imagePaths.count + (manifest.isV3 ? manifest.rig?.imagePaths.count ?? 0 : 0)
            if images > budget.maxImages { return (errors + [.tooManyImages(images, limit: budget.maxImages)], [:]) }
        }
        // State frames keep #123's total in both schemas (v2 clips have their own image budget).
        let totalFrames = manifest.states.filter { MascotState(rawValue: $0.key) != nil }.values.reduce(0) { $0 + $1.frames.count }
        if totalFrames > maxPackFrames, manifest.states.values.allSatisfy({ $0.frames.count <= maxFrames }) { return (errors + [.tooManyFrames(totalFrames)], [:]) }
        var checked: Set<String> = []
        var totalBytes = 0
        for state in MascotState.allCases {
            guard let spec = manifest.states[state.rawValue] else {
                errors.append(.missingState(state.rawValue))
                continue
            }
            // An over-limit state is invalid already: never open or decode its paths.
            let frameLimit = min(maxFrames, budget.maxSequenceFrames)
            guard !spec.frames.isEmpty, spec.frames.count <= frameLimit, spec.durationMs.count <= frameLimit else {
                errors.append(.frameCount(state.rawValue))
                continue
            }
            // Playback is fixed by the renderer (idle loops, event clips play once), so a manifest
            // declaring otherwise would not behave as written and is rejected.
            if spec.loop != (state == .idle) { errors.append(.wrongLoopFlag(state.rawValue, expected: state == .idle)) }
            if spec.frames.count != spec.durationMs.count { errors.append(.durationMismatch(state.rawValue)) }
            for duration in spec.durationMs where !durationRange.contains(duration) {
                errors.append(.durationOutOfRange(state.rawValue, duration))
            }
            // Attention and urgent play once per event clip; a longer sequence would be cut off
            // (its last frames never shown), so it is rejected rather than truncated.
            if state != .idle {
                let limit = Int((EventClipQueue.duration(of: state) * 1000).rounded())
                let total = saturatingSum(spec.durationMs)
                if total > limit { errors.append(.clipTooLong(state.rawValue, total, limit)) }
            }
            for path in spec.frames + [spec.staticFallback] where checked.insert(path).inserted {
                let (fileErrors, data) = validateFile(path, root: root, checksums: manifest.frameSha256 ?? [:],
                                                      limit: budget.maxImageBytes)
                errors += fileErrors
                if fileErrors.isEmpty, let data { validated[path] = data }
                totalBytes += data?.count ?? 0
                if totalBytes > budget.maxBytes { return (errors + [.packTooLarge(budget.maxBytes)], [:]) }
            }
        }
        // v2 additions: held poses, clips and accessories, under the same image checks and budget.
        if manifest.isV2 {
            for path in manifest.v2ImagePaths where checked.insert(path).inserted {
                let (fileErrors, data) = validateFile(path, root: root, checksums: manifest.frameSha256 ?? [:],
                                                      limit: budget.maxImageBytes)
                errors += fileErrors
                if fileErrors.isEmpty, let data { validated[path] = data }
                totalBytes += data?.count ?? 0
                if totalBytes > budget.maxBytes { return (errors + [.packTooLarge(budget.maxBytes)], [:]) }
            }
        }
        // v3 rig parts: any size up to `maxPartSide`, with a little more room per image than frames.
        if manifest.isV3 {
            let limit = min(maxImageBytes, max(budget.maxImageBytes, 160 * 1024))
            for path in manifest.rig?.imagePaths ?? [] where checked.insert(path).inserted {
                let (fileErrors, data) = validateFile(path, root: root, checksums: manifest.frameSha256 ?? [:],
                                                      limit: limit, part: true)
                errors += fileErrors
                if fileErrors.isEmpty, let data { validated[path] = data }
                totalBytes += data?.count ?? 0
                if totalBytes > budget.maxBytes { return (errors + [.packTooLarge(budget.maxBytes)], [:]) }
            }
        }
        return (errors, validated)
    }

    /// v2 manifest rules that need no file access: names, frame counts, durations, loop flags, points.
    static func validateV2Structure(_ manifest: MascotPackManifest, budget: PackBudget) -> [MascotPackError] {
        var errors: [MascotPackError] = []
        let core = Set(MascotState.allCases.map(\.rawValue)), held = Set(MascotClipID.loopingStates.map(\.rawValue))
        func sequence(_ name: String, frames: [String], durations: [Int], range: ClosedRange<Int> = durationRange) -> Bool {
            let limit = min(maxFrames, budget.maxSequenceFrames)
            guard !frames.isEmpty, frames.count <= limit, durations.count <= limit else {
                errors.append(.frameCount(name)); return false
            }
            if frames.count != durations.count { errors.append(.durationMismatch(name)) }
            for duration in durations where !range.contains(duration) { errors.append(.durationOutOfRange(name, duration)) }
            return true
        }
        for (name, spec) in manifest.states.sorted(by: { $0.key < $1.key }) where !core.contains(name) {
            guard held.contains(name) else { errors.append(.unknownState(name)); continue }
            guard sequence(name, frames: spec.frames, durations: spec.durationMs, range: clipDurationRange) else { continue }
            if !spec.loop { errors.append(.wrongLoopFlag(name, expected: true)) }
        }
        for (name, spec) in (manifest.clips ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let policy = ClipCatalog.v1[MascotClipID(name)] else { errors.append(.unknownClip(name)); continue }
            guard sequence(name, frames: spec.frames, durations: spec.durationMs, range: clipDurationRange) else { continue }
            if spec.loop == true { errors.append(.wrongLoopFlag(name, expected: false)) }
            let total = saturatingSum(spec.durationMs)
            if total > policy.maxDurationMs { errors.append(.clipTooLong(name, total, policy.maxDurationMs)) }
        }
        for (name, spec) in (manifest.accessories ?? [:]).sorted(by: { $0.key < $1.key }) {
            if !AccessoryPolicy.all.contains(MascotClipID(name)) { errors.append(.unknownAccessory(name)) }
            else if spec.attach != "head" { errors.append(.badAccessory(name)) }
        }
        func valid(_ point: [Int]?) -> Bool {
            guard let point else { return true }
            return point.count == 2 && point.allSatisfy { (0..<canvasSize).contains($0) }
        }
        func valid(_ points: MascotPackManifest.Points) -> Bool { valid(points.head) && valid(points.nozzle) && valid(points.hand) }
        // The hat is authored for the default head point, so a pack with accessories must name it.
        if let points = manifest.points, !valid(points) { errors.append(.badPoint("points")) }
        else if !(manifest.accessories ?? [:]).isEmpty, manifest.points?.head == nil { errors.append(.badPoint("points")) }
        let used = Set(manifest.imagePaths)
        for (path, points) in (manifest.framePoints ?? [:]).sorted(by: { $0.key < $1.key })
        where !used.contains(path) || !valid(points) {
            errors.append(.badPoint(path))
        }
        // Mist is emitted only where a nozzle is named: incident-end's spray frames (02 and 03) need one.
        if let end = manifest.clips?[MascotClipID.incidentEnd.rawValue] {
            for path in Set(end.frames.dropFirst(2).prefix(2)).sorted()
            where (manifest.framePoints?[path]?.nozzle ?? manifest.points?.nozzle) == nil {
                errors.append(.badPoint(path))
            }
        }
        return errors
    }

    /// Sum of manifest durations that saturates instead of trapping on overflow (a manifest may
    /// declare e.g. Int.max; such values are rejected as out of range, never crash the app).
    static func saturatingSum(_ values: [Int]) -> Int {
        var total = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(max(value, 0))
            total = overflow ? .max : sum
        }
        return total
    }

    /// Relative, `.png`, no `..`, and resolving inside the pack directory.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        // No NUL or other control characters: C APIs stop at NUL, so "..\0x/a.png" would reach
        // openat as "..".
        guard !path.isEmpty, !path.unicodeScalars.contains(where: isControl), !path.hasPrefix("/"),
              !path.hasPrefix("~"), path.lowercased().hasSuffix(".png"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty || $0 == "." }
    }

    /// Validates one image and returns the bytes it checked (nil if it couldn't be read).
    static func validateFile(_ path: String, root: Int32, checksums: [String: String], limit: Int = maxImageBytes,
                             part: Bool = false) -> (errors: [MascotPackError], data: Data?) {
        guard isSafeRelativePath(path) else { return ([.unsafePath(path)], nil) }
        let data: Data
        do {
            data = try readInPack(root: root, path: path, limit: min(limit, maxImageBytes))
        } catch ReadError.symlink, ReadError.unsafeComponent {
            return ([.unsafePath(path)], nil)
        } catch ReadError.tooLarge {
            return ([.tooLarge(path)], nil)
        } catch ReadError.notRegularFile {
            return ([.notRegularFile(path)], nil)
        } catch {
            return ([.missingFile(path)], nil)
        }
        guard let size = pngSize(data) else { return ([.notPNG(path)], data) }
        // Header dimensions first: a small file can declare a huge image, and decoding it
        // would allocate the full pixel buffer.
        if part ? !(1...maxPartSide).contains(size.width) || !(1...maxPartSide).contains(size.height)
                : size.width != canvasSize || size.height != canvasSize {
            return ([.wrongSize(path, size.width, size.height)], data)
        }
        guard isDecodableRGBA(data) else { return ([.undecodable(path)], data) }
        var errors: [MascotPackError] = []
        if let expected = checksums[path] {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if actual != expected.lowercased() { errors.append(.checksumMismatch(path)) }
        }
        return (errors, data)
    }

    enum ReadError: Error { case tooLarge, unreadable, notRegularFile, symlink, unsafeComponent }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 0x20 || scalar.value == 0x7F }

    /// Opens `path` (a safe relative path) under the pack's directory descriptor one component at a
    /// time with O_NOFOLLOW, so no symlink anywhere below the pack is followed, and reads it
    /// bounded from that same descriptor.
    static func readInPack(root: Int32, path: String, limit: Int) throws -> Data {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // Defence in depth, whatever the caller checked: every component must be a plain name that
        // means the same thing to openat as it does here.
        guard !components.isEmpty, components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && !component.unicodeScalars.contains(where: isControl)
        }) else { throw ReadError.unsafeComponent }
        guard let name = components.last else { throw ReadError.unreadable }
        var directory = root
        defer { if directory != root { close(directory) } }
        func fail(_ code: Int32) -> ReadError { code == ELOOP || code == ENOTDIR ? .symlink : .unreadable }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw fail(errno) }
            if directory != root { close(directory) }
            directory = next
        }
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw fail(errno) }
        return try readBounded(fd: fd, limit: limit)
    }

    /// Reads at most `limit` bytes from a regular file; larger files are rejected without
    /// reading them whole. Opened non-blocking and checked with fstat, so a FIFO or device
    /// planted in a pack can never stall launch.
    static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ReadError.unreadable }
        return try readBounded(fd: fd, limit: limit)
    }

    /// `readBounded` on an already open descriptor, which it takes ownership of.
    static func readBounded(fd: Int32, limit: Int) throws -> Data {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReadError.unreadable }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ReadError.notRegularFile }
        guard let data = try handle.read(upToCount: limit + 1) else { return Data() }
        if data.count > limit { throw ReadError.tooLarge }
        return data
    }

    /// True if ImageIO fully decodes the image as a PNG with an alpha channel.
    static func isDecodableRGBA(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              (CGImageSourceGetType(source) as String?) == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return false }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Width and height from the PNG IHDR chunk, or nil if the data is not a PNG.
    public static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, Array(bytes[0..<8]) == signature,
              Array(bytes[12..<16]) == Array("IHDR".utf8) else { return nil }
        func be32(_ offset: Int) -> Int {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        return (be32(16), be32(20))
    }
}

extension MascotLayout {
    /// Layout for a loaded pack (nil: the placeholder, labels above the art square).
    public init(artSide: CGFloat, pack: MascotPack?) {
        self.init(artSide: artSide, contours: pack?.allContours ?? [], headContours: pack?.uprightContours ?? [])
    }
}
