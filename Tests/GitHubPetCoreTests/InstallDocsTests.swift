import Foundation
import Testing

/// Documented commands that users copy (#60): every `gh release list` in the install guide skips
/// draft releases, which a maintainer's account can see but nobody can download.
@Suite struct InstallDocsTests {
    @Test func releaseListCommandsExcludeDrafts() throws {
        let guide = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/install.md")
        let lines = try String(contentsOf: guide, encoding: .utf8).split(separator: "\n").filter { $0.contains("gh release list") }
        #expect(!lines.isEmpty, "the guide documents gh release list")
        for line in lines { #expect(line.contains("--exclude-drafts"), "\(line)") }
    }
}
