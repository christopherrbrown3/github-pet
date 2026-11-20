import Foundation

/// Semantic Versioning 2.0.0 precedence for release tags such as `v0.1.0-beta.3`.
/// Build metadata (`+45`) never affects precedence; `buildNumber` is kept only as a tie-breaker.
public struct SemanticVersion: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Identifier: Equatable, Hashable, Sendable {
        case numeric(Int)
        case text(String)
    }

    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [Identifier]
    /// The numeric `+N` build metadata, when present.
    public let buildNumber: Int?

    public init(major: Int, minor: Int, patch: Int, prerelease: [Identifier] = [], buildNumber: Int? = nil) {
        self.major = major; self.minor = minor; self.patch = patch
        self.prerelease = prerelease; self.buildNumber = buildNumber
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if isPrerelease {
            text += "-" + prerelease.map { identifier -> String in
                switch identifier {
                case .numeric(let number): return String(number)
                case .text(let string): return string
                }
            }.joined(separator: ".")
        }
        if let buildNumber { text += "+\(buildNumber)" }
        return text
    }

    /// Strict parse of `MAJOR.MINOR.PATCH[-pre][+build]` with an optional leading `v`.
    /// Rejects leading zeros, empty identifiers, odd characters and absurd lengths.
    public init?(_ string: String) {
        var text = Substring(string)
        guard text.utf8.count <= 64 else { return nil }
        if text.first == "v" { text = text.dropFirst() }
        var build: Substring?
        if let plus = text.firstIndex(of: "+") {
            build = text[text.index(after: plus)...]
            text = text[..<plus]
        }
        var pre: Substring?
        if let dash = text.firstIndex(of: "-") {
            pre = text[text.index(after: dash)...]
            text = text[..<dash]
        }
        let core = text.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.number(core[0]), let minor = Self.number(core[1]), let patch = Self.number(core[2])
        else { return nil }
        var identifiers: [Identifier] = []
        if let pre {
            for part in pre.split(separator: ".", omittingEmptySubsequences: false) {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
                else { return nil }
                if part.allSatisfy(\.isNumber) {
                    guard let number = Self.number(part) else { return nil }
                    identifiers.append(.numeric(number))
                } else {
                    identifiers.append(.text(String(part)))
                }
            }
        }
        var buildNumber: Int?
        if let build {
            let parts = build.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
            else { return nil }
            if parts.count == 1, parts[0].allSatisfy(\.isNumber) { buildNumber = Int(parts[0]) }
        }
        self.init(major: major, minor: minor, patch: patch, prerelease: identifiers, buildNumber: buildNumber)
    }

    private static func number<S: StringProtocol>(_ part: S) -> Int? {
        guard !part.isEmpty, part.utf8.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
              part == "0" || part.first != "0" else { return nil }
        return Int(part)
    }

    /// Precedence per SemVer §11. Equal precedence returns false both ways.
    public static func precedes(_ lhs: SemanticVersion, _ rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (false, true): return true      // 1.0.0-beta < 1.0.0
        case (true, false): return false
        case (false, false):
            for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
                switch (a, b) {
                case (.numeric(let x), .numeric(let y)): return x < y
                case (.numeric, .text): return true
                case (.text, .numeric): return false
                case (.text(let x), .text(let y)): return x < y
                }
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }

    /// Precedence, then (only when precedence is equal) the numeric build number if both have one.
    public static func isOrdered(_ lhs: SemanticVersion, before rhs: SemanticVersion) -> Bool {
        if precedes(lhs, rhs) { return true }
        if precedes(rhs, lhs) { return false }
        if let a = lhs.buildNumber, let b = rhs.buildNumber { return a < b }
        return false
    }
}
