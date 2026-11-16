import Foundation
import Testing

/// Static guard (#7): GitHub Pet never reads or stores tokens. No file under Sources reads a token
/// environment variable, asks gh to print a token, or runs a `gh auth` subcommand other than the
/// documented `auth status` preflight (`GhClient.authStatusArguments`). Hint text such as
/// "Run: gh auth login" is a string for the user to read, not an argument array, so it is not matched.
@Suite struct TokenAccessSourceTests {
    static let forbiddenSubstrings = [
        "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
        "show-token", "auth token", "SecItemCopyMatching",
    ]

    /// Violations in one source text: forbidden substrings, `"auth", "token"` argument pairs, and any
    /// `"auth", "<x>"` pair where x is not `status`.
    static func violations(in text: String) -> [String] {
        var found = forbiddenSubstrings.filter { text.contains($0) }
        let pair = try! NSRegularExpression(pattern: #""auth"\s*,\s*"([^"]*)""#)
        let range = NSRange(text.startIndex..., in: text)
        for match in pair.matches(in: text, range: range) {
            if let sub = Range(match.range(at: 1), in: text), text[sub] != "status" {
                found.append("gh auth \(text[sub])")
            }
        }
        return found
    }

    private func sourceFiles() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func noSourceReadsTokensOrRunsAnyAuthCommandButStatus() throws {
        let files = try sourceFiles()
        #expect(files.count > 10, "the scan found the sources")
        var authStatusUses = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(Self.violations(in: text).isEmpty, "\(file.lastPathComponent): \(Self.violations(in: text))")
            if text.contains(#""auth", "status""#) { authStatusUses += 1 }
        }
        #expect(authStatusUses >= 1, "the documented auth status preflight is still what the scan allows")
    }

    @Test func theScannerCatchesWhatItIsMeantTo() {
        #expect(Self.violations(in: #"let a = ["auth", "status", "--active"]"#).isEmpty)
        #expect(Self.violations(in: #"Text("Run: gh auth login")"#).isEmpty)
        #expect(Self.violations(in: #"env["GH_TOKEN"]"#) == ["GH_TOKEN"])
        #expect(Self.violations(in: #"ProcessInfo.processInfo.environment["GITHUB_TOKEN"]"#) == ["GITHUB_TOKEN"])
        #expect(Self.violations(in: #"run(["auth", "token"])"#) == ["gh auth token"])
        #expect(Self.violations(in: #"run(["auth","refresh"])"#) == ["gh auth refresh"])
        #expect(Self.violations(in: #"["auth", "status", "--show-token"]"#) == ["show-token"])
    }
}
