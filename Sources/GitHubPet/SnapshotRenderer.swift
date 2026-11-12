import AppKit
import GitHubPetCore
import SwiftUI

/// QA/dev hook: `--render-snapshots <dir>` drives a fixture scenario, renders the real Inbox
/// window, hover summary and mascot offscreen with AppKit, dumps each window's accessibility
/// tree, then quits. Needs no screen-recording or accessibility permission.
@MainActor
enum SnapshotRenderer {
    static func run(model: AppModel, directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [String] = []

        func capture(_ name: String) async {
            // Let polls, ticks and SwiftUI updates settle.
            try? await Task.sleep(nanoseconds: 400_000_000)
            report.append("## \(name)")
            report.append("state=\(model.dataState.statusText) badge=\(model.badge ?? "none") rows=\(model.items.count) "
                          + "demo=\(model.isDemo) mood=\(model.mascotState.rawValue)")
            report.append("menu-bar AX: \(model.statusAccessibilityLabel)")
            report += await render(InboxView(model: model, showsWindowButton: false), name: "\(name)-inbox",
                                   directory: directory, asWindow: true)
            report += await render(HoverSummaryView(model: model), name: "\(name)-hover", directory: directory)
            report += await render(MascotView(model: model)
                                    .frame(width: model.settings.mascotSize, height: model.settings.mascotSize),
                                   name: "\(name)-mascot", directory: directory)
            report.append("")
        }

        await capture("01-baseline")
        model.injectEntitlementEvent()
        await capture("02-injected")
        model.replaySnapshot()
        await capture("03-replayed")
        model.setPartialPolls(true)
        await capture("04-partial")
        model.setPartialPolls(false)
        model.markStale()
        await capture("05-stale")
        model.simulateDisconnect()
        await capture("06-disconnected")
        model.simulateReconnect()
        await capture("07-reconnected")
        model.settings.privacyMode = true
        await capture("08-privacy")

        let text = report.joined(separator: "\n") + "\n"
        try? text.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("GitHubPet: snapshots written to \(directory.path)\n".utf8))
    }

    /// Renders `view` the way the app shows it. With `asWindow`, it goes through the same
    /// NSHostingController window sizing as the real Inbox window.
    private static func render<V: View>(_ view: V, name: String, directory: URL, asWindow: Bool = false) async -> [String] {
        let window: NSWindow
        if asWindow {
            window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .resizable]
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
        }
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 300_000_000)

        guard let content = window.contentView else { return ["\(name): no content view"] }
        content.layoutSubtreeIfNeeded()
        var lines = ["\(name): \(Int(content.bounds.width))x\(Int(content.bounds.height)) pt"]
        if let png = renderPNG(content) {
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        lines += accessibilityDump(content, depth: 1)
        window.orderOut(nil)
        return lines
    }

    /// SwiftUI draws into layers, so render the layer tree (cacheDisplay misses most of it).
    private static func renderPNG(_ view: NSView) -> Data? {
        view.wantsLayer = true
        guard let layer = view.layer else { return nil }
        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func accessibilityDump(_ element: Any, depth: Int) -> [String] {
        guard depth < 14, let node = element as? NSAccessibilityProtocol else { return [] }
        var lines: [String] = []
        let role = node.accessibilityRole()?.rawValue ?? "?"
        let label = node.accessibilityLabel() ?? ""
        let value = (node.accessibilityValue() as? String) ?? ""
        if !label.isEmpty || !value.isEmpty || role.contains("List") || role.contains("Row") || role.contains("Button") {
            lines.append(String(repeating: "  ", count: depth) + "\(role) \"\(label)\"" + (value.isEmpty ? "" : " = \"\(value)\""))
        }
        for child in node.accessibilityChildren() ?? [] {
            lines += accessibilityDump(child, depth: depth + 1)
        }
        return lines
    }
}
