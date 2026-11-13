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

    public var directory: URL
    public var manifest: MascotPackManifest

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
        return errors.isEmpty ? .success(MascotPack(directory: directory, manifest: manifest)) : .failure(MascotPackErrors(errors: errors))
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
