import AppKit
import GitHubPetCore
import SwiftUI

/// README desktop-pet renders (scripts/readme-screenshots.sh): each built-in skin in its idle pose
/// with the real count badge for the first four #87 Demo rows, no service incident, on a
/// transparent canvas like the real borderless mascot panel. Render-only: runs inside
/// `--render-snapshots`, changes no app behaviour, and restores the model afterwards.
/// Files: `readme-mascot-<skin>[-dark].png`.
extension SnapshotRenderer {
    static func readmeMascotRenders(model: AppModel, directory: URL) async -> [String] {
        var report = ["## readme mascots"]
        let saved = model.settings
        model.settings.dataSource = .fixtures
        model.settings.reducedMotion = true
        model.resolveServiceIncidents()
        model.showFixtureItemsForSnapshot(inbox87Items(4))
        model.markAllSeen()
        try? await Task.sleep(nanoseconds: 400_000_000)
        for skin in MascotSkin.allCases {
            model.settings.mascotSkin = skin
            try? await Task.sleep(nanoseconds: 300_000_000)
            let panel = model.layout(model.settings.mascotSize).panelSize
            report.append("readme-mascot \(skin.rawValue): badge=\(model.mascotBadge ?? "none") "
                          + "incident-marker=\(model.incidentMarker?.tier.rawValue ?? "none") "
                          + "pack=\(model.pack?.manifest.displayID ?? "placeholder")")
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                let view = MascotView(model: model, poseOverride: MascotPose(state: .idle, frame: nil, clipElapsed: nil))
                    .frame(width: panel.width, height: panel.height)
                report.append(await renderTransparent(view, name: "readme-mascot-\(skin.rawValue)\(suffix)",
                                                      directory: directory, appearance: appearance))
            }
        }
        model.settings = saved
        return report
    }

    /// Like `render`, without the window-background fill: the mascot panel is transparent on screen.
    private static func renderTransparent<V: View>(_ view: V, name: String, directory: URL,
                                                   appearance: NSAppearance.Name) async -> String {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        hosting.layoutSubtreeIfNeeded()
        hosting.wantsLayer = true
        let scale: CGFloat = 2
        let width = Int(hosting.bounds.width * scale), height = Int(hosting.bounds.height * scale)
        guard let layer = hosting.layer, width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "\(name): not rendered" }
        context.scaleBy(x: scale, y: scale)
        if hosting.isFlipped {
            context.translateBy(x: 0, y: hosting.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return "\(name): not rendered"
        }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
        return "\(name): \(Int(hosting.bounds.width))x\(Int(hosting.bounds.height)) pt"
    }
}
