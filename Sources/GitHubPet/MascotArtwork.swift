import CryptoKit
import Foundation
import GitHubPetCore

struct MascotArtwork {
    enum Source: Equatable {
        case builtIn(MascotSkin), custom, placeholder
    }

    let source: Source
    let pack: MascotPack?
    var notice: String?
    var errors: [MascotPackError] = []
    var locksPicker = false

    var logDescription: String {
        pack.map { "mascot pack \($0.manifest.displayID) loaded from \(PackLabel.sanitizePath($0.directory.path))" }
            ?? (errors.isEmpty ? "mascot placeholder (no pack)"
                : "mascot placeholder (pack rejected: \(PackLabel.joined(errors, separator: "; ")))")
    }
}

/// Resolves launch overrides before the built-in choice. Only the two verified built-in results
/// are cached, so switching between them does not reopen any validated frame path.
struct MascotArtworkLoader {
    let forcePlaceholder: Bool
    let overrideDirectory: URL?
    /// #138 QA and renders: synthesize "PH" clips from the pack's own frames until the art lands.
    let placeholderClips: Bool
    let builtInDirectory: (MascotSkin) -> URL?
    private var builtIns: [MascotSkin: Result<MascotPack, MascotPackErrors>] = [:]

    init(options: LaunchOptions, builtInDirectory: @escaping (MascotSkin) -> URL?) {
        forcePlaceholder = options.forcePlaceholder
        overrideDirectory = options.packDirectory
        placeholderClips = options.placeholderClips
        self.builtInDirectory = builtInDirectory
    }

    private func withClips(_ pack: MascotPack) -> MascotPack {
        placeholderClips ? pack.withPlaceholderClips() : pack
    }

    /// True when the launch fixes the artwork (placeholder or custom pack), so the picker is locked.
    var locksPicker: Bool { forcePlaceholder || overrideDirectory != nil }

    /// Keeps what an off-main load verified, so later switches to the same built-in don't reload it.
    mutating func adoptCache(from other: MascotArtworkLoader) {
        builtIns.merge(other.builtIns) { current, _ in current }
    }

    mutating func resolve(_ skin: MascotSkin) -> MascotArtwork {
        if forcePlaceholder {
            return MascotArtwork(source: .placeholder, pack: nil, notice: "This launch uses the placeholder.",
                                 locksPicker: true)
        }
        if let overrideDirectory {
            switch MascotPack.load(from: overrideDirectory).map(withClips) {
            case .success(let pack):
                return MascotArtwork(source: .custom, pack: pack,
                                     notice: "Using custom pack \(pack.manifest.displayName) for this launch.",
                                     locksPicker: true)
            case .failure(let failure):
                return MascotArtwork(source: .placeholder, pack: nil,
                                     notice: "Custom pack rejected. Showing the placeholder.",
                                     errors: failure.errors, locksPicker: true)
            }
        }

        return resolveBuiltIn(skin, cacheOnly: false) ?? MascotArtwork(source: .placeholder, pack: nil)
    }

    /// What a built-in skin shows if it has already been verified, or nil: never reads the disk.
    /// Settings skin cards use it so opening Settings can't block on a pack load (#41).
    mutating func cachedBuiltInArtwork(_ skin: MascotSkin) -> MascotArtwork? {
        resolveBuiltIn(skin, cacheOnly: true)
    }

    private mutating func resolveBuiltIn(_ skin: MascotSkin, cacheOnly: Bool) -> MascotArtwork? {
        guard let result = loadBuiltIn(skin, cacheOnly: cacheOnly) else { return nil }
        switch result {
        case .success(let pack):
            return MascotArtwork(source: .builtIn(skin), pack: pack)
        case .failure(let failure):
            if skin == .littleChris {
                guard let fallback = loadBuiltIn(.mona, cacheOnly: cacheOnly) else { return nil }
                if case .success(let mona) = fallback {
                    return MascotArtwork(source: .builtIn(.mona), pack: mona,
                                         notice: "Little Chris is unavailable. Showing Mona.", errors: failure.errors)
                }
            }
            return MascotArtwork(source: .placeholder, pack: nil,
                                 notice: "\(skin.name) is unavailable. Showing the placeholder.", errors: failure.errors)
        }
    }

    private mutating func loadBuiltIn(_ skin: MascotSkin, cacheOnly: Bool = false) -> Result<MascotPack, MascotPackErrors>? {
        if let cached = builtIns[skin] { return cached }
        if cacheOnly { return nil }
        let result: Result<MascotPack, MascotPackErrors>
        if let directory = builtInDirectory(skin) {
            // Bundled art has the tighter design budget (#138); custom packs keep #123's.
            result = BuiltInPackCache.load(from: directory, expectedID: skin.rawValue).map(withClips)
        } else {
            result = .failure(MascotPackErrors(errors: [.unreadableManifest]))
        }
        builtIns[skin] = result
        return result
    }
}

/// Built-in packs verified once per process (#138: the animated packs hold ~480 frames, so every model
/// re-verifying them is slow, most of all in debug test runs). Keyed by the directory and a fingerprint
/// of its files (manifest bytes, then every file's path, size and modification time), so a pack that
/// changes on disk is verified again.
enum BuiltInPackCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var packs: [String: MascotPack] = [:]

    static func load(from directory: URL, expectedID: String) -> Result<MascotPack, MascotPackErrors> {
        let key = fingerprint(directory)
        if let key, let pack = lock.withLock({ packs[key] }) { return .success(pack) }
        let result = MascotPack.load(from: directory, expectedID: expectedID, budget: .bundled)
        if let key, case .success(let pack) = result { lock.withLock { packs[key] = pack } }
        return result
    }

    private static func fingerprint(_ directory: URL) -> String? {
        guard let manifest = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return nil }
        var hash = SHA256()
        hash.update(data: manifest)
        var entries: [String] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            entries.append("\(url.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        for entry in entries.sorted() { hash.update(data: Data(entry.utf8)) }
        return directory.standardizedFileURL.path + "#" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Carries a value across the detached load. The loader holds a directory-lookup closure and the
/// result holds only value types; neither is touched by another task while the load runs.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
