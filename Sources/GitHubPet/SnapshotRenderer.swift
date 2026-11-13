import AppKit
import GitHubPetCore
import SwiftUI

/// QA/dev hook: `--render-snapshots <dir>` drives a fixture scenario, renders the real Inbox
/// window, hover summary and mascot offscreen with AppKit, dumps each window's accessibility
/// tree, then quits. Each surface is rendered in light (`<name>.png`) and dark (`<name>-dark.png`)
/// appearance. Needs no screen-recording or accessibility permission. Stills only: they say
/// nothing about interaction or animation.
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
            report.append("source=\(model.settings.dataSource.rawValue) privacy=\(model.settings.privacyMode) "
                          + "details=\(model.detailsRevealed) inbox-privacy=\(model.inboxPrivacy)")
            report.append("menu-bar AX: \(model.statusAccessibilityLabel)")
            report.append(mascotAccessibility(model))
            if name == "00-loading" { report.append(mascotPointer()) }
            let panel = MascotView.panelSize(side: model.settings.mascotSize)
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                report += await render(MascotView(model: model).frame(width: panel.width, height: panel.height),
                                       name: "\(name)-mascot\(suffix)", directory: directory, appearance: appearance)
                report += await render(HoverSummaryView(model: model), name: "\(name)-hover\(suffix)",
                                       directory: directory, appearance: appearance)
            }
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                report += await render(InboxView(model: model, showsWindowButton: false, marksSeenOnClose: false),
                                       name: "\(name)-inbox\(suffix)", directory: directory,
                                       appearance: appearance, asWindow: true)
            }
            report.append("")
        }

        // Default settings: privacy on, details hidden.
        model.showLoadingForSnapshot()
        await capture("00-loading")
        model.refresh()
        await capture("01-baseline")
        // As if the user pressed "Show details": rows show titles, hover stays generic.
        model.detailsRevealed = true
        await capture("01b-details")
        model.injectEntitlementEvent()
        await capture("02-injected")
        model.replaySnapshot()
        await capture("03-replayed")
        model.markAllSeen()   // as when the user opens the inbox
        model.setPartialPolls(true)
        await capture("04-partial")
        model.setPartialPolls(false)
        model.markStale()
        await capture("05-stale")
        model.simulateDisconnect()
        await capture("06-disconnected")
        model.simulateReconnect()
        await capture("07-reconnected")
        model.detailsRevealed = false
        await capture("08-privacy")
        model.detailsRevealed = true
        // Attention needs an unseen event while alerts are allowed; with reduced motion the
        // mascot holds the attention state's static fallback pose (no clip plays).
        model.settings.reducedMotion = true
        model.injectEntitlementEvent()
        await capture("09-attention-static")
        model.markAllSeen()
        model.injectWorkflowFailure()
        await capture("10-urgent-static")
        // Only with an explicit gh path that does not exist (e.g. /nonexistent/gh): the result
        // is deterministic and can never contain live GitHub data.
        if let path = ProcessInfo.processInfo.environment[GhLocator.overrideVariable],
           !FileManager.default.fileExists(atPath: path) {
            model.settings.dataSource = .githubCLI
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await capture("11-gh-override")
        }

        report.append("## hover placement")
        for side in [CGFloat(64), 128, 256] { report.append(await hoverGap(model: model, side: side)) }

        // Settings goes through the same window sizing as the real Settings window.
        report.append("## settings")
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            report += await render(SettingsView(model: model), name: "settings\(suffix)", directory: directory,
                                   appearance: appearance, asWindow: true)
        }

        let text = report.joined(separator: "\n") + "\n"
        try? text.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        UserDefaults.standard.removePersistentDomain(forName: LaunchOptions.snapshotDefaultsSuite)
        FileHandle.standardError.write(Data("GitHubPet: snapshots written to \(directory.path)\n".utf8))
    }

    /// Renders `view` the way the app shows it. With `asWindow`, it goes through the same
    /// NSHostingController window sizing as the real Inbox window.
    private static func render<V: View>(_ view: V, name: String, directory: URL, appearance: NSAppearance.Name,
                                        asWindow: Bool = false) async -> [String] {
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
        window.appearance = NSAppearance(named: appearance)
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
        var background = NSColor.windowBackgroundColor.cgColor
        (view.window?.appearance ?? view.effectiveAppearance).performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        context.setFillColor(background)
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

    /// Exercises the real mascot container's accessibility contract: one button whose press
    /// runs the same action as a click.
    private static func mascotAccessibility(_ model: AppModel) -> String {
        let container = MascotContainerView()
        var pressed = false
        container.onClick = { pressed = true }
        container.accessibilityText = { MascotView.accessibilityLabel(model) }
        let element = container.isAccessibilityElement()
        let role = container.accessibilityRole()?.rawValue ?? "none"
        let handled = container.accessibilityPerformPress()
        return "mascot AX: element=\(element) role=\(role) press=\(handled && pressed ? "opens-inbox" : "none") "
            + "label=\(container.accessibilityLabel() ?? "")"
    }

    /// Drives the real mascot container with synthetic press/release events: a release past the
    /// drag threshold with no mouseDragged in between must move and save, not open the Inbox;
    /// a release in place must open the Inbox.
    private static func mascotPointer() -> String {
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 2000, width: 128, height: 150),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = MascotContainerView(frame: CGRect(x: 0, y: 0, width: 128, height: 150))
        window.contentView = container
        var clicks = 0
        var saved: CGPoint?
        container.onClick = { clicks += 1 }
        container.onDragEnded = { saved = $0 }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
        }
        container.mouseDown(with: event(.leftMouseDown, CGPoint(x: 72, y: 96)))
        container.mouseUp(with: event(.leftMouseUp, CGPoint(x: 110, y: 104)))
        let moved = window.frame.origin == CGPoint(x: 2038, y: 2008) && saved == window.frame.origin && clicks == 0
        container.mouseDown(with: event(.leftMouseDown, CGPoint(x: 40, y: 40)))
        container.mouseUp(with: event(.leftMouseUp, CGPoint(x: 41, y: 40)))
        let clicked = clicks == 1 && window.frame.origin == CGPoint(x: 2038, y: 2008)
        return "mascot pointer: drop-without-drag-events=\(moved ? "moved" : "FAILED \(window.frame.origin)") "
            + "click=\(clicked ? "opens-inbox" : "FAILED clicks=\(clicks)")"
    }

    /// Shows a real mascot panel and hover popover on screen for a moment and measures the gap
    /// between the popover's arrow tip (its window's bottom edge) and the character's visible top.
    private static func hoverGap(model: AppModel, side: CGFloat) async -> String {
        guard let screen = NSScreen.main?.visibleFrame else { return "hover gap @\(Int(side)): no screen" }
        let size = MascotView.panelSize(side: side)
        let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: screen.minX + 40, y: screen.minY + 40), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let container = MascotContainerView(frame: CGRect(origin: .zero, size: size))
        let hosting = PassthroughHostingView(rootView: MascotView(model: model))
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container
        panel.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 300_000_000)   // let the panel reach the screen first
        let popover = MascotWindowController.makeHoverPopover(model: model)
        popover.animates = false
        popover.show(relativeTo: MascotWindowController.hoverAnchor(in: container.bounds, pack: model.pack),
                     of: container, preferredEdge: .maxY)
        try? await Task.sleep(nanoseconds: 400_000_000)
        defer { popover.close(); panel.orderOut(nil) }
        guard let popoverFrame = popover.contentViewController?.view.window?.frame else {
            return "hover gap @\(Int(side)): popover not shown"
        }
        let characterTop = panel.frame.minY + MascotView.characterTop(side: side, pack: model.pack)
        let gap = popoverFrame.minY - characterTop
        let above = popoverFrame.minY >= panel.frame.minY
        func describe(_ rect: CGRect) -> String {
            "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
        }
        // Gap from the highest visible art pixel (any static pose) to the popover's arrow tip,
        // the popover's nearest visible point. Negative would mean overlap.
        return "hover gap @\(Int(side)): \(Int(gap.rounded())) pt arrow-tip-to-character, popover \(above ? "above" : "below") "
            + "panel=\(describe(panel.frame)) popover=\(describe(popoverFrame)) character-top-y=\(Int(characterTop))"
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
