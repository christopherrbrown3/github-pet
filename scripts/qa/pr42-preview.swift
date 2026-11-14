import AppKit
import SwiftUI
@testable import GitHubPet
import GitHubPetCore

@main struct PreviewQA {
    @MainActor static func main() {
        _ = NSApplication.shared
        let suite = "dev.github-pet.qa.preview.\(ProcessInfo.processInfo.processIdentifier)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var options = LaunchOptions()
        options.defaultsSuite = suite
        options.snapshotDirectory = URL(fileURLWithPath: "/tmp/qa42-preview-no-render")
        options.packDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = AppModel(options: options)
        model.settings.mascotVisible = false
        model.settings.reducedMotion = true
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        var failures = 0
        for critical in [false, true] {
            if critical { model.injectServiceIncident(.critical) }
            for side in [64.0, 128.0] {
                model.settings.mascotSize = side
                let layout = model.layout(side)
                for rightEdge in [false, true] {
                    let frame = CGRect(origin: CGPoint(x: rightEdge ? screen.maxX - layout.panelWidth : 300, y: 250), size: layout.panelSize)
                    let (popover, placement) = MascotWindowController.prepareHover(model: model, panelFrame: frame, screen: screen)
                    let lines = model.hoverLines(compact: side < 80)
                    let expectedTier: IncidentMarker.Tier = critical ? .critical : .minor
                    let pass = placement.meetsTarget && placement.arrowGap.isFinite
                        && placement.arrowGap <= 12 && placement.laneClear
                        && (!rightEdge || placement.side == .left)
                        && model.incidentMarker?.tier == expectedTier
                        && lines.first?.contains("GitHub incident") == true
                        && (side >= 80 || lines.count == 2)
                        && model.badge == "3" && model.statusAccessibilityLabel.contains("active GitHub incident")
                    print("\(pass ? "PASS" : "FAIL") tier=\(expectedTier) size=\(Int(side)) edge=\(rightEdge) arrow=\(placement.arrowGap) clear=\(placement.laneClear) side=\(placement.side) measured=\(popover.contentSize) lines=\(lines.count)")
                    if !pass { failures += 1 }
                }
            }
        }
        print("RESULT cases=8 failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
