import Foundation
import Testing

/// Source checks for explicit accessibility metadata. Native focus and VoiceOver announcements
/// still need a separate QA pass.
@Suite struct AccessibilitySourceTests {
    private let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/GitHubPet")

    @Test func loginToggleExposesTheExistingStatusSummary() throws {
        let source = try String(contentsOf: sources.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        let toggle = try #require(source.range(of: #"Toggle("Open at login""#))
        let caption = try #require(source.range(of: "Text(settings.summary)", range: toggle.upperBound..<source.endIndex))
        #expect(source[toggle.upperBound..<caption.lowerBound].contains(".accessibilityValue(Text(verbatim: settings.summary))"))
    }

    @Test func everySliderHasAnAccessibilityLabel() throws {
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var sliders = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            var rest = Substring(text)
            while let range = rest.range(of: "Slider(") {
                sliders += 1
                // The modifiers that follow the control, up to the next blank line or closing view.
                let tail = rest[range.upperBound...].prefix(600)
                #expect(tail.contains(".accessibilityLabel("), "unlabelled Slider in \(file.lastPathComponent)")
                rest = rest[range.upperBound...]
            }
        }
        #expect(sliders >= 1, "the Size slider exists")
    }
}
