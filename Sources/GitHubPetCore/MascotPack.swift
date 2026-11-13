import CryptoKit
import Foundation
import ImageIO

/// Mascot pack manifest, schema v1 (agreed with design):
/// `<pack>/manifest.json` with 256×256 RGBA PNG frames per state, anchor at the bottom-centre
/// ground point, per-frame durations and a static fallback used for reduced motion.
public struct MascotPackManifest: Codable, Equatable, Sendable {
    public struct Canvas: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
    }

    public struct StateSpec: Codable, Equatable, Sendable {
        public var frames: [String]
        public var durationMs: [Int]
        public var loop: Bool
        public var staticFallback: String
    }

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var canvas: Canvas
    public var anchor: [Int]
    public var states: [String: StateSpec]
    public var frameSha256: [String: String]?
}

public enum MascotPackError: Error, Equatable, CustomStringConvertible {
    case unreadableManifest
    case unsupportedSchema(Int)
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

    public var description: String {
        switch self {
        case .unreadableManifest: return "manifest.json missing or not valid JSON"
        case .unsupportedSchema(let v): return "unsupported schemaVersion \(v)"
        case .badCanvas: return "canvas must be 256×256"
        case .badAnchor: return "anchor must be [x, y] inside the canvas"
        case .missingState(let s): return "required state '\(s)' missing"
        case .frameCount(let s): return "state '\(s)' needs 1–\(MascotPack.maxFrames) frames"
        case .durationMismatch(let s): return "state '\(s)' durationMs count differs from frames"
        case .durationOutOfRange(let s, let d): return "state '\(s)' duration \(d)ms outside 125–2000"
        case .unsafePath(let p): return "unsafe path '\(p)'"
        case .missingFile(let p): return "file not found '\(p)'"
        case .notPNG(let p): return "not a PNG '\(p)'"
        case .wrongSize(let p, let w, let h): return "'\(p)' is \(w)×\(h), expected canvas size"
        case .checksumMismatch(let p): return "SHA-256 mismatch for '\(p)'"
        case .tooLarge(let p): return "'\(p)' exceeds the size limit"
        case .undecodable(let p): return "'\(p)' is not a decodable RGBA PNG"
        case .notRegularFile(let p): return "'\(p)' is not a regular file"
        }
    }
}

public struct MascotPackErrors: Error, Equatable {
    public var errors: [MascotPackError]
}

/// A validated pack: every referenced path resolved to a file inside the pack directory.
public struct MascotPack: Equatable, Sendable {
    public static let schemaVersion = 1
    /// Pack bundled with the app (`assets/mascots/<id>` in the repository).
    public static let defaultPackID = "mona-pet-v1"
    public static let canvasSize = 256
    public static let maxFrames = 12
    public static let durationRange = 125...2000
    /// Read limits, enforced before decoding or hashing.
    public static let maxManifestBytes = 256 * 1024
    public static let maxImageBytes = 4 * 1024 * 1024
    /// Largest attention lean (design storyboard #29), about the ground anchor.
    public static let attentionLeanDegrees = 5.0

    public var directory: URL
    public var manifest: MascotPackManifest
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
        frameURLs(for: .attention).count >= AttentionGesture.friendlyDoubleWave.frameCount
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
        if pose.angle != 0, pose.state == .attention, let frame = pose.frame, leaningOutlines.indices.contains(frame) {
            return ArtProfile.rotatedContour(leaningOutlines[frame], canvas: MascotPack.canvasSize, from: pose.angle,
                                             to: pose.angle, pivot: AttentionGesture.pivot, margin: 0)
        }
        let contours = poseContours(pose.state)
        let index = pose.frame.map { $0 + 1 } ?? 0
        return contours.indices.contains(index) ? contours[index] : nil
    }

    /// Every pose's contour, upright and leaning, for the fixed lane height and the count's range.
    public var allContours: [[Int?]] {
        MascotState.allCases.flatMap(poseContours) + leaningContours
    }

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

    /// Load and validate; on any error the caller keeps the native placeholder.
    public static func load(from directory: URL) -> Result<MascotPack, MascotPackErrors> {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? readBounded(manifestURL, limit: maxManifestBytes),
              let manifest = try? JSONDecoder().decode(MascotPackManifest.self, from: data) else {
            return .failure(MascotPackErrors(errors: [.unreadableManifest]))
        }
        let errors = validate(manifest, in: directory)
        guard errors.isEmpty else { return .failure(MascotPackErrors(errors: errors)) }
        var pack = MascotPack(directory: directory, manifest: manifest)
        for state in MascotState.allCases {
            let urls = [pack.staticFallbackURL(for: state)].compactMap { $0 } + pack.frameURLs(for: state)
            let images = urls.compactMap { try? readBounded($0, limit: maxImageBytes) }
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
        return .success(pack)
    }

    /// Rows from the top of the image down to the first visible row, or nil if the image is
    /// undecodable or fully transparent.
    public static func opaqueTopInset(_ data: Data) -> Int? {
        ArtProfile(png: data)?.top
    }

    public static func validate(_ manifest: MascotPackManifest, in directory: URL) -> [MascotPackError] {
        var errors: [MascotPackError] = []
        guard manifest.schemaVersion == schemaVersion else { return [.unsupportedSchema(manifest.schemaVersion)] }
        if manifest.canvas.width != canvasSize || manifest.canvas.height != canvasSize { errors.append(.badCanvas) }
        if manifest.anchor.count != 2 || !manifest.anchor.allSatisfy({ (0...canvasSize).contains($0) }) {
            errors.append(.badAnchor)
        }
        var checked: Set<String> = []
        for state in MascotState.allCases {
            guard let spec = manifest.states[state.rawValue] else {
                errors.append(.missingState(state.rawValue))
                continue
            }
            // An over-limit state is invalid already: never open or decode its paths.
            guard !spec.frames.isEmpty, spec.frames.count <= maxFrames, spec.durationMs.count <= maxFrames else {
                errors.append(.frameCount(state.rawValue))
                continue
            }
            if spec.frames.count != spec.durationMs.count { errors.append(.durationMismatch(state.rawValue)) }
            for duration in spec.durationMs where !durationRange.contains(duration) {
                errors.append(.durationOutOfRange(state.rawValue, duration))
            }
            for path in spec.frames + [spec.staticFallback] where checked.insert(path).inserted {
                errors += validateFile(path, in: directory, checksums: manifest.frameSha256 ?? [:])
            }
        }
        return errors
    }

    /// Relative, `.png`, no `..`, and resolving inside the pack directory.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              path.lowercased().hasSuffix(".png"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty || $0 == "." }
    }

    static func validateFile(_ path: String, in directory: URL, checksums: [String: String]) -> [MascotPackError] {
        guard isSafeRelativePath(path) else { return [.unsafePath(path)] }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let fileURL = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard fileURL.path.hasPrefix(root + "/") else { return [.unsafePath(path)] }
        let data: Data
        do {
            data = try readBounded(fileURL, limit: maxImageBytes)
        } catch ReadError.tooLarge {
            return [.tooLarge(path)]
        } catch ReadError.notRegularFile {
            return [.notRegularFile(path)]
        } catch {
            return [.missingFile(path)]
        }
        guard let size = pngSize(data) else { return [.notPNG(path)] }
        // Header dimensions first: a small file can declare a huge image, and decoding it
        // would allocate the full pixel buffer.
        if size.width != canvasSize || size.height != canvasSize {
            return [.wrongSize(path, size.width, size.height)]
        }
        guard isDecodableRGBA(data) else { return [.undecodable(path)] }
        var errors: [MascotPackError] = []
        if let expected = checksums[path] {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if actual != expected.lowercased() { errors.append(.checksumMismatch(path)) }
        }
        return errors
    }

    enum ReadError: Error { case tooLarge, unreadable, notRegularFile }

    /// Reads at most `limit` bytes from a regular file; larger files are rejected without
    /// reading them whole. Opened non-blocking and checked with fstat, so a FIFO or device
    /// planted in a pack can never stall launch.
    static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ReadError.unreadable }
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
