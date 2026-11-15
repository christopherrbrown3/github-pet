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
}
