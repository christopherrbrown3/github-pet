import AppKit
import GitHubPetCore
import SwiftUI

@main struct StillsQA {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "dev.github-pet.qa.stills.\(ProcessInfo.processInfo.processIdentifier)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var options = LaunchOptions()
        options.defaultsSuite = suite
        options.snapshotDirectory = out
        options.packDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
        let model = AppModel(options: options)
        model.settings.reducedMotion = true // freeze only this isolated model's art
        let lead = model.serviceIncidents[0]
        for side in [64.0, 128.0, 256.0] {
            model.settings.mascotSize = side
            let layout = model.layout(side)
            for (label, dark, elapsed) in [("critical-static", false, Optional<Double>.none), ("critical-static-dark", true, nil), ("major-fade", false, 0.05)] {
                let marker = IncidentMarker(tier: elapsed == nil ? .critical : .major, count: 1, lead: lead)
                let phase = elapsed.map { marker.phase(now: Date(timeIntervalSince1970: $0), burst: .init(start: Date(timeIntervalSince1970: 0), fromTier: nil), reducedMotion: false, alertsAllowed: true) } ?? .still
                let scene = ZStack(alignment: .topLeading) {
                    IncidentMarkerView(marker: marker, layout: layout, phase: phase)
                    MascotView(model: model, poseOverride: MascotPose(state: .urgent, frame: 0, clipElapsed: nil), badgeOverride: "99+", drawsMarker: false)
                }.frame(width: layout.panelWidth, height: layout.panelSize.height)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: scene)
                host.frame = CGRect(origin: .zero, size: layout.panelSize)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
                window.orderFrontRegardless()
                try await Task.sleep(nanoseconds: 300_000_000)
                host.layoutSubtreeIfNeeded()
                host.wantsLayer = true
                let scale = 2.0
                let context = CGContext(data: nil, width: Int(layout.panelWidth * scale), height: Int(layout.panelSize.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: 0, y: layout.panelSize.height)
                context.scaleBy(x: 1, y: -1)
                host.layer!.render(in: context)
                let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
                let name = "focused-\(Int(side))-\(label).png"
                try png.write(to: out.appendingPathComponent(name))
                print("PASS rendered \(name) bytes=\(png.count)")
                window.orderOut(nil)
            }
        }
    }
}
