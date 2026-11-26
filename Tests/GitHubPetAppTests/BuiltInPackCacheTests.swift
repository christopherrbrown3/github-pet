import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

/// #138: built-in packs are verified once per process, and again whenever their files change.
@Suite struct BuiltInPackCacheTests {
    @Test func reusesAVerifiedPackUntilItsFilesChange() throws {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("assets/mascots/little-chris-v1")
        let copy = fm.temporaryDirectory.appendingPathComponent("pack-cache-\(UUID().uuidString)/little-chris-v1")
        defer { try? fm.removeItem(at: copy.deletingLastPathComponent()) }
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        for item in ["manifest.json", "frames"] {
            try fm.copyItem(at: source.appendingPathComponent(item), to: copy.appendingPathComponent(item))
        }
        // Callers asking at once (parallel tests on a cold cache) share one verification.
        let results = Locked<[MascotPack?]>(Array(repeating: nil, count: 4))
        DispatchQueue.concurrentPerform(iterations: 4) { index in
            let pack = try? BuiltInPackCache.load(from: copy, expectedID: "little-chris-v1").get()
            results.withLock { $0[index] = pack }
        }
        let loaded = results.withLock { $0 }
        let first = try #require(loaded[0])
        #expect(loaded.allSatisfy { $0 == first })
        let again = try BuiltInPackCache.load(from: copy, expectedID: "little-chris-v1").get()
        #expect(first == again)
        #expect(BuiltInPackCache.verifications(of: copy) == 1)
        // The placeholder-clip variant is kept beside it, built from the verified pack.
        let clips = try BuiltInPackCache.load(from: copy, expectedID: "little-chris-v1", placeholderClips: true).get()
        #expect(clips.placeholderClips.contains(AccessoryPolicy.firefighterHat) && first.placeholderClips.isEmpty)
        #expect(try BuiltInPackCache.load(from: copy, expectedID: "little-chris-v1", placeholderClips: true).get() == clips)
        // A frame that no longer matches its checksum is caught: the changed files are verified again.
        let frame = copy.appendingPathComponent(try #require(first.manifest.clips?["poke"]?.frames.last))
        var bytes = try Data(contentsOf: frame)
        bytes.append(0)
        try bytes.write(to: frame)
        if case .success = BuiltInPackCache.load(from: copy, expectedID: "little-chris-v1") {
            Issue.record("a changed frame was served from the cache")
        }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
