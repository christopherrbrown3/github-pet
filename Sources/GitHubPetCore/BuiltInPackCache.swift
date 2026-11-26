import CryptoKit
import Foundation

/// Built-in packs verified once per process (#138: the animated packs hold ~480 frames, so every model
/// re-verifying them is slow, most of all in debug test runs, where the app's and the core's tests share
/// it). Keyed by the directory and a fingerprint of its files (manifest bytes, then every file's path,
/// size and modification time), so a pack that changes on disk is verified again. The placeholder-clip
/// variant (#138 QA) is kept beside the plain pack, since building it re-measures the pack's clips.
/// Callers asking for the same pack at once wait for one verification instead of each running their
/// own (parallel tests on a cold cache did, which was most of the suite's time).
public enum BuiltInPackCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var packs: [String: MascotPack] = [:]
    nonisolated(unsafe) private static var loading: [String: NSLock] = [:]
    nonisolated(unsafe) private static var verificationCounts: [String: Int] = [:]

    /// How many full verifications this process has run for `directory` (tests).
    static func verifications(of directory: URL) -> Int {
        lock.withLock { verificationCounts[directory.standardizedFileURL.path, default: 0] }
    }

    /// Held while `key` is being built, so a second caller finds the result instead of building it too.
    private static func building<T>(_ key: String, _ body: () -> T) -> T {
        let keyLock = lock.withLock {
            if let existing = loading[key] { return existing }
            let created = NSLock()
            loading[key] = created
            return created
        }
        return keyLock.withLock(body)
    }

    public static func load(from directory: URL, expectedID: String,
                            placeholderClips: Bool = false) -> Result<MascotPack, MascotPackErrors> {
        guard let key = fingerprint(directory) else {
            let result = MascotPack.load(from: directory, expectedID: expectedID, budget: .bundled)
            return placeholderClips ? result.map { $0.withPlaceholderClips() } : result
        }
        let verified: Result<MascotPack, MascotPackErrors> = building(key) {
            if let pack = lock.withLock({ packs[key] }) { return .success(pack) }
            lock.withLock { verificationCounts[directory.standardizedFileURL.path, default: 0] += 1 }
            let result = MascotPack.load(from: directory, expectedID: expectedID, budget: .bundled)
            if case .success(let pack) = result { lock.withLock { packs[key] = pack } }
            return result
        }
        guard placeholderClips, case .success(let pack) = verified else { return verified }
        let variant = key + "#placeholder-clips"
        return .success(building(variant) {
            if let clips = lock.withLock({ packs[variant] }) { return clips }
            let clips = pack.withPlaceholderClips()
            lock.withLock { packs[variant] = clips }
            return clips
        })
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
