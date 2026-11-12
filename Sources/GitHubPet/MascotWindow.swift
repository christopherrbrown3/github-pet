import AppKit
import Combine
import GitHubPetCore
import SwiftUI

/// Transparent, borderless, always-on-top panel holding the mascot. Drag moves it (the
/// position is persisted), hover shows a privacy-aware summary, click opens the Inbox.
@MainActor
final class MascotWindowController {
    private let model: AppModel
    private var panel: NSPanel?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        model.$settings
            .map { ($0.mascotVisible, $0.mascotSize, $0.mascotOriginX, $0.mascotOriginY) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] visible, size, x, y in
                self?.update(visible: visible, size: size, origin: x.flatMap { x in y.map { CGPoint(x: x, y: $0) } })
            }
            .store(in: &cancellables)
    }

    private func update(visible: Bool, size: Double, origin: CGPoint?) {
        guard visible else {
            hideSummary()
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let side = CGFloat(size)
        let frameOrigin = origin.flatMap { onScreen(CGRect(origin: $0, size: CGSize(width: side, height: side))) }
            ?? defaultOrigin(side: side)
        panel.setFrame(CGRect(origin: frameOrigin, size: CGSize(width: side, height: side)), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.setAccessibilityLabel("GitHub Pet mascot")

        let container = MascotContainerView()
        let hosting = PassthroughHostingView(rootView: MascotView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.onClick = { [weak self] in
            guard let self else { return }
            self.hideSummary()
            WindowPresenter.shared.showInbox(model: self.model)
        }
        container.onDragEnded = { [weak self] origin in
            self?.model.settings.mascotOriginX = Double(origin.x)
            self?.model.settings.mascotOriginY = Double(origin.y)
        }
        container.onHover = { [weak self] inside in
            if inside { self?.showSummary(from: container) } else { self?.hideSummary() }
        }
        panel.contentView = container
        return panel
    }

    private func showSummary(from view: NSView) {
        hideSummary()
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = !model.effectiveReducedMotion
        popover.contentViewController = NSHostingController(rootView: HoverSummaryView(model: model))
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        self.popover = popover
    }

    private func hideSummary() {
        popover?.performClose(nil)
        popover = nil
    }

    /// Returns `frame.origin` if the frame is mostly on some screen, else nil.
    private func onScreen(_ frame: CGRect) -> CGPoint? {
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return !overlap.isNull && overlap.width * overlap.height >= frame.width * frame.height * 0.5
        }
        return visible ? frame.origin : nil
    }

    private func defaultOrigin(side: CGFloat) -> CGPoint {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: screen.maxX - side - 24, y: screen.minY + 24)
    }
}

/// Lets the container receive all mouse events while SwiftUI only draws.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Distinguishes click from drag and reports hover.
final class MascotContainerView: NSView {
    var onClick: (() -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onHover: ((Bool) -> Void)?

    private var mouseDownScreenPoint: CGPoint?
    private var windowOriginAtMouseDown: CGPoint?
    private var dragged = false
    private static let dragThreshold: CGFloat = 3

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenPoint = NSEvent.mouseLocation
        windowOriginAtMouseDown = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownScreenPoint, let origin = windowOriginAtMouseDown, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragged, hypot(dx, dy) < Self.dragThreshold { return }
        if !dragged { onHover?(false) }
        dragged = true
        window.setFrameOrigin(CGPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownScreenPoint = nil; windowOriginAtMouseDown = nil }
        if dragged, let origin = window?.frame.origin {
            onDragEnded?(origin)
        } else {
            onClick?()
        }
        dragged = false
    }
}

struct HoverSummaryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.summaryLines.enumerated()), id: \.offset) { index, line in
                Text(line).font(index == 0 ? .callout.bold() : .caption).lineLimit(1)
            }
            Text("Click to open inbox").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
    }
}
