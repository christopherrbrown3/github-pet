import AppKit
import GitHubPetCore
import SwiftUI

/// README renders (scripts/readme-screenshots.sh) on the first four #87 Demo rows, up to date, no
/// service incident. Render-only: runs inside `--render-snapshots`, changes no app behaviour, and
/// restores the model afterwards.
/// - `readme-mascot-<skin>[-dark].png`: each built-in skin idle with the real count badge, on a
///   transparent canvas like the real borderless mascot panel.
/// - `readme-settings-<pane>[-dark].png`: the Mascot and GitHub panes' content (the tab strip
///   doesn't draw offscreen) with new-install defaults, Mona selected, and Open at login in the
///   state ad-hoc-signed builds read (`.notFound`, #112) through an inert backend that never
///   registers. Heights end between sections, as a window that size shows them before scrolling:
///   the whole Mascot pane, and the GitHub pane through Monitoring scope (its Software updates
///   section reads "not configured" here because snapshot mode never starts the updater).
extension SnapshotRenderer {
    static let readmeMascotPaneHeight: CGFloat = 815
    static let readmeGitHubPaneHeight: CGFloat = 695

    static func readmeBeta4Renders(model: AppModel, directory: URL) async -> [String] {
        var report = ["## readme beta 4"]
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
        model.settings.mascotSkin = saved.mascotSkin
        model.settings.reducedMotion = PetSettings().reducedMotion
        let startup = LoginItemSettings(backend: AdHocLoginItemBackend())
        startup.refresh()
        try? await Task.sleep(nanoseconds: 400_000_000)
        report.append("readme-settings: badge=\(model.mascotBadge ?? "none") state=\(model.dataState.statusText) "
                      + "skin=\(model.settings.mascotSkin.rawValue) login-item=\(startup.status.map { "\($0)" } ?? "nil") offers-settings=\(startup.offersSystemSettings)")
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            report += await render(MascotPane(model: model, loginItem: startup).frame(width: 520, height: Self.readmeMascotPaneHeight),
                                   name: "readme-settings-mascot\(suffix)", directory: directory, appearance: appearance)
                .prefix(1)
            report += await render(GitHubPane(model: model).frame(width: 520, height: Self.readmeGitHubPaneHeight),
                                   name: "readme-settings-github\(suffix)", directory: directory, appearance: appearance)
                .prefix(1)
        }
        model.settings = saved
        return report
    }

    /// What `SMAppService.mainApp` reads on ad-hoc-signed builds (#112); never registers.
    private struct AdHocLoginItemBackend: LoginItemBackend {
        var status: LoginItemStatus { .notFound }
        func register() throws { throw CocoaError(.featureUnsupported) }
        func unregister() throws { throw CocoaError(.featureUnsupported) }
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
