import Foundation
import Testing

/// Static guard (the app target has no test target, and SwiftUI builds its accessibility tree
/// only for a live assistive client): every Slider in the app's views carries an explicit
/// accessibility label. Live VoiceOver behaviour still needs QA.
@Suite struct AccessibilitySourceTests {
    @Test func everySliderHasAnAccessibilityLabel() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GitHubPet")
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
