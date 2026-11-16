import Foundation
import Testing
@testable import GitHubPetCore

struct PackLabelTests {
    @Test func normalNamePassesThrough() {
        #expect(PackLabel.sanitize("Mona Pet v1") == "Mona Pet v1")
        #expect(PackLabel.sanitize("mona-pet-v1") == "mona-pet-v1")
        #expect(PackLabel.sanitize("Café 🐙 モナ") == "Café 🐙 モナ")
    }

    @Test func newlinesCannotForgeLogLines() {
        let out = PackLabel.sanitize("evil\nGitHubPet: mascot pack trusted\r\nloaded\u{2028}x")
        #expect(!out.contains("\n") && !out.contains("\r") && !out.contains("\u{2028}"))
        #expect(out == "evil GitHubPet: mascot pack trusted loaded x")
    }

    @Test func ansiEscapeIsRemoved() {
        let out = PackLabel.sanitize("\u{1B}[31mred\u{1B}[0m\u{9B}2J\u{07}\u{7F}")
        #expect(!out.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) })
        #expect(out == "[31mred [0m 2J")
    }

    @Test func bidiOverridesAndIsolatesAreRemoved() {
        let bidi = "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{200E}\u{200F}\u{061C}"
        #expect(PackLabel.sanitize("ab\u{202E}cd\(bidi)ef") == "abcdef")
    }

    @Test func zeroWidthAndFormatCharactersAreRemoved() {
        #expect(PackLabel.sanitize("a\u{200B}b\u{200C}c\u{2060}d\u{FEFF}e\u{00AD}f") == "abcdef")
    }

    @Test func oversizedInputIsBounded() {
        let out = PackLabel.sanitize(String(repeating: "a", count: 1_000_000))
        #expect(out.count == PackLabel.maxGraphemes + 1)
        #expect(out.hasSuffix("…"))
        let zalgo = "a" + String(repeating: "\u{0301}", count: 100_000)
        #expect(PackLabel.sanitize(zalgo).unicodeScalars.count <= PackLabel.maxScalars + 1)
    }

    @Test func scalarCapTruncationIsMarked() {
        // One huge grapheme: the suffix after the combining marks must not silently vanish.
        let hidden = "a" + String(repeating: "\u{0301}", count: 300) + "pack-B"
        let out = PackLabel.sanitize(hidden)
        #expect(out.hasSuffix("…"))
        #expect(!out.contains("pack-B"))
        // Input exactly at the scalar limit is not marked as truncated.
        let exact = "a" + String(repeating: "\u{0301}", count: PackLabel.maxScalars - 1)
        #expect(!PackLabel.sanitize(exact).hasSuffix("…"))
    }

    @Test func emptyAfterSanitizingUsesFallback() {
        #expect(PackLabel.sanitize("") == PackLabel.fallbackID)
        #expect(PackLabel.sanitize("\u{202E}\u{200B}\n\t ") == PackLabel.fallbackID)
        #expect(PackLabel.sanitize("\u{1B}", fallback: "(x)") == "(x)")
    }

    @Test func pendingSpaceRespectsScalarBoundaryWithCombiningClusters() {
        // Each prefix is one grapheme, so the grapheme cap cannot hide a scalar overflow.
        for prefixCount in [253, 254, 255, 256] {
            let prefix = "a" + String(repeating: "\u{0301}", count: prefixCount - 1)
            let raw = prefix + " bc"
            let expected: String
            switch prefixCount {
            case 253: expected = raw // 256 content scalars, no truncation.
            case 254: expected = prefix + " b…"
            default: expected = prefix + "…" // No room for both the space and b.
            }
            #expect(PackLabel.sanitize(raw) == expected, "prefix=\(prefixCount)")
            #expect(PackLabel.sanitize(raw).unicodeScalars.count <= PackLabel.maxScalars + 1)
        }
        // Exact 255/256/257 total-scalar inputs at a pending-space boundary.
        for total in [255, 256, 257] {
            let prefix = "a" + String(repeating: "\u{0301}", count: total - 3)
            let raw = prefix + " b"
            #expect(PackLabel.sanitize(raw) == (total <= 256 ? raw : prefix + "…"))
        }
    }

    @Test func pendingSpaceKeepsShortSafeLabelsAndFallbackPolicy() {
        for label in ["Mona", "safe pack", "a\u{0301} b", "🐈 companion"] {
            #expect(PackLabel.sanitize(label) == label)
        }
        #expect(PackLabel.sanitize("  a\u{0301}\n\t\u{200B} b  ") == "a\u{0301} b")
        #expect(PackLabel.sanitize("\u{202E}\n", fallback: "(invalid)") == "(invalid)")
        let exact = "a" + String(repeating: "\u{0301}", count: 255)
        #expect(PackLabel.sanitize(exact) == exact)
        #expect(PackLabel.sanitize(exact + "b") == exact + "…")
    }

    @Test func manifestDisplayLeavesStoredIdentityUntouched() throws {
        let json = """
        {"schemaVersion":1,"id":"a\\u202Eb\\ncd","name":"\\u200B","canvas":{"width":256,"height":256},
         "anchor":[128,232],"states":{}}
        """
        let manifest = try JSONDecoder().decode(MascotPackManifest.self, from: Data(json.utf8))
        #expect(manifest.id == "a\u{202E}b\ncd")
        #expect(manifest.displayID == "ab cd")
        #expect(manifest.displayName == "ab cd")
    }

    @Test func errorDescriptionsSanitizeAuthorControlledText() {
        let errors: [MascotPackError] = [
            .unsafePath("../\u{1B}[2J\nfake"), .missingState("idle\u{202E}"), .notPNG("\n"),
        ]
        for error in errors {
            let text = error.description
            #expect(!text.contains("\n") && !text.contains("\u{1B}") && !text.contains("\u{202E}"))
        }
        #expect(MascotPackError.notPNG("\n").description == "not a PNG '(invalid)'")
    }

    @Test func shortPathPassesThroughAndIsCleaned() {
        #expect(PackLabel.sanitizePath("/Users/me/packs/mona-pet-v1") == "/Users/me/packs/mona-pet-v1")
        #expect(PackLabel.sanitizePath("/tmp/a\n\u{1B}[2Jb\u{202E}c") == "/tmp/a [2Jbc")
        #expect(PackLabel.sanitizePath("\u{200B}") == "(unknown path)")
    }

    @Test func fileErrorPathsKeepDistinctTailsWithoutChangingLabelPolicy() {
        func errors(_ path: String) -> [MascotPackError] {
            [.unsafePath(path), .missingFile(path), .notPNG(path), .wrongSize(path, 128, 128),
             .checksumMismatch(path), .tooLarge(path), .undecodable(path), .notRegularFile(path)]
        }
        let prefix = "frames/" + String(repeating: "shared-diagnostic-prefix-", count: 12)
        let alpha = errors(prefix + "missing-alpha.png"), beta = errors(prefix + "missing-beta.png")
        for (a, b) in zip(alpha, beta) {
            #expect(a.description != b.description)
            #expect(a.description.contains("missing-alpha.png") && b.description.contains("missing-beta.png"))
            #expect(a.description.count <= PackLabel.maxPathGraphemes + 50)
        }
        for error in errors(prefix + "\n\u{1B}[2J\u{202E}missing-alpha.png") {
            let text = error.description
            #expect(!text.unicodeScalars.contains { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) })
            #expect(text.contains("missing-alpha.png") && text.count <= PackLabel.maxPathGraphemes + 50)
        }
        #expect(MascotPackError.missingFile("frames/idle.png").description == "file not found 'frames/idle.png'")
        #expect(MascotPackError.notPNG("\n").description == "not a PNG '(invalid)'")
        let state = String(repeating: "s", count: 60)
        #expect(MascotPackError.missingState(state).description == "required state '\(PackLabel.sanitize(state))' missing")
        #expect(PackLabel.sanitize(state).count == PackLabel.maxGraphemes + 1)
    }

    @Test func longPathKeepsTheIdentifyingTail() {
        let tail = "/work/custom-packs/hostile-pack-B"
        let path = "/Users/someone" + String(repeating: "/very-long-directory-name", count: 20) + tail
        let out = PackLabel.sanitizePath(path)
        #expect(out.count <= PackLabel.maxPathGraphemes)
        #expect(out.hasPrefix("/Users/someone"))
        #expect(out.hasSuffix(tail))
        #expect(out.contains("…"))
        // Names and ids keep the short cap.
        #expect(PackLabel.sanitize(path).count == PackLabel.maxGraphemes + 1)
    }

    @Test func longLastComponentKeepsItsEnd() {
        let path = "/p/" + String(repeating: "x", count: 500) + "-END"
        let out = PackLabel.sanitizePath(path)
        #expect(out.count <= PackLabel.maxPathGraphemes)
        #expect(out.hasSuffix("-END"))
    }

    @Test func pathAtTheCapIsUntouchedAndHugePathsAreBounded() {
        let exact = String(repeating: "a", count: PackLabel.maxPathGraphemes)
        #expect(PackLabel.sanitizePath(exact) == exact)
        let huge = PackLabel.sanitizePath("/" + String(repeating: "d/", count: 1_000_000))
        #expect(huge.count <= PackLabel.maxPathGraphemes + 1)
    }
}
