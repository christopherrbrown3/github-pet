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

    enum Token: Equatable {
        /// A string literal's content (raw delimiters removed). `escaped` is set when a non-raw literal
        /// holds a backslash escape or interpolation, so its value can't be read statically.
        case string(String, escaped: Bool)
        case comma
        case other
    }

    /// Lexes Swift well enough for this guard: line and nested block comments are dropped, and
    /// regular, raw (`#"..."#`, any number of `#`) and multiline (`"""`) string literals each become one token.
    static func tokens(in text: String) -> [Token] {
        let b = Array(text.utf8)
        var tokens: [Token] = []
        var i = 0
        func has(_ s: String, at index: Int) -> Bool {
            let u = Array(s.utf8)
            return index + u.count <= b.count && Array(b[index..<index + u.count]) == u
        }
        while i < b.count {
            let c = b[i]
            if has("//", at: i) {
                while i < b.count, b[i] != 0x0A { i += 1 }
            } else if has("/*", at: i) {
                var depth = 0
                repeat {
                    if has("/*", at: i) { depth += 1; i += 2 }
                    else if has("*/", at: i) { depth -= 1; i += 2 }
                    else { i += 1 }
                } while depth > 0 && i < b.count
            } else if c == 0x22 || c == 0x23 {
                var hashes = 0
                var j = i
                while j < b.count, b[j] == 0x23 { hashes += 1; j += 1 }
                guard j < b.count, b[j] == 0x22 else { tokens.append(.other); i += max(hashes, 1); continue }
                let pound = String(repeating: "#", count: hashes)
                let multiline = has("\"\"\"", at: j)
                let open = multiline ? 3 : 1
                let close = (multiline ? "\"\"\"" : "\"") + pound
                let escape = "\\" + pound
                var k = j + open
                var content: [UInt8] = []
                var escaped = false
                while k < b.count, !has(close, at: k) {
                    if has(escape, at: k) {
                        escaped = true
                        k += escape.utf8.count
                        if k < b.count { k += 1 }  // the escaped character, so \" never closes the literal
                    } else {
                        content.append(b[k]); k += 1
                    }
                }
                var value = String(decoding: content, as: UTF8.self)
                if multiline {
                    // Content sits between the line breaks after the opening and before the closing
                    // delimiter; the closing delimiter's indentation is not part of it.
                    var lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    if lines.count >= 2 { lines.removeFirst(); lines.removeLast() }
                    value = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                }
                tokens.append(.string(value, escaped: escaped))
                i = min(k + close.utf8.count, b.count)
            } else if c == 0x2C {
                tokens.append(.comma); i += 1
            } else {
                if !(c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D) { tokens.append(.other) }
                i += 1
            }
        }
        return tokens
    }

    /// Violations in one source text: forbidden substrings, and every `"auth"` element followed by a
    /// comma and anything but the literal `"status"` (another subcommand, an escaped or interpolated
    /// literal, or a non-literal), whatever comments or string-literal style sit in between.
    static func violations(in text: String) -> [String] {
        var found = forbiddenSubstrings.filter { text.contains($0) }
        let tokens = tokens(in: text)
        for index in tokens.indices where tokens[index] == .string("auth", escaped: false) {
            guard index + 2 < tokens.count, tokens[index + 1] == .comma else { continue }
            switch tokens[index + 2] {
            case .string("status", escaped: false): break
            case .string(let sub, escaped: false): found.append("gh auth \(sub)")
            case .string: found.append("gh auth <escaped literal>")
            default: found.append("gh auth <non-literal>")
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

    @Test func commentsAndRawOrMultilineLiteralsCannotHideAuthCommands() {
        // The Copilot examples on PR #56.
        #expect(Self.violations(in: #"run(["auth", /* preflight */ "token"])"#) == ["gh auth token"])
        #expect(Self.violations(in: ##"run([#"auth"#, #"login"#])"##) == ["gh auth login"])
        // Line comments, nested block comments, and comments between every element.
        #expect(Self.violations(in: "run([\"auth\", // why\n \"token\"])") == ["gh auth token"])
        #expect(Self.violations(in: #"run(["auth" /* a */ , /* /* nested */ b */ "refresh"])"#) == ["gh auth refresh"])
        // Multiline and multi-hash raw literals.
        let multiline = "run([\"\"\"\n  auth\n  \"\"\", \"\"\"\n  token\n  \"\"\"])"
        #expect(Self.violations(in: multiline) == ["gh auth token"])
        #expect(Self.violations(in: ###"run([##"auth"##, ##"logout"##])"###) == ["gh auth logout"])
        // Not literals: an escape, an interpolation or a variable could build any subcommand.
        #expect(Self.violations(in: #"run(["auth", "tok\u{65}n"])"#) == ["gh auth <escaped literal>"])
        #expect(Self.violations(in: #"run(["auth", "\(sub)"])"#) == ["gh auth <escaped literal>"])
        #expect(Self.violations(in: #"run(["auth", sub])"#) == ["gh auth <non-literal>"])
    }

    @Test func commentedOutOrQuotedTextIsNotMistakenForCode() {
        #expect(Self.violations(in: #"// run(["auth", "token"]) is never done"#).isEmpty)
        #expect(Self.violations(in: #"/* ["auth", "login"] */ let a = ["auth", "status"]"#).isEmpty)
        #expect(Self.violations(in: ##"let a = [#"auth"#, #"status"#]"##).isEmpty)
        #expect(Self.violations(in: "let s = \"a \\\"auth\\\", \\\"token\\\" quote\"").isEmpty)
        #expect(Self.violations(in: #"Text("Run: gh auth login")"#).isEmpty)
    }
}
