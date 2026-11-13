import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import GitHubPetCore

/// A real, decodable PNG of the given size, with or without an alpha channel.
func makePNG(width: Int, height: Int, alpha: Bool = true) -> Data {
    let info: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: alpha ? 0.5 : 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Signature and IHDR only: passes a header sniff but has no pixel data.
private func pngHeaderOnly(width: Int, height: Int) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
    bytes += Array("IHDR".utf8)
    for value in [width, height] {
        bytes += [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
    bytes += [8, 6, 0, 0, 0]
    return Data(bytes)
}

private let validFrame = makePNG(width: 256, height: 256)

private struct PackFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubPetPack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("frames"),
                                                withIntermediateDirectories: true)
        for state in MascotState.allCases {
            for index in 0..<2 {
                try validFrame.write(to: directory.appendingPathComponent("frames/\(state.rawValue)_\(index).png"))
            }
        }
    }

    func manifest(mutate: (inout [String: Any]) -> Void = { _ in }) throws {
        var states: [String: Any] = [:]
        for state in MascotState.allCases {
            states[state.rawValue] = [
                "frames": ["frames/\(state.rawValue)_0.png", "frames/\(state.rawValue)_1.png"],
                "durationMs": [400, 400],
                "loop": state == .idle,
                "staticFallback": "frames/\(state.rawValue)_0.png",
            ]
        }
        var json: [String: Any] = [
            "schemaVersion": 1, "id": "test-pack", "name": "Test",
            "canvas": ["width": 256, "height": 256], "anchor": [128, 232], "states": states,
        ]
        mutate(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("manifest.json"))
    }

    func load() -> Result<MascotPack, MascotPackErrors> { MascotPack.load(from: directory) }

    func errors() -> [MascotPackError] {
        if case .failure(let failure) = load() { return failure.errors }
        return []
    }
}

@Suite struct MascotPackTests {
    @Test func validPackLoads() throws {
        let fixture = try PackFixture()
        try fixture.manifest()
        let pack = try fixture.load().get()
        #expect(pack.frameURLs(for: .idle).count == 2)
        #expect(pack.staticFallbackURL(for: .urgent)?.lastPathComponent == "urgent_0.png")
    }

    @Test func missingManifestIsRejected() throws {
        let fixture = try PackFixture()
        #expect(fixture.errors() == [.unreadableManifest])
    }

    @Test func wrongSchemaIsRejected() throws {
        let fixture = try PackFixture()
        try fixture.manifest { $0["schemaVersion"] = 2 }
        #expect(fixture.errors() == [.unsupportedSchema(2)])
    }

    @Test func missingRequiredStateIsRejected() throws {
        let fixture = try PackFixture()
        try fixture.manifest { json in
            var states = json["states"] as! [String: Any]
            states["urgent"] = nil
            json["states"] = states
        }
        #expect(fixture.errors().contains(.missingState("urgent")))
    }

    @Test func pathTraversalAndAbsolutePathsAreRejected() throws {
        #expect(!MascotPack.isSafeRelativePath("../escape.png"))
        #expect(!MascotPack.isSafeRelativePath("frames/../../escape.png"))
        #expect(!MascotPack.isSafeRelativePath("/etc/escape.png"))
        #expect(!MascotPack.isSafeRelativePath("~/escape.png"))
        #expect(!MascotPack.isSafeRelativePath("frames/idle.gif"))
        #expect(!MascotPack.isSafeRelativePath("frames//idle.png"))
        #expect(MascotPack.isSafeRelativePath("frames/idle_0.png"))
    }

    @Test func symlinkEscapingPackIsRejected() throws {
        let fixture = try PackFixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).png")
        try validFrame.write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent("frames/link.png"),
                                                   withDestinationURL: outside)
        try fixture.manifest { json in
            var states = json["states"] as! [String: Any]
            var idle = states["idle"] as! [String: Any]
            idle["staticFallback"] = "frames/link.png"
            states["idle"] = idle
            json["states"] = states
        }
        #expect(fixture.errors().contains(.unsafePath("frames/link.png")))
    }

    @Test func durationRulesAreEnforced() throws {
        let fixture = try PackFixture()
        try fixture.manifest { json in
            var states = json["states"] as! [String: Any]
            var idle = states["idle"] as! [String: Any]
            idle["durationMs"] = [50, 400]
            states["idle"] = idle
            var urgent = states["urgent"] as! [String: Any]
            urgent["durationMs"] = [400]
            states["urgent"] = urgent
            json["states"] = states
        }
        let errors = fixture.errors()
        #expect(errors.contains(.durationOutOfRange("idle", 50)))
        #expect(errors.contains(.durationMismatch("urgent")))
    }

    @Test func wrongFrameSizeAndNonPNGAreRejected() throws {
        let fixture = try PackFixture()
        try makePNG(width: 128, height: 256).write(to: fixture.directory.appendingPathComponent("frames/idle_1.png"))
        try Data("GIF89a".utf8).write(to: fixture.directory.appendingPathComponent("frames/attention_1.png"))
        try fixture.manifest()
        let errors = fixture.errors()
        #expect(errors.contains(.wrongSize("frames/idle_1.png", 128, 256)))
        #expect(errors.contains(.notPNG("frames/attention_1.png")))
    }

    @Test func checksumsAreVerifiedWhenPresent() throws {
        let fixture = try PackFixture()
        let data = try Data(contentsOf: fixture.directory.appendingPathComponent("frames/idle_0.png"))
        let good = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try fixture.manifest { $0["frameSha256"] = ["frames/idle_0.png": good, "frames/idle_1.png": String(repeating: "0", count: 64)] }
        #expect(fixture.errors() == [.checksumMismatch("frames/idle_1.png")])
    }
}

@Suite struct MascotPackLimitTests {
    @Test func headerOnlyPNGIsRejectedAsUndecodable() throws {
        let fixture = try PackFixture()
        try pngHeaderOnly(width: 256, height: 256).write(to: fixture.directory.appendingPathComponent("frames/idle_1.png"))
        try fixture.manifest()
        #expect(fixture.errors() == [.undecodable("frames/idle_1.png")])
    }

    @Test func opaquePNGWithoutAlphaIsRejected() throws {
        let fixture = try PackFixture()
        try makePNG(width: 256, height: 256, alpha: false)
            .write(to: fixture.directory.appendingPathComponent("frames/urgent_0.png"))
        try fixture.manifest()
        #expect(fixture.errors() == [.undecodable("frames/urgent_0.png")])
    }

    @Test func oversizedImageIsRejectedBeforeDecoding() throws {
        let fixture = try PackFixture()
        var big = validFrame
        big.append(Data(count: MascotPack.maxImageBytes))
        try big.write(to: fixture.directory.appendingPathComponent("frames/attention_0.png"))
        try fixture.manifest()
        #expect(fixture.errors() == [.tooLarge("frames/attention_0.png")])
    }

    @Test func oversizedManifestIsRejected() throws {
        let fixture = try PackFixture()
        try fixture.manifest { $0["padding"] = String(repeating: "x", count: MascotPack.maxManifestBytes) }
        #expect(fixture.errors() == [.unreadableManifest])
    }

    @Test func overLimitFrameCountSkipsFileValidation() throws {
        let fixture = try PackFixture()
        try fixture.manifest { json in
            var states = json["states"] as! [String: Any]
            var idle = states["idle"] as! [String: Any]
            // Thousands of missing paths: a valid count would report each one.
            idle["frames"] = (0..<5000).map { "frames/missing_\($0).png" }
            idle["durationMs"] = Array(repeating: 400, count: 5000)
            states["idle"] = idle
            json["states"] = states
        }
        #expect(fixture.errors() == [.frameCount("idle")])
    }

    @Test func wrongDimensionsAreRejectedBeforeDecoding() throws {
        let fixture = try PackFixture()
        // Declares 8192×8192 (256 MiB decoded) with no pixel data: rejected on the header alone.
        try pngHeaderOnly(width: 8192, height: 8192)
            .write(to: fixture.directory.appendingPathComponent("frames/idle_1.png"))
        try fixture.manifest()
        #expect(fixture.errors() == [.wrongSize("frames/idle_1.png", 8192, 8192)])
    }

    @Test(.timeLimit(.minutes(1))) func fifoManifestAndFrameDoNotBlock() throws {
        let fixture = try PackFixture()
        let frame = fixture.directory.appendingPathComponent("frames/urgent_1.png")
        try FileManager.default.removeItem(at: frame)
        #expect(mkfifo(frame.path, 0o600) == 0)
        try fixture.manifest()
        #expect(fixture.errors() == [.notRegularFile("frames/urgent_1.png")])

        let manifest = fixture.directory.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest)
        #expect(mkfifo(manifest.path, 0o600) == 0)
        #expect(fixture.errors() == [.unreadableManifest])
    }

    @Test func boundedReadAcceptsExactlyTheLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-\(UUID().uuidString)")
        try Data(count: 10).write(to: url)
        #expect(try MascotPack.readBounded(url, limit: 10).count == 10)
        #expect(throws: MascotPack.ReadError.tooLarge) { try MascotPack.readBounded(url, limit: 9) }
    }
}

@Suite struct ArtBoundsTests {
    @Test func topInsetIsTheFirstVisibleRow() {
        // makePNG fills the bottom-left quadrant: the top half is transparent.
        #expect(MascotPack.opaqueTopInset(makePNG(width: 256, height: 256)) == 128)
        #expect(MascotPack.opaqueTopInset(makePNG(width: 256, height: 256, alpha: false)) == 0)
        #expect(MascotPack.opaqueTopInset(Data("not a png".utf8)) == nil)
    }

    @Test func loadedPackRecordsTheHighestStaticPose() throws {
        let fixture = try PackFixture()
        try fixture.manifest()
        let pack = try fixture.load().get()
        #expect(pack.poseProfiles[.idle]?.first?.top == 128)
        #expect(pack.artTopInset <= 128, "the attention sway can reach higher than the upright poses")
    }
}

@Suite struct BundledPackTests {
    /// The repository's shipped pack must pass the same validation the app runs at launch.
    @Test func repositoryPackIsValid() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("assets/mascots/\(MascotPack.defaultPackID)", isDirectory: true)
        let pack = try MascotPack.load(from: directory).get()
        #expect(pack.manifest.id == MascotPack.defaultPackID)
        for state in MascotState.allCases {
            #expect(!pack.frameURLs(for: state).isEmpty)
            #expect(pack.staticFallbackURL(for: state) != nil)
        }
        #expect(pack.manifest.states["idle"]?.loop == true)
        #expect(pack.manifest.states["attention"]?.loop == false)
        #expect(pack.manifest.frameSha256?.count == 12)
        #expect(pack.artTopInset == 19, "the swept attention lean reaches 19 px below the canvas top")
    }
}
