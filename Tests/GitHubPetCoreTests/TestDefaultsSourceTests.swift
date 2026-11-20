import Foundation
import Testing

/// Deterministic guard (no real preferences are read): tests must use EphemeralDefaults or an
/// in-memory simulation domain, never a real preferences domain, which would write the running
/// user's GitHubPet preferences (and flake whenever the real app is running). No test file may
/// construct or reach one; the allowlist is empty except the standalone client below and this file.
@Suite struct TestDefaultsSourceTests {
    /// Paths relative to Tests/. The external client opens only a disposable suite named on its
    /// command line; this file spells out the forbidden patterns.
    private static let allowlist: Set<String> = [
        "ExternalDismissalStoreClient/main.swift", "GitHubPetCoreTests/TestDefaultsSourceTests.swift",
    ]
    private static let patterns: [String] = [
        #"UserDefaults\s*\.\s*standard"#,                                   // the real domain
        #"UserDefaults\s*\(\s*\)"#,                                          // same as standard
        #"UserDefaults\s*\.\s*init"#,
        #"UserDefaults\s*\(\s*suiteName"#,                                   // any real suite, e.g. the app's own
        #"(?:userDefaultsOverride|defaults)\s*[:=]\s*\.standard"#,           // handing it to the app
        #"dev\.github-pet\.GitHubPet\b"#,                                    // the app's real bundle domain
        #"\bCFPreferences\w*"#, #"\bNSUserDefaults\b"#, #"\bNSUserDefaultsController\b"#, #"@AppStorage"#,
    ]
    private static let forbidden: [NSRegularExpression] = patterns.map { try! NSRegularExpression(pattern: $0) }

    private let tests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func matches(_ text: String) -> Bool {
        forbidden.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    }

    @Test func noTestFileReachesARealPreferencesDomain() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        var scanned = 0, offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let relative = String(file.path.dropFirst(tests.path.count + 1))
            guard !Self.allowlist.contains(relative) else { continue }
            if Self.matches(try String(contentsOf: file, encoding: .utf8)) { offenders.append(relative) }
        }
        #expect(scanned > 20, "the scan found the test sources")
        #expect(offenders.isEmpty, "use EphemeralDefaults, not a real preferences domain: \(offenders)")
    }

    @Test func checkDetectsTheForbiddenForms() {
        for sample in ["UserDefaults.standard.set(1, forKey: \"k\")", "options.userDefaultsOverride = .standard",
                       "SettingsStore(defaults: .standard)", "let d = UserDefaults()", "UserDefaults.init(suiteName: x)",
                       "UserDefaults(suiteName: \"dev.github-pet.GitHubPet\")", "UserDefaults(suiteName: suite)",
                       "UserDefaults (suiteName : \"other\")", "CFPreferencesCopyAppValue(k, d)", "NSUserDefaults.standard",
                       "let name = \"dev.github-pet.GitHubPet\"", "@AppStorage(\"x\") var x"] {
            #expect(Self.matches(sample), "\(sample)")
        }
        for sample in ["EphemeralDefaults(name: \"x\")", "FileHandle.standardError", "spec: .standard",
                       "\"dev.github-pet.tests.mascot-window.\\(UUID())\"", "preferencesFileExists(domain)"] {
            #expect(!Self.matches(sample), "\(sample)")
        }
    }
}
