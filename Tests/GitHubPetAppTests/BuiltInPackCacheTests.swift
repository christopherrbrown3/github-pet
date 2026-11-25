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
        let first = try BuiltInPackCache.load(from: copy, expectedID: "little-chris-v1").get()
        let again = try BuiltInPackCache.load(from: copy, expectedID: "little-chris-v1").get()
        #expect(first == again)
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
