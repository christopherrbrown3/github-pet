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
            report.append("service=\(model.serviceState.statusText(count: model.serviceIncidents.count)) "
                          + "incident-rows=\(model.serviceIncidents.count) unseen-incidents=\(model.unseenIncidents.count)")
            report.append("incident-marker=\(model.incidentMarker?.tier.rawValue ?? "none") "
                          + "hover-top=\(model.hoverLines(compact: false).first ?? "") "
                          + "compact-hover=\(model.hoverLines(compact: true).joined(separator: " | "))")
            report.append("source=\(model.settings.dataSource.rawValue) privacy=\(model.settings.privacyMode) "
                          + "details=\(model.detailsRevealed) inbox-privacy=\(model.inboxPrivacy)")
            report.append("menu-bar AX: \(model.statusAccessibilityLabel)")
            report.append(mascotAccessibility(model))
            if name == "00-loading" { report.append(mascotPointer()) }
            let panel = model.layout(model.settings.mascotSize).panelSize
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                report += await render(MascotView(model: model).frame(width: panel.width, height: panel.height),
                                       name: "\(name)-mascot\(suffix)", directory: directory, appearance: appearance)
                report += await render(HoverSummaryView(model: model, compact: model.hoverIsCompact), name: "\(name)-hover\(suffix)",
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
        report.append("## lane labels (native text, widest count)")
        for side in [CGFloat(64), 128, 256] {
            report.append(tagFit(model: model, side: side))
            // The real panel with the widest count, full DEMO and the idle pose.
            let saved = model.settings.mascotSize
            model.settings.mascotSize = Double(side)
            let panel = MascotView(model: model, poseOverride: MascotPose(state: .idle, frame: nil, clipElapsed: nil),
                                   badgeOverride: "99+")
                .frame(width: model.layout(Double(side)).panelSize.width, height: model.layout(Double(side)).panelSize.height)
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                report += await render(panel, name: "lane-\(Int(side))-99plus\(suffix)", directory: directory,
                                       appearance: appearance)
            }
            model.settings.mascotSize = saved
        }
        report.append("## near-touch labels (real MascotView rasterised; art and labels drawn separately)")
        report += await nearTouchMeasurements(model: model, directory: directory)
        report.append("## hover placement (idle)")
        for placementCase in HoverCase.all {
            report.append(await hoverPlacement(model: model, placementCase, directory: directory))
        }
        model.injectEntitlementEvent()
        await capture("02-injected")
        // Fixture timestamps must use the app clock (QA clock hooks), not the wall clock.
        if let newest = model.items.map(\.updatedAt).max() {
            report.append("injected-age-on-app-clock=\(Int(model.clock().timeIntervalSince(newest)))s")
        }
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
        report.append("## hover placement (attention, swept lean outline)")
        for placementCase in HoverCase.attention {
            report.append(await hoverPlacement(model: model, placementCase, directory: directory))
        }
        model.markAllSeen()
        model.injectWorkflowFailure()
        await capture("10-urgent-static")
        report.append("## hover placement (urgent, privacy off: names and titles)")
        model.settings.privacyMode = false
        for placementCase in HoverCase.urgent {
            report.append(await hoverPlacement(model: model, placementCase, directory: directory))
        }
        model.settings.privacyMode = true
        // Late in the scenario: the probe injects fixture events, which would change earlier counts.
        report.append("## attention gesture (#29, live model)")
        report += await gestureProbe(model: model, directory: directory)
        // GitHub Status (#11): a new major incident is urgent; resolving leaves quietly.
        model.markAllSeen()
        model.injectServiceIncident(.major)
        await capture("10c-incident-major")
        report.append("## incident marker (#37: rasterised marker vs labels and keep-out, every tier and pose)")
        report += await incidentMarkerProbe(model: model, directory: directory)
        model.resolveServiceIncidents()
        await capture("10d-incidents-resolved")
        // Counts above 99: the mascot shows "99+" (its slot's width), inbox and AX the full count.
        report.append("## count cap")
        for _ in 0..<100 { model.injectEntitlementEvent() }
        model.markAllSeen()
        report.append("count cap: items=\(model.items.count) mascot-badge=\(model.mascotBadge ?? "none") "
                      + "inbox-badge=\(model.badge ?? "none") ax=\(model.statusAccessibilityLabel)")
        report += await render(MascotView(model: model)
            .frame(width: model.layout(model.settings.mascotSize).panelSize.width,
                   height: model.layout(model.settings.mascotSize).panelSize.height),
                               name: "count-cap-mascot", directory: directory, appearance: .aqua)
        // Only with an explicit gh path that does not exist (e.g. /nonexistent/gh): the result
        // is deterministic and can never contain live GitHub data.
        if let path = ProcessInfo.processInfo.environment[GhLocator.overrideVariable],
           !FileManager.default.fileExists(atPath: path) {
            model.settings.dataSource = .githubCLI
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await capture("11-gh-override")
        }


        report.append("## hover follows content growth (real mascot window controller)")
        report.append(await hoverGrowthProbe(model: model))
        report.append("## resize (real mascot window controller, as the Settings slider does)")
        report += await resizeProbe(model: model, directory: directory)

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

    /// Opens the real controller's hover summary while Loading (narrow), then lets a refresh fill
    /// it with titles (privacy off: much wider). The panel sits so the narrow summary fits on the
    /// right but the wide one doesn't: the grown summary must be re-placed on the left, clear of
    /// the art, the labels and the screen edge (Copilot 4567505191). Without re-placement it stays
    /// on the right and AppKit pushes it back over the mascot.
    private static func hoverGrowthProbe(model: AppModel) async -> String {
        let saved = model.settings
        defer { model.settings = saved }
        guard let screen = NSScreen.main?.visibleFrame, let pack = model.pack else { return "hover growth: no screen or pack" }
        model.settings.mascotSize = 128
        model.settings.dataSource = .fixtures   // so the refresh below really fills the summary
        model.settings.privacyMode = false
        let layout = model.layout(128)
        // Room on the right of the art for about 260 pt: enough for Loading, not for titles.
        let origin = CGPoint(x: screen.maxX - layout.artFrame.maxX - 260, y: screen.minY + 160)
        model.settings.mascotOriginX = Double(origin.x)
        model.settings.mascotOriginY = Double(origin.y)
        model.settings.mascotVisible = true
        var controller: MascotWindowController? = MascotWindowController(model: model)
        try? await Task.sleep(nanoseconds: 500_000_000)
        model.showLoadingForSnapshot()
        try? await Task.sleep(nanoseconds: 200_000_000)
        controller?.showSummaryNow()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let before = controller?.summaryWindowFrame
        model.refresh()
        try? await Task.sleep(nanoseconds: 900_000_000)
        defer { controller = nil }
        guard let after = controller?.summaryWindowFrame, let before, let panel = controller?.panelFrame else {
            model.settings.mascotVisible = false
            return "hover growth: summary not shown"
        }
        let art = layout.artFrame.offsetBy(dx: panel.minX, dy: panel.minY)
        let scale = art.width / CGFloat(MascotPack.canvasSize)
        let artPixels = (pack.artProfiles[model.mascotState]?.rows ?? []).enumerated().compactMap { index, span in
            span.map { CGRect(x: art.minX + CGFloat($0.lowerBound) * scale, y: art.maxY - CGFloat(index + 1) * scale,
                              width: CGFloat($0.count) * scale, height: scale) }
        }
        let labels = layout.labelRects.map { $0.offsetBy(dx: panel.minX, dy: panel.minY) }
        let side = { (frame: CGRect) in frame.minX >= art.midX ? "right" : "left" }
        let artClear = !artPixels.contains { $0.intersects(after) }
        let clear = !labels.contains { $0.intersects(after) }
        let onScreen = screen.insetBy(dx: -0.5, dy: -0.5).contains(after)
        model.settings.mascotVisible = false
        try? await Task.sleep(nanoseconds: 200_000_000)
        return "hover growth: grew=\(after.width > before.width + 1) before-side=\(side(before)) after-side=\(side(after)) "
            + "art-clear=\(artClear) labels-clear=\(clear) on-screen=\(onScreen) "
            + "before=\(Int(before.width))x\(Int(before.height)) after=\(Int(after.width))x\(Int(after.height))"
    }

    /// Drives a real MascotWindowController through size changes the way the Settings slider does
    /// and checks that the panel follows the setting and the ground point stays put.
    private static func resizeProbe(model: AppModel, directory: URL) async -> [String] {
        let saved = model.settings
        model.settings.mascotOriginX = nil
        model.settings.mascotOriginY = nil
        model.settings.mascotSize = 128
        model.settings.mascotVisible = true
        var controller: MascotWindowController? = MascotWindowController(model: model)
        try? await Task.sleep(nanoseconds: 500_000_000)
        func ground(_ frame: CGRect, _ size: Double) -> CGPoint {
            let g = model.layout(Double(size)).ground
            return CGPoint(x: frame.minX + g.x, y: frame.minY + g.y)
        }
        var lines: [String] = []
        var previous = (frame: controller?.panelFrame ?? .zero, size: 128.0)
        for size in [64.0, 256, 128] {
            model.settings.mascotSize = size
            try? await Task.sleep(nanoseconds: 500_000_000)
            let frame = controller?.panelFrame ?? .zero
            let expected = model.layout(Double(size)).panelSize
            // What the real panel draws after the resize (its hosted SwiftUI content).
            if let content = controller?.panelContentView, let png = renderPNG(content) {
                try? png.write(to: directory.appendingPathComponent("resize-\(Int(previous.size))-to-\(Int(size)).png"))
            }
            let before = ground(previous.frame, previous.size), after = ground(frame, size)
            let drift = hypot(after.x - before.x, after.y - before.y)
            lines.append("resize \(Int(previous.size))->\(Int(size)): setting=\(Int(model.settings.mascotSize)) "
                         + "panel=\(Int(frame.width))x\(Int(frame.height)) expected=\(Int(expected.width))x\(Int(expected.height)) "
                         + "ground-drift=\(format(drift)) ok=\(frame.size == expected && model.settings.mascotSize == size && drift < 0.5)")
            previous = (frame, size)
        }
        // Dragging the Settings slider: 16 pt steps in quick succession, up to 256 then down to 64.
        for (from, to) in [(128.0, 256.0), (256.0, 64.0)] {
            for size in stride(from: from, through: to, by: to > from ? 16 : -16) {
                model.settings.mascotSize = size
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let frame = controller?.panelFrame ?? .zero
            let expected = model.layout(Double(to)).panelSize
            if let content = controller?.panelContentView, let png = renderPNG(content) {
                try? png.write(to: directory.appendingPathComponent("slider-\(Int(from))-to-\(Int(to)).png"))
            }
            let before = ground(previous.frame, previous.size), after = ground(frame, to)
            let drift = hypot(after.x - before.x, after.y - before.y)
            lines.append("slider \(Int(from))->\(Int(to)): setting=\(Int(model.settings.mascotSize)) "
                         + "panel=\(Int(frame.width))x\(Int(frame.height)) expected=\(Int(expected.width))x\(Int(expected.height)) "
                         + "ground-drift=\(format(drift)) ok=\(frame.size == expected && model.settings.mascotSize == to && drift < 0.5)")
            previous = (frame, to)
        }
        model.settings.mascotVisible = false
        try? await Task.sleep(nanoseconds: 200_000_000)
        controller = nil
        model.settings = saved
        return lines
    }

    /// Measures the actual rasterised gap between the labels and the art (#28 near-touch): for
    /// each size, backing scale, pose (static and every frame of every state) and count text, the
    /// real MascotView is drawn twice (art only, labels only) and the nearest pair of visible
    /// pixels is found. Reports the range and any overlapping pixels.
    private static func nearTouchMeasurements(model: AppModel, directory: URL) async -> [String] {
        guard let pack = model.pack else { return ["near-touch: no pack"] }
        var lines: [String] = []
        // One offscreen window reused for every case: SwiftUI only commits its layers inside one.
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 300, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var empty = 0
        let saved = model.settings.mascotSize
        defer { model.settings.mascotSize = saved }
        for side in [64.0, 128, 256] {
            model.settings.mascotSize = side
            let layout = model.layout(side)
            for scale in [CGFloat(1), 2] {
                var gaps: [CGFloat] = []
                var upright: [CGFloat] = [], leaning: [CGFloat] = []
                var overlaps = 0
                var worst = "", closest = ""
                var sheet: [(name: String, art: [UInt8], labels: [UInt8], gap: CGFloat)] = []
                // Every upright pose, plus the attention gesture's leaning frames.
                var poses = MascotState.allCases.flatMap { state in
                    (pack.frameURLs(for: state).indices.map { Optional($0) } + [nil])
                        .map { MascotPose(state: state, frame: $0, clipElapsed: nil) }
                }
                if pack.attentionGesture != nil {
                    poses += [-5.0, -2.5].map { MascotPose(state: .attention, frame: 0, clipElapsed: 0, angle: $0) }
                    for frame in [1, 2] {
                        poses += [-5.0, -2.5, 2.5, 5].map { MascotPose(state: .attention, frame: frame, clipElapsed: 0, angle: $0) }
                    }
                }
                for pose in poses {
                        let state = pose.state, frame = pose.frame
                        for badge in ["2", "2+", "?", "99+"] {
                            func image(art: Bool) async -> [UInt8]? {
                                let view = MascotView(model: model, poseOverride: pose, badgeOverride: badge,
                                                      drawsArt: art, drawsLabels: !art)
                                    .environment(\.displayScale, scale)
                                return await alphaBitmap(view, in: host, size: layout.panelSize, scale: scale)
                            }
                            guard let artAlpha = await image(art: true), let labelAlpha = await image(art: false),
                                  artAlpha.contains(where: { $0 > 0 }), labelAlpha.contains(where: { $0 > 0 }) else {
                                empty += 1
                                continue
                            }
                            let (gap, overlap) = nearestGap(artAlpha, labelAlpha, size: layout.panelSize, scale: scale)
                            overlaps += overlap
                            let name = "\(state.rawValue)/\(frame.map(String.init) ?? "static")"
                                + (pose.angle == 0 ? "" : "@\(pose.angle)°") + "/\(badge)"
                            if gap > (gaps.max() ?? -1) { worst = name }
                            if gap < (gaps.min() ?? .infinity) { closest = name }
                            gaps.append(gap)
                            if pose.angle == 0 { upright.append(gap) } else { leaning.append(gap) }
                            sheet.append((name, artAlpha, labelAlpha, gap))
                        }
                }
                writeContactSheet(sheet, size: layout.panelSize, scale: scale,
                                  to: directory.appendingPathComponent("near-touch-\(Int(side))-\(Int(scale))x.png"))
                lines.append("near-touch @\(Int(side)) \(Int(scale))x: gap-min=\(format(gaps.min())) gap-max=\(format(gaps.max())) "
                             + "upright=\(format(upright.min()))-\(format(upright.max())) leaning=\(format(leaning.min()))-\(format(leaning.max())) "
                             + "(closest \(closest), farthest \(worst)) cases=\(gaps.count) empty-renders=\(empty) overlapping-pixels=\(overlaps) "
                             + "lane=\(format(layout.laneHeight))")
                empty = 0
            }
        }
        return lines
    }

    /// The incident marker never touches the labels (#37): at 64/128/256 and 1×/2×, the union of
    /// every tier's marker (static and burst frames) against the union of the labels over every
    /// pose with the widest count. Reports the nearest gap and pixels visible in both.
    private static func incidentMarkerProbe(model: AppModel, directory: URL) async -> [String] {
        guard let lead = model.serviceIncidents.first else { return ["incident marker: no incident"] }
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 300, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let saved = model.settings.mascotSize
        defer { model.settings.mascotSize = saved }
        var lines: [String] = []
        for side in [64.0, 128, 256] {
            model.settings.mascotSize = side
            let layout = model.layout(side)
            let poses = MascotState.allCases.flatMap { state in
                ((model.pack?.frameURLs(for: state).indices.map { Optional($0) } ?? []) + [nil])
                    .map { MascotPose(state: state, frame: $0, clipElapsed: nil) }
            }
            for scale in [CGFloat(1), 2] {
                func union(_ a: [UInt8]?, _ b: [UInt8]?) -> [UInt8]? {
                    guard let b else { return a }
                    guard let a else { return b }
                    return zip(a, b).map { max($0, $1) }
                }
                var labels: [UInt8]?, marker: [UInt8]?
                for pose in poses {
                    let view = MascotView(model: model, poseOverride: pose, badgeOverride: "99+", drawsArt: false,
                                          drawsLabels: true).environment(\.displayScale, scale)
                    labels = union(labels, await alphaBitmap(view, in: host, size: layout.panelSize, scale: scale))
                }
                for tier in [IncidentMarker.Tier.minor, .major, .critical] {
                    for elapsed in [nil, 0.0, 0.7, 1.9, 3.1, 5.3, 5.7] as [TimeInterval?] {
                        let view = IncidentMarkerView(marker: IncidentMarker(tier: tier, count: 1, lead: lead), layout: layout,
                                                      phase: markerPhase(tier, elapsed, lead: lead))
                            .frame(width: layout.panelSize.width, height: layout.panelSize.height, alignment: .topLeading)
                            .environment(\.displayScale, scale)
                        marker = union(marker, await alphaBitmap(view, in: host, size: layout.panelSize, scale: scale))
                    }
                }
                guard let labels, let marker, labels.contains(where: { $0 > 0 }), marker.contains(where: { $0 > 0 }) else {
                    lines.append("incident marker @\(Int(side)) \(Int(scale))x: empty render")
                    continue
                }
                let (gap, overlap) = nearestGap(marker, labels, size: layout.panelSize, scale: scale)
                // Design keep-out: no marker pixel in the top 64 canvas units of the art square.
                let width = Int((layout.panelSize.width * scale).rounded(.up))
                let keepOutRows = Int(((layout.laneHeight + layout.artSide * 64 / 256) * scale).rounded(.down))
                let keepOutPixels = marker.prefix(width * keepOutRows).filter { $0 > 0 }.count
                lines.append("incident marker @\(Int(side)) \(Int(scale))x: gap=\(format(gap)) overlapping-pixels=\(overlap) "
                             + "keep-out-pixels=\(keepOutPixels) slot=\(IncidentMarker.frame(in: layout).integral)")
            }
            // Native renders for design to compare with docs/design/incidents/previews: the real
            // mascot panel (labels, widest count) over the marker, design's preview columns.
            let tierPoses: [IncidentMarker.Tier: MascotPose] = [
                .minor: MascotPose(state: .attention, frame: 3, clipElapsed: nil),
                .major: MascotPose(state: .urgent, frame: 0, clipElapsed: nil),
                .critical: MascotPose(state: .urgent, frame: 0, clipElapsed: nil),
            ]
            let columns: [(String, TimeInterval?)] = [("static", nil), ("0.05s", 0.05), ("1.2s", 1.2), ("2.6s", 2.6)]
            var rendered = 0
            for tier in [IncidentMarker.Tier.minor, .major, .critical] {
                for (column, elapsed) in columns {
                    let scene = ZStack(alignment: .topLeading) {
                        IncidentMarkerView(marker: IncidentMarker(tier: tier, count: 1, lead: lead), layout: layout,
                                           phase: markerPhase(tier, elapsed, lead: lead))
                        MascotView(model: model, poseOverride: tierPoses[tier], badgeOverride: "99+", drawsMarker: false)
                    }
                    .frame(width: layout.panelSize.width, height: layout.panelSize.height, alignment: .topLeading)
                    for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                        let name = "incident-\(Int(side))-\(tier.rawValue)-\(column)\(suffix)"
                        if !(await render(scene, name: name, directory: directory, appearance: appearance)).isEmpty { rendered += 1 }
                    }
                }
            }
            lines.append("incident renders @\(Int(side)): \(rendered) PNGs (tiers x static/0.05s/1.2s/2.6s x light/dark)")
        }
        return lines
    }

    /// The marker phase `elapsed` seconds into a burst for a new incident (every layer fading in),
    /// or the static frame for nil.
    private static func markerPhase(_ tier: IncidentMarker.Tier, _ elapsed: TimeInterval?,
                                    lead: ServiceIncident) -> IncidentMarker.Phase {
        guard let elapsed else { return .still }
        let start = Date(timeIntervalSince1970: 0)
        return IncidentMarker(tier: tier, count: 1, lead: lead)
            .phase(now: start.addingTimeInterval(elapsed), burst: IncidentMarker.Burst(start: start, fromTier: nil),
                   reducedMotion: false, alertsAllowed: true)
    }

    /// Drives the real AppModel: one injected event starts one attention gesture; a second event
    /// during it merges (same start); it ends after 1.9 s; with Reduce Motion nothing plays. Also
    /// writes a filmstrip of the real MascotView at the storyboard's key times for each size.
    private static func gestureProbe(model: AppModel, directory: URL) async -> [String] {
        var lines: [String] = []
        let savedReduced = model.settings.reducedMotion
        model.settings.reducedMotion = false
        model.injectEntitlementEvent()
        let first = model.activeClip
        try? await Task.sleep(nanoseconds: 300_000_000)
        model.injectEntitlementEvent()
        let merged = model.activeClip?.startedAt == first?.startedAt && first != nil
        try? await Task.sleep(nanoseconds: 1_900_000_000)
        let ended = model.activeClip == nil
        model.markAllSeen()
        // Snooze mid-gesture stops it at once (no tick wait); lifting snooze replays nothing.
        model.injectEntitlementEvent()
        let playing = model.activeClip != nil
        model.snooze(.oneHour)
        let stoppedAtOnce = playing && model.activeClip == nil
        model.cancelSnooze()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let replayed = model.activeClip != nil
        model.markAllSeen()
        model.settings.reducedMotion = true
        model.injectEntitlementEvent()
        let reducedPlays = model.activeClip != nil
        model.settings.reducedMotion = savedReduced
        model.markAllSeen()
        // The system setting can't be overridden: with it on, nothing must play.
        lines.append("gesture environment: system-reduce-motion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) "
                     + "alerts-allowed=\(model.alertsAllowed)")
        lines.append("gesture: started=\(first != nil) state=\(first?.state.rawValue ?? "none") "
                     + "duration=\(format(first.map { CGFloat($0.endsAt.timeIntervalSince($0.startedAt)) })) "
                     + "second-event-merged=\(merged) ended=\(ended) reduced-motion-plays=\(reducedPlays)")
        lines.append("gesture cancel: snooze-stops-at-once=\(stoppedAtOnce) replayed-after-unsnooze=\(replayed)")

        guard let pack = model.pack, let gesture = pack.attentionGesture else { return lines + ["gesture: no pack gesture"] }
        var queue = EventClipQueue()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        queue.enqueue([InboxEvent(item: FixtureSimulator.defaultItems()[0])], now: start, playable: true)
        guard let clip = queue.active else { return lines }
        let times: [Double] = [0, 75, 150, 275, 400, 500, 600, 725, 850, 950, 1050, 1300, 1899]
        let saved = model.settings.mascotSize
        defer { model.settings.mascotSize = saved }
        for side in [64.0, 128, 256] {
            model.settings.mascotSize = side
            let size = model.layout(side).panelSize
            let frames: [NSView] = times.map { ms in
                let pose = MascotAnimator.pose(mood: .attention, clip: clip, now: start.addingTimeInterval(ms / 1000),
                                               reducedMotion: false, idleEpoch: start, gesture: gesture) { _ in [] }
                let view = VStack(spacing: 2) {
                    MascotView(model: model, poseOverride: pose, badgeOverride: "2").frame(width: size.width, height: size.height)
                    Text("\(Int(ms)) ms · f\(pose.frame.map(String.init) ?? "s") · \(String(format: "%+.1f", pose.angle))°")
                        .font(.system(size: 9)).foregroundStyle(.black)
                }
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                return host
            }
            let strip = NSStackView(views: frames)
            strip.spacing = 6
            strip.frame = CGRect(origin: .zero, size: strip.fittingSize)
            let window = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .white
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = strip
            window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 300_000_000)
            strip.layoutSubtreeIfNeeded()
            if let png = renderPNG(strip) {
                try? png.write(to: directory.appendingPathComponent("gesture-\(Int(side)).png"))
            }
            window.orderOut(nil)
        }
        lines.append("gesture filmstrips: gesture-64.png gesture-128.png gesture-256.png (\(times.count) key times)")
        return lines
    }

    /// A grid of near-touch cases for visual review: art grey, labels blue, overlapping pixels red,
    /// each captioned with its case and measured gap.
    private static func writeContactSheet(_ cases: [(name: String, art: [UInt8], labels: [UInt8], gap: CGFloat)],
                                          size: CGSize, scale: CGFloat, to url: URL) {
        let cellW = Int((size.width * scale).rounded(.up)), cellH = Int((size.height * scale).rounded(.up))
        let caption = Int(22 * max(scale, 1)), columns = 8
        let rows = (cases.count + columns - 1) / columns
        let width = columns * cellW, height = rows * (cellH + caption)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, item) in cases.enumerated() {
            let originX = (index % columns) * cellW
            let top = height - (index / columns) * (cellH + caption)   // bottom-up coordinates
            for y in 0..<cellH { for x in 0..<cellW {
                let i = y * cellW + x
                guard i < item.art.count else { continue }
                let (a, l) = (item.art[i], item.labels[i])
                guard a > 0 || l > 0 else { continue }
                let color = a > 0 && l > 0 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
                    : l > 0 ? CGColor(red: 0, green: 0.31, blue: 0.69, alpha: CGFloat(l) / 255)
                    : CGColor(gray: 0.2, alpha: CGFloat(a) / 255)
                context.setFillColor(color)
                context.fill(CGRect(x: originX + x, y: top - caption - y - 1, width: 1, height: 1))
            } }
            // Two short lines that fit the cell: pose (state/frame@angle) and count + gap.
            let parts = item.name.split(separator: "/")
            let pose = parts.dropLast().joined(separator: "/"), badge = parts.last.map(String.init) ?? ""
            let text = NSAttributedString(string: "\(pose)\n\(badge)  \(format(item.gap)) pt",
                                          attributes: [.font: NSFont.systemFont(ofSize: CGFloat(caption) * 0.36),
                                                       .foregroundColor: NSColor.black])
            text.draw(with: CGRect(x: originX + 2, y: top - caption + 1, width: cellW - 4, height: caption - 2),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// Alpha channel of a view rasterised at `scale` (rows top first), via its layer tree, drawn
    /// by `hosting` inside an offscreen window.
    private static func alphaBitmap<V: View>(_ view: V, in hosting: NSHostingView<AnyView>, size: CGSize,
                                             scale: CGFloat) async -> [UInt8]? {
        hosting.rootView = AnyView(view.frame(width: size.width, height: size.height))
        hosting.window?.setContentSize(size)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.displayIfNeeded()
        try? await Task.sleep(nanoseconds: 15_000_000)
        guard let layer = hosting.layer else { return nil }
        layer.contentsScale = scale
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.scaleBy(x: scale, y: scale)
            if hosting.isFlipped {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
            }
            layer.render(in: context)
            return true
        }
        guard ok else { return nil }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    /// Nearest distance (points) between visible pixels of two same-size alpha bitmaps, and the
    /// number of pixels visible in both. Only edge pixels can be nearest, so only they are compared.
    private static func nearestGap(_ a: [UInt8], _ b: [UInt8], size: CGSize, scale: CGFloat) -> (CGFloat, Int) {
        let width = Int((size.width * scale).rounded(.up)), height = a.count / max(width, 1)
        func edges(_ alpha: [UInt8], in box: (Int, Int, Int, Int)) -> [(Int, Int)] {
            var result: [(Int, Int)] = []
            for y in box.1...box.3 { for x in box.0...box.2 where alpha[y * width + x] > 0 {
                let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                if neighbours.contains(where: { $0.0 < 0 || $0.1 < 0 || $0.0 >= width || $0.1 >= height
                    || alpha[$0.1 * width + $0.0] == 0 }) { result.append((x, y)) }
            } }
            return result
        }
        var overlap = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width where b[y * width + x] > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            if a[y * width + x] > 0 { overlap += 1 }
        } }
        guard maxX >= 0 else { return (.infinity, 0) }
        let reach = Int(16 * scale)
        let labelEdges = edges(b, in: (minX, minY, maxX, maxY))
        let artEdges = edges(a, in: (max(0, minX - reach), max(0, minY - reach),
                                     min(width - 1, maxX + reach), min(height - 1, maxY + reach)))
        var best = Int.max
        for (x, y) in artEdges {
            for (lx, ly) in labelEdges {
                let d = (lx - x) * (lx - x) + (ly - y) * (ly - y)
                if d < best { best = d }
            }
        }
        // Distance between the facing edges of the two nearest pixels.
        let gap = best == Int.max ? CGFloat.infinity : max(0, CGFloat(Double(best).squareRoot()) - 1) / scale
        return (overlap > 0 ? 0 : gap, overlap)
    }

    /// Full DEMO and the widest count ("99+") at their native sizes must fit the panel with the
    /// minimum gap (design spec #28), so neither is ever truncated.
    private static func tagFit(model: AppModel, side: CGFloat) -> String {
        let layout = model.layout(Double(side))
        func width<V: View>(_ view: V) -> CGFloat { NSHostingView(rootView: view).fittingSize.width.rounded(.up) }
        let demo = width(Tag(text: PrivacyText.demoLabel.uppercased(), role: .demo, metrics: layout.demo))
        let count = width(Tag(text: "99+", role: .count, metrics: layout.count))
        let gap = layout.panelWidth - 2 * layout.inset - demo - count
        let demoClear = (model.pack?.allContours ?? []).map { layout.clearance($0, layout.demoFrame, lane: layout.laneHeight) }.min()
        var line = "tags @\(Int(side)): demo=\(Int(demo)) count99=\(Int(count)) panel=\(Int(layout.panelWidth)) "
        line += "gap=\(Int(gap)) min-gap=\(Int(layout.minimumGap)) fits=\(gap >= layout.minimumGap) "
        line += "lane=\(format(layout.laneHeight)) panel-height=\(format(layout.panelSize.height)) "
        line += "count-slot-x=\(Int(layout.countSlotX)) max-count-offset=\(format(layout.maxCountOffset)) "
        line += "demo-to-art=\(format(demoClear))"
        return line
    }

    struct HoverCase {
        enum Position: String { case center, leftEdge = "left-edge", rightEdge = "right-edge" }
        var side: CGFloat
        var position: Position
        var name: String { "\(Int(side))-\(position.rawValue)" }
        func name(_ state: MascotState) -> String { "\(state.rawValue)-\(name)" }

        static let all = [HoverCase(side: 64, position: .leftEdge), HoverCase(side: 64, position: .center),
                          HoverCase(side: 128, position: .center), HoverCase(side: 256, position: .center),
                          HoverCase(side: 128, position: .rightEdge)]
        /// Urgent with privacy off (four item lines: the tallest, widest summary).
        static let attention = [HoverCase(side: 64, position: .center), HoverCase(side: 256, position: .center)]
        static let urgent = [HoverCase(side: 64, position: .leftEdge), HoverCase(side: 64, position: .center),
                             HoverCase(side: 128, position: .rightEdge), HoverCase(side: 256, position: .center)]

        /// Panel origin, high enough above the screen bottom for a tall summary; the right-edge
        /// case is the app's default horizontal spot (24 pt from the right).
        func origin(size: CGSize, screen: CGRect) -> CGPoint {
            switch position {
            case .leftEdge: return CGPoint(x: screen.minX, y: screen.minY + 120)
            case .center: return CGPoint(x: (screen.midX - size.width / 2).rounded(), y: screen.minY + 120)
            case .rightEdge: return CGPoint(x: screen.maxX - size.width - 24, y: screen.minY + 120)
            }
        }
    }

    /// Shows the real mascot panel and hover popover on screen for a moment, measures the actual
    /// windows against the visible art of every frame of the current state, and writes one
    /// combined image (art, popover with its arrow, display edge) for visual review.
    private static func hoverPlacement(model: AppModel, _ placementCase: HoverCase, directory: URL) async -> String {
        let state = model.mascotState
        let label = "hover \(placementCase.name(state))"
        guard let screenFrame = NSScreen.main?.visibleFrame else { return "\(label): no screen" }
        let savedSize = model.settings.mascotSize
        model.settings.mascotSize = placementCase.side
        defer { model.settings.mascotSize = savedSize }
        let layout = model.layout(Double(placementCase.side))
        let size = layout.panelSize
        let panel = NSPanel(contentRect: CGRect(origin: placementCase.origin(size: size, screen: screenFrame), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .aqua)
        let container = MascotContainerView(frame: CGRect(origin: .zero, size: size))
        let hosting = PassthroughHostingView(rootView: MascotView(model: model))
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container
        panel.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 300_000_000)   // let the panel reach the screen first

        let (popover, placement) = MascotWindowController.prepareHover(model: model, panelFrame: panel.frame,
                                                                       screen: screenFrame)
        popover.animates = false
        popover.appearance = NSAppearance(named: .aqua)
        let anchor = MascotWindowController.makeHoverAnchor()
        MascotWindowController.show(popover, placement: placement, panelFrame: panel.frame, anchor: anchor)
        defer { popover.close(); panel.orderOut(nil); anchor.orderOut(nil) }
        var shown: NSWindow?
        for _ in 0..<8 where shown == nil {
            try? await Task.sleep(nanoseconds: 200_000_000)
            shown = popover.contentViewController?.view.window.flatMap { $0.isVisible ? $0 : nil }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let popoverWindow = shown else { return "\(label): popover not shown" }
        let window = popoverWindow.frame

        // Art of every frame the state can show (static pose first), measured independently of
        // the placement code, as screen-space row rects.
        let poses: [ArtProfile] = model.pack.map { pack in
            ([pack.staticFallbackData(for: state)].compactMap { $0 } + pack.frameData(for: state))
                .compactMap { ArtProfile(png: $0) }
        } ?? [.placeholder]
        let art = layout.artFrame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        func pixels(_ pose: ArtProfile) -> [CGRect] {
            let scale = art.width / CGFloat(pose.canvas)
            return pose.rows.enumerated().compactMap { index, span in
                span.map { CGRect(x: art.minX + CGFloat($0.lowerBound) * scale, y: art.maxY - CGFloat(index + 1) * scale,
                                  width: CGFloat($0.count) * scale, height: scale) }
            }
        }
        // The popover as drawn: its own window captured natively where the OS allows it (the
        // real bubble and arrow), else the whole window rectangle (an upper bound).
        let capture = captureWindows([popoverWindow])
        let visible = capture.flatMap { visibleRects($0, frame: window) } ?? [window]
        let source = capture == nil ? "window-bounds" : "native-capture"
        func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
            hypot(max(b.minX - a.maxX, 0, a.minX - b.maxX), max(b.minY - a.maxY, 0, a.minY - b.maxY))
        }
        let near = visible.filter { $0.insetBy(dx: -24, dy: -24).intersects(panel.frame) }
        var gaps: [CGFloat] = []
        var overlaps = 0
        for pose in poses {
            var nearest = CGFloat.infinity
            for row in pixels(pose) {
                for piece in near {
                    let d = distance(row, piece)
                    if row.intersects(piece) { overlaps += 1 }
                    nearest = min(nearest, d)
                }
            }
            gaps.append(nearest)
        }
        let tags = layout.tagBand.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        let laneClear = !visible.contains { $0.intersects(tags) }
        let onScreen = screenFrame.insetBy(dx: -0.5, dy: -0.5).contains(window)
        // Where the arrow points: the window's edge on the arrow side, at the anchor's height.
        let tip = CGPoint(x: placement.side == .right ? window.minX : window.maxX, y: panel.frame.minY + placement.tip.y)
        let tipGap = pixels(poses[0]).map { distance($0, CGRect(origin: tip, size: .zero)) }.min()
        let sideName = placement.side == .right ? "right" : "left"
        let worst = gaps.max(), best = gaps.min()

        let caption = "\(Int(placementCase.side)) pt, \(placementCase.position.rawValue), \(state.rawValue): popover \(sideName); "
            + "window-boundary gap \(format(best))-\(format(worst)) pt over \(poses.count) frames; arrow anchor to static art "
            + "\(format(tipGap)) pt; overlap \(overlaps == 0 ? "none" : "\(overlaps)"); "
            + "tags \(laneClear ? "clear" : "COVERED"); popover from \(source)"
        await writeHoverComposite(name: "hover-\(placementCase.name(state))", directory: directory, screen: screenFrame,
                                  panel: panel, popoverWindow: popoverWindow, capture: capture, tip: tip, tags: tags,
                                  caption: caption)
        func rect(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))" }
        // Window-boundary measures: the popover window rectangle (not its drawn arrow/chrome).
        var line = "\(label): state=\(state.rawValue) side=\(sideName) window-gap-min=\(format(best)) "
        line += "window-gap-max=\(format(worst)) arrow-anchor-to-static-art=\(format(tipGap)) "
        line += "frames=\(poses.count) overlap=\(overlaps) lane=\(laneClear ? "clear" : "covered") on-screen=\(onScreen) "
        line += "popover-source=\(source) panel=\(rect(panel.frame)) art=\(rect(art)) popover=\(rect(window)) "
        line += "screen=\(rect(screenFrame))"
        return line
    }

    /// The listed windows composited by the window server (their real pixels, including the
    /// popover's material and arrow), or nil where the OS doesn't allow it without Screen
    /// Recording permission. Looked up at run time: the API is unavailable in newer SDKs.
    private static func captureWindows(_ windows: [NSWindow]) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"),
              let primary = NSScreen.screens.first else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let ids = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber))! } as CFArray
        let bounds = windows.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        // Window-server coordinates have a top-left origin on the primary display.
        let rect = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
        // kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        guard let image = capture(rect, ids, 1 | 8)?.takeRetainedValue(), image.width > 0 else { return nil }
        // An image without any visible pixel means capture was refused.
        return visibleRects(image, frame: bounds)?.isEmpty == false ? image : nil
    }

    /// Screen-space rects (one per visible pixel run per row) of an image covering `frame`.
    private static func visibleRects(_ image: CGImage, frame: CGRect) -> [CGRect]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let sx = frame.width / CGFloat(width), sy = frame.height / CGFloat(height)
        var rects: [CGRect] = []
        for row in 0..<height {
            var run: Int?
            for column in 0...width {
                let on = column < width && pixels[(row * width + column) * 4 + 3] > 32
                if on, run == nil { run = column }
                if !on, let start = run {
                    rects.append(CGRect(x: frame.minX + CGFloat(start) * sx, y: frame.maxY - CGFloat(row + 1) * sy,
                                        width: CGFloat(column - start) * sx, height: sy))
                    run = nil
                }
            }
        }
        return rects
    }

    private static func format(_ value: CGFloat?) -> String {
        guard let value, value.isFinite else { return "none" }
        return String(format: "%.1f", value)
    }

    /// One reviewable image per placement: the region around the mascot and popover in screen
    /// space at 2x, the display edge and off-screen area when nearby, the real mascot drawing, the
    /// popover (natively captured where the OS allows; otherwise its window bounds as a flat
    /// outlined shape with its real content, labelled as such) and a caption.
    private static func writeHoverComposite(name: String, directory: URL, screen: CGRect, panel: NSWindow,
                                            popoverWindow: NSWindow, capture: CGImage?, tip: CGPoint, tags: CGRect,
                                            caption: String) async {
        var region = panel.frame.union(popoverWindow.frame).insetBy(dx: -24, dy: -24)
        for edge in [screen.minX, screen.maxX] where abs(edge - region.minX) < 60 || abs(edge - region.maxX) < 60 {
            region = region.union(CGRect(x: edge - 24, y: region.minY, width: 48, height: region.height))
        }
        region.size.height += 44   // caption strip (wraps to up to four lines)
        region.origin.y -= 44
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(region.width * scale), height: Int(region.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -region.minX, y: -region.minY)
        // Desktop stand-in, then hatch everything outside the display's visible frame.
        context.setFillColor(CGColor(gray: 0.86, alpha: 1))
        context.fill(region)
        context.saveGState()
        context.addRect(region)
        context.addRect(screen)
        context.clip(using: .evenOdd)
        context.setFillColor(CGColor(gray: 0.35, alpha: 1))
        context.fill(region)
        context.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
        context.setLineWidth(1)
        var x = region.minX - region.height
        while x < region.maxX {
            context.move(to: CGPoint(x: x, y: region.minY))
            context.addLine(to: CGPoint(x: x + region.height, y: region.maxY))
            x += 8
        }
        context.strokePath()
        context.restoreGState()
        context.setStrokeColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        context.setLineWidth(1)
        context.stroke(screen)

        // Mascot panel: real drawing plus thin outlines of the panel and its tag lane.
        drawLayer(of: panel.contentView, at: panel.frame.origin, in: context)
        context.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
        context.setLineDash(phase: 0, lengths: [3, 3])
        context.setLineWidth(0.5)
        context.stroke(panel.frame)
        context.stroke(tags)
        context.setLineDash(phase: 0, lengths: [])

        // Popover: its natively captured pixels, else its window bounds (flat, outlined) and content.
        if let capture {
            context.draw(capture, in: popoverWindow.frame)
        } else {
            let rect = popoverWindow.frame.insetBy(dx: 0.5, dy: 0.5)
            context.setFillColor(CGColor(gray: 0.98, alpha: 1))
            context.fill(rect)
            context.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
            context.setLineWidth(1)
            context.stroke(rect)
            if let content = popoverWindow.contentViewController?.view {
                let frame = content.convert(content.bounds, to: nil)
                drawLayer(of: content, at: CGPoint(x: popoverWindow.frame.minX + frame.minX,
                                                   y: popoverWindow.frame.minY + frame.minY), in: context)
            }
        }
        // Arrow-tip marker.
        context.setStrokeColor(CGColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 1))
        context.setLineWidth(0.75)
        context.move(to: CGPoint(x: tip.x - 4, y: tip.y)); context.addLine(to: CGPoint(x: tip.x + 4, y: tip.y))
        context.move(to: CGPoint(x: tip.x, y: tip.y - 4)); context.addLine(to: CGPoint(x: tip.x, y: tip.y + 4))
        context.strokePath()

        // Caption.
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let text = NSAttributedString(string: caption + " (display edge: red; dashed: panel and tag band)",
                                      attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black])
        let strip = CGRect(x: region.minX, y: region.minY, width: region.width, height: 44)
        NSColor.white.setFill()
        strip.fill()
        text.draw(with: strip.insetBy(dx: 6, dy: 3), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// Renders a view's layer tree at its screen origin (bottom-left), unflipping if needed.
    private static func drawLayer(of view: NSView?, at origin: CGPoint, in context: CGContext) {
        guard let view, let layer = view.layer else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        if view.isFlipped || layer.isGeometryFlipped == false && view.isFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        context.restoreGState()
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
