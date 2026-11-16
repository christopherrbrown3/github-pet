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
        // Other ways to read a stored token: gh's config value and hosts file, and the Keychain CLI.
        "oauth_token", "hosts.yml", "find-generic-password", "find-internet-password",
    ]
    /// `gh auth` subcommands: after a first element that can't be read statically, they fail closed.
    static let authSubcommands: Set<String> = ["login", "logout", "refresh", "setup-git", "status", "switch", "token"]

    enum Token: Equatable {
        /// A string literal's statically known value: raw delimiters removed, escapes such as `\t`
        /// and `\u{74}` decoded. `escaped` is set when the value can't be read statically (an
        /// interpolation or an invalid escape).
        case string(String, escaped: Bool)
        case comma
        /// `]`: the end of an array literal.
        case close
        case other
        /// Interpolations nested deeper than `maximumInterpolationDepth`: the scan fails closed.
        case unscannable
    }

    static let maximumInterpolationDepth = 16

    /// Lexes Swift well enough for this guard: line and nested block comments are dropped, and
    /// regular, raw (`#"..."#`, any number of `#`) and multiline (`"""`) string literals each become
    /// one token. An interpolation's code is lexed like any other code (its own strings and
    /// comments included) into its own segment; segments follow the top-level tokens, each after
    /// an `.other` separator, so they never change which elements sit next to each other.
    ///
    /// Not a Swift parser. Known limits, all outside what this guard claims: values built at run
    /// time (concatenation such as `"au" + "th"`, variables, constants defined elsewhere), regex
    /// literals containing quotes, `#if` branches (all branches are scanned), and anything run
    /// outside Sources. Interpolation deeper than the bound is reported, never skipped. A first
    /// element that can't be read statically is flagged only before a known `gh auth` subcommand
    /// array element; the status flag check covers the same array literal only.
    static func tokens(in text: String) -> [Token] {
        let b = Array(text.utf8)
        var i = 0, tokens: [Token] = [], segments: [[Token]] = []
        lex(b, &i, depth: 0, untilParen: false, into: &tokens, segments: &segments)
        return segments.reduce(tokens) { $0 + [.other] + $1 }
    }

    private static func has(_ b: [UInt8], _ s: String, at index: Int) -> Bool {
        let u = Array(s.utf8)
        return index + u.count <= b.count && Array(b[index..<index + u.count]) == u
    }

    /// Lexes from `i`. With `untilParen`, stops after the `)` that balances an interpolation's `(`.
    private static func lex(_ b: [UInt8], _ i: inout Int, depth: Int, untilParen: Bool,
                            into tokens: inout [Token], segments: inout [[Token]]) {
        var parens = 0
        while i < b.count {
            let c = b[i]
            if has(b, "//", at: i) {
                while i < b.count, b[i] != 0x0A { i += 1 }
            } else if has(b, "/*", at: i) {
                var nesting = 0
                repeat {
                    if has(b, "/*", at: i) { nesting += 1; i += 2 }
                    else if has(b, "*/", at: i) { nesting -= 1; i += 2 }
                    else { i += 1 }
                } while nesting > 0 && i < b.count
            } else if c == 0x22 || c == 0x23 {
                var hashes = 0, j = i
                while j < b.count, b[j] == 0x23 { hashes += 1; j += 1 }
                guard j < b.count, b[j] == 0x22 else { tokens.append(.other); i += max(hashes, 1); continue }
                i = j
                stringLiteral(b, &i, hashes: hashes, depth: depth, into: &tokens, segments: &segments)
            } else if c == 0x2C {
                tokens.append(.comma); i += 1
            } else if c == 0x5D {
                tokens.append(.close); i += 1
            } else {
                if untilParen {
                    if c == 0x28 { parens += 1 }
                    if c == 0x29 {
                        if parens == 0 { i += 1; return }
                        parens -= 1
                    }
                }
                if !(c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D) { tokens.append(.other) }
                i += 1
            }
        }
    }

    /// `i` is at the opening quote, after `hashes` pound signs.
    private static func stringLiteral(_ b: [UInt8], _ i: inout Int, hashes: Int, depth: Int,
                                      into tokens: inout [Token], segments: inout [[Token]]) {
        let pound = String(repeating: "#", count: hashes)
        let multiline = has(b, "\"\"\"", at: i)
        let close = (multiline ? "\"\"\"" : "\"") + pound
        let escape = "\\" + pound
        var k = i + (multiline ? 3 : 1)
        var content: [UInt8] = [], escaped = false
        while k < b.count, !has(b, close, at: k) {
            guard has(b, escape, at: k) else { content.append(b[k]); k += 1; continue }
            k += escape.utf8.count
            guard k < b.count else { break }
            switch b[k] {
            case 0x28: // \( interpolation: lex its code, bounded by depth.
                escaped = true
                k += 1
                guard depth < maximumInterpolationDepth else { tokens.append(.unscannable); i = b.count; return }
                var code: [Token] = []
                lex(b, &k, depth: depth + 1, untilParen: true, into: &code, segments: &segments)
                segments.append(code)
            case 0x30: content.append(0); k += 1
            case 0x5C, 0x22, 0x27: content.append(b[k]); k += 1
            case 0x74: content.append(0x09); k += 1
            case 0x6E: content.append(0x0A); k += 1
            case 0x72: content.append(0x0D); k += 1
            case 0x0A where multiline: k += 1 // line continuation
            case 0x75: // \u{1-8 hex digits}
                var end = k + 1, hex: [UInt8] = []
                if end < b.count, b[end] == 0x7B {
                    end += 1
                    while end < b.count, hex.count <= 8, b[end] != 0x7D { hex.append(b[end]); end += 1 }
                }
                if end < b.count, b[end] == 0x7D, (1...8).contains(hex.count),
                   let value = UInt32(String(decoding: hex, as: UTF8.self), radix: 16), let scalar = Unicode.Scalar(value) {
                    content += Array(String(Character(scalar)).utf8); k = end + 1
                } else { escaped = true; k += 1 }
            default: escaped = true; k += 1
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
    }

    /// Violations in one source text: forbidden substrings (in the text or a decoded literal); every
    /// `"auth"` element followed by a comma and anything but the literal `"status"` (another subcommand,
    /// an escaped or interpolated literal, or a non-literal); a status array that asks for the token
    /// or holds a non-static element; and a non-static first element before a `gh auth` subcommand.
    /// Comments and string-literal style between elements make no difference.
    static func violations(in text: String) -> [String] {
        let tokens = tokens(in: text)
        let literals = tokens.compactMap { token -> String? in if case .string(let value, _) = token { return value }; return nil }
        var found = forbiddenSubstrings.filter { name in text.contains(name) || literals.contains { $0.contains(name) } }
        if tokens.contains(.unscannable) { found.append("unscannable interpolation nesting") }
        for index in tokens.indices {
            guard index + 2 < tokens.count, tokens[index + 1] == .comma,
                  case .string(let first, let firstEscaped) = tokens[index] else { continue }
            if firstEscaped {
                // Could be "auth" at run time (QA LOW-3): fail closed before a gh auth subcommand
                // that is an array element (followed by `,` or `]`, not a dictionary key's `:`).
                let next = index + 3 < tokens.count ? tokens[index + 3] : .close
                if case .string(let sub, escaped: false) = tokens[index + 2], authSubcommands.contains(sub),
                   next == .comma || next == .close {
                    found.append("gh <escaped literal> \(sub)")
                }
                continue
            }
            guard first == "auth" else { continue }
            switch tokens[index + 2] {
            case .string("status", escaped: false): found += statusFlagViolations(tokens, after: index + 2)
            case .string(let sub, escaped: false): found.append("gh auth \(sub)")
            case .string: found.append("gh auth <escaped literal>")
            default: found.append("gh auth <non-literal>")
            }
        }
        return found
    }

    /// The rest of a `"auth", "status"` array (QA MED-1): every element must be a static literal and
    /// none may ask for the token (`--show-token`, or `-t` alone or in a short-flag group).
    static func statusFlagViolations(_ tokens: [Token], after status: Int) -> [String] {
        var found: [String] = [], index = status + 1
        while index + 1 < tokens.count, tokens[index] == .comma {
            switch tokens[index + 1] {
            case .close: return found
            case .string(let flag, escaped: false):
                let short = flag.hasPrefix("-") && !flag.hasPrefix("--") && flag.contains("t")
                if short || flag.hasPrefix("--show-token") { found.append("gh auth status \(flag)") }
            case .string: found.append("gh auth status <escaped literal>")
            default: found.append("gh auth status <non-literal>"); return found
            }
            index += 2
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
        #expect(Self.violations(in: #"["auth", "status", "--show-token"]"#) == ["show-token", "gh auth status --show-token"])
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
        #expect(Self.violations(in: #"run(["auth", "tok\q"])"#) == ["gh auth <escaped literal>"])
        #expect(Self.violations(in: #"run(["auth", "\(sub)"])"#) == ["gh auth <escaped literal>"])
        #expect(Self.violations(in: #"run(["auth", sub])"#) == ["gh auth <non-literal>"])
    }

    @Test func executableCodeInsideInterpolationIsScanned() {
        // The Copilot examples on PR #56: inner quotes and a nested "/*" no longer end the scan.
        #expect(Self.violations(in: #"let result = "\(run(["auth", "login"]))""#) == ["gh auth login"])
        #expect(Self.violations(in: #"let s = "\(f("/*"))"; run(["auth", "token"])"#) == ["gh auth token"])
        // Comments, nested strings and deeper interpolation inside an interpolation.
        #expect(Self.violations(in: #"let s = "\(f(/* " */ 1))"; run(["auth", "token"])"#) == ["gh auth token"])
        #expect(Self.violations(in: #"let s = "a \(g("b \(run(["auth", /* x */ "refresh"])) c")) d""#) == ["gh auth refresh"])
        #expect(Self.violations(in: #"let s = "\(f(")"))"; run(["auth", "logout"])"#) == ["gh auth logout"])
        // Raw and multiline literals interpolate only with their own delimiter.
        #expect(Self.violations(in: ##"let s = #"\#(run(["auth", "logout"]))"#"##) == ["gh auth logout"])
        #expect(Self.violations(in: ##"let s = #"\(run(["auth", "logout"]))"#"##).isEmpty, "raw text, not code")
        let multiline = "let s = \"\"\"\n  \\(run([\"auth\", \"token\"]))\n  \"\"\""
        #expect(Self.violations(in: multiline) == ["gh auth token"])
        // Allowed: interpolated hint text and the status preflight inside an interpolation.
        #expect(Self.violations(in: #"Text("Run: gh auth login as \(name)")"#).isEmpty)
        #expect(Self.violations(in: #"let s = "Run: \("gh auth login")""#).isEmpty)
        #expect(Self.violations(in: #"let s = "\(run(["auth", "status"]))""#).isEmpty)
        // Bounded: nesting deeper than the scanner follows fails closed instead of passing.
        let deep = String(repeating: #""\("#, count: 40) + "1" + String(repeating: #")""#, count: 40)
        #expect(Self.violations(in: deep) == ["unscannable interpolation nesting"])
    }

    @Test func staticallyDecodableEscapesAreDecodedBeforeMatching() {
        // The Copilot example on PR #56.
        #expect(Self.violations(in: #"run(["au\u{74}h", "token"])"#) == ["gh auth token"])
        #expect(Self.violations(in: #"run(["\u{61}uth", "lo\u{67}in"])"#) == ["gh auth login"])
        #expect(Self.violations(in: #"run(["auth", "tok\u{65}n"])"#) == ["gh auth token"])
        #expect(Self.violations(in: ##"run([#"au\#u{74}h"#, "token"])"##) == ["gh auth token"])
        #expect(Self.violations(in: #"env["GH_\u{54}OKEN"]"#) == ["GH_TOKEN"])
        // Still allowed when the decoded value is the status preflight; an undecodable or
        // interpolated subcommand is still a violation.
        #expect(Self.violations(in: #"let a = ["\u{61}uth", "st\u{61}tus"]"#).isEmpty)
        #expect(Self.violations(in: #"run(["au\u{74}h", "\(sub)"])"#) == ["gh auth <escaped literal>"])
        #expect(Self.violations(in: #"run(["auth", "\u{110000}"])"#) == ["gh auth <escaped literal>"])
    }

    @Test func theStatusPreflightCannotAskForTheToken() {
        // QA MED-1 on PR #56: -t is gh's short --show-token; pflag also accepts it in a group.
        #expect(Self.violations(in: #"run(["auth", "status", "-t"])"#) == ["gh auth status -t"])
        #expect(Self.violations(in: #"run(["auth", "status", "--active", "-at"])"#) == ["gh auth status -at"])
        #expect(Self.violations(in: #"run(["auth", "status", /* x */ "-\u{74}"])"#) == ["gh auth status -t"])
        #expect(Self.violations(in: #"run(["auth", "status", "--show-token=true"])"#) == ["show-token", "gh auth status --show-token=true"])
        #expect(Self.violations(in: #"run(["auth", "status", "\(flag)"])"#) == ["gh auth status <escaped literal>"])
        #expect(Self.violations(in: #"run(["auth", "status", flag])"#) == ["gh auth status <non-literal>"])
        // Allowed: the documented preflight, with or without a trailing comma.
        #expect(Self.violations(in: #"let a = ["auth", "status", "--active", "--hostname", "github.com"]"#).isEmpty)
        #expect(Self.violations(in: "let a = [\"auth\", \"status\",\n]").isEmpty)
    }

    @Test func otherWaysToReadAStoredTokenAreForbidden() {
        // QA LOW-2 on PR #56.
        #expect(Self.violations(in: #"run(["config", "get", "oauth_token"])"#) == ["oauth_token"])
        #expect(Self.violations(in: #"run(["find-generic-password", "-s", "gh:github.com"])"#) == ["find-generic-password"])
        #expect(Self.violations(in: #"run(["find-internet-password", "-s", "github.com"])"#) == ["find-internet-password"])
        #expect(Self.violations(in: #"read(home + "/.config/gh/hosts.yml")"#) == ["hosts.yml"])
        #expect(Self.violations(in: #"read("hosts\u{2E}yml")"#) == ["hosts.yml"])
    }

    @Test func anAuthPositionThatCannotBeReadStaticallyFailsClosed() {
        // QA LOW-3 on PR #56: an interpolated or invalid-escape first element before a gh auth
        // subcommand could be "auth" at run time.
        #expect(Self.violations(in: #"run(["\("auth")", "token"])"#) == ["gh <escaped literal> token"])
        #expect(Self.violations(in: #"run(["au\qth", "login"])"#) == ["gh <escaped literal> login"])
        // Not a gh auth subcommand after it: ordinary interpolated text stays allowed.
        #expect(Self.violations(in: #"let a = ["\(name)", "Assigned"]"#).isEmpty)
        #expect(Self.violations(in: #"let d = ["id": "O_\(index)", "login": owner]"#).isEmpty, "a dictionary key, not an argument")
        #expect(Self.violations(in: #"run(["\(verb)", "login", "--web"])"#) == ["gh <escaped literal> login"])
    }

    @Test func commentedOutOrQuotedTextIsNotMistakenForCode() {
        #expect(Self.violations(in: #"// run(["auth", "token"]) is never done"#).isEmpty)
        #expect(Self.violations(in: #"/* ["auth", "login"] */ let a = ["auth", "status"]"#).isEmpty)
        #expect(Self.violations(in: ##"let a = [#"auth"#, #"status"#]"##).isEmpty)
        #expect(Self.violations(in: "let s = \"a \\\"auth\\\", \\\"token\\\" quote\"").isEmpty)
        #expect(Self.violations(in: #"Text("Run: gh auth login")"#).isEmpty)
    }
}
