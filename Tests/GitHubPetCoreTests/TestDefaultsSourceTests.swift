import Foundation
import Testing

/// Deterministic guard (no real preferences are read): tests must use EphemeralDefaults or an
/// in-memory simulation domain, never the real standard defaults, which would write the running
/// user's GitHubPet preferences. Only the files below may mention the standard domain, and only
/// to prove nothing reached it. A new test that needs it must be reviewed and added here.
@Suite struct TestDefaultsSourceTests {
    private static let allowlist: Set<String> = [
        "BaselinePersistenceTests.swift", "EphemeralDefaultsTests.swift", "MascotWindowLifetimeTests.swift",
        "QAScenarioRunnerTests.swift", "ScopeApplicationTests.swift", "SettingsScenarioRunnerTests.swift",
        // This file names the patterns it forbids.
        "TestDefaultsSourceTests.swift",
    ]
    private static let pattern = try! NSRegularExpression(
        pattern: #"UserDefaults\s*\.\s*standard|UserDefaults\s*\(\s*\)|(?:userDefaultsOverride|defaults)\s*[:=]\s*\.standard"#)

    private let tests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func onlyAllowlistedTestFilesMentionTheStandardDefaults() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        var scanned = 0, offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            guard !Self.allowlist.contains(file.lastPathComponent) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if Self.pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(scanned > 20, "the scan found the test sources")
        #expect(offenders.isEmpty, "use EphemeralDefaults, not the standard defaults: \(offenders)")
    }

    @Test func checkDetectsTheForbiddenForms() {
        for sample in ["UserDefaults.standard.set(1, forKey: \"k\")", "options.userDefaultsOverride = .standard",
                       "SettingsStore(defaults: .standard)", "let d = UserDefaults()"] {
            #expect(Self.pattern.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil, "\(sample)")
        }
        for sample in ["EphemeralDefaults(name: \"x\")", "FileHandle.standardError", "spec: .standard"] {
            #expect(Self.pattern.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) == nil, "\(sample)")
        }
    }
}
