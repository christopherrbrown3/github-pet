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
    private lazy var hoverAnchor = Self.makeHoverAnchor()
    /// What the open summary's placement was computed for.
    private var summaryInputs: HoverPlacementInputs?
    /// Art size the panel is currently laid out for.
    private var shownSize: Double?
    /// The art's ground point on screen, kept unrounded: resizes are computed from it, not from
    /// the panel's pixel-rounded frame, so repeated resizes don't drift.
    private var groundOnScreen: CGPoint?
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
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.repositionSummaryIfNeeded() }
            .store(in: &cancellables)
    }

    private func update(visible: Bool, size: Double, origin savedOrigin: CGPoint?) {
        var origin = savedOrigin
        guard visible else {
            hideSummary()
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Resizing keeps the art's ground point where it is on screen (design spec #28): the
        // panel's width and lane change with size, so its origin moves instead, and is saved.
        let layout = model.layout(size)
        if let previous = shownSize, previous != size, panel.isVisible, let ground = groundOnScreen {
            origin = CGPoint(x: ground.x - layout.ground.x, y: ground.y - layout.ground.y)
            // `$settings` delivers during willSet, before the new size is stored: writing settings
            // here would modify the old value and the outer assignment would then drop the panel
            // resize (QA on a3d7aa7: Settings 64, panel 128×164). Save on the next turn, for
            // whatever size is shown by then (the slider may have moved again).
            DispatchQueue.main.async { [weak self] in
                guard let self, let ground = self.groundOnScreen, let shown = self.shownSize else { return }
                let current = self.model.layout(shown).ground
                self.saveOrigin(CGPoint(x: ground.x - current.x, y: ground.y - current.y))
            }
            _ = previous
        }
        shownSize = size
        let panelSize = layout.panelSize
        let frameOrigin = origin.flatMap { onScreen(CGRect(origin: $0, size: panelSize)) }
            ?? defaultOrigin(size: panelSize)
        groundOnScreen = CGPoint(x: frameOrigin.x + layout.ground.x, y: frameOrigin.y + layout.ground.y)
        panel.setFrame(CGRect(origin: frameOrigin, size: panelSize), display: true)
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
        let openInbox = { [weak self] in
            guard let self else { return }
            self.hideSummary()
            WindowPresenter.shared.showInbox(model: self.model)
        }
        let hosting = PassthroughHostingView(rootView: MascotView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.onClick = openInbox
        container.accessibilityText = { [weak self] in self.map { MascotView.accessibilityLabel($0.model) } ?? "" }
        // Save where the panel actually settles: the drop point moved fully on screen (#39), so the
        // saved origin is the one shown and restored.
        container.onDragEnded = { [weak self] origin in
            guard let self, let size = self.panel?.frame.size else { return }
            self.saveOrigin(Self.settledOrigin(origin, size: size))
        }
        container.onHover = { [weak self] inside in
            if inside { self?.showSummary(from: container) } else { self?.hideSummary() }
        }
        panel.contentView = container
        return panel
    }

    /// Saves both coordinates in one settings change, so no half-updated origin is observed.
    private func saveOrigin(_ origin: CGPoint) {
        var settings = model.settings
        settings.mascotOriginX = Double(origin.x)
        settings.mascotOriginY = Double(origin.y)
        model.settings = settings
    }

    /// The mascot panel's frame, if it is shown (render-check probe).
    var panelFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }
    var panelContentView: NSView? { panel?.contentView }

    private func showSummary(from view: NSView) {
        hideSummary()
        guard let window = view.window else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let (popover, placement) = Self.prepareHover(model: model, panelFrame: window.frame, screen: screen)
        Self.reportIfUnclear(placement)
        Self.show(popover, placement: placement, panelFrame: window.frame, anchor: hoverAnchor)
        self.popover = popover
        summaryInputs = inputs(popover: popover, panelFrame: window.frame)
    }

    private func inputs(popover: NSPopover, panelFrame: CGRect) -> HoverPlacementInputs {
        HoverPlacementInputs(contentSize: Self.measuredContentSize(popover) ?? popover.contentSize, panelFrame: panelFrame,
                             state: model.mascotState, gesture: Self.gesturePlaying(model))
    }

    /// The summary's current natural size (its content may have changed since it was placed).
    static func measuredContentSize(_ popover: NSPopover) -> CGSize? {
        (popover.contentViewController as? NSHostingController<HoverSummaryView>)?.view.fittingSize
    }

    /// Open summary and its window frame (render-check probe).
    func showSummaryNow() {
        guard let view = panel?.contentView else { return }
        showSummary(from: view)
    }
    var summaryWindowFrame: CGRect? { popover?.contentViewController?.view.window?.frame }

    /// The hover summary popover, sized to its content before it is shown. Without that, the
    /// hosting controller's provisional size placed the popover ~237 pt above the mascot (#27).
    static func makeHoverPopover(model: AppModel, compact: Bool) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = !model.effectiveReducedMotion
        let controller = NSHostingController(rootView: HoverSummaryView(model: model, compact: compact))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        return popover
    }

    /// The hover popover and where it goes: the full summary if it can be placed within #27's
    /// limits, else the compact one (always below `AppModel.compactHoverBelow`).
    static func prepareHover(model: AppModel, panelFrame: CGRect, screen: CGRect) -> (NSPopover, HoverPlacement) {
        let popover = makeHoverPopover(model: model, compact: model.hoverIsCompact)
        return (popover, placeHover(popover, model: model, panelFrame: panelFrame, screen: screen))
    }

    /// Sizes `popover` for the full summary if that can be placed within #27's limits, else the
    /// compact one, and returns where it goes. Used when opening and when re-placing.
    static func placeHover(_ popover: NSPopover, model: AppModel, panelFrame: CGRect, screen: CGRect) -> HoverPlacement {
        let layout = model.layout(model.settings.mascotSize)
        let controller = popover.contentViewController as? NSHostingController<HoverSummaryView>
        func attempt(_ compact: Bool) -> HoverPlacement {
            controller?.rootView = HoverSummaryView(model: model, compact: compact)
            let size = controller?.view.fittingSize ?? popover.contentSize
            popover.contentSize = size
            return hoverPlacement(panelFrame: panelFrame, layout: layout, pack: model.pack, state: model.mascotState,
                                  popover: size, screen: screen, gesture: gesturePlaying(model))
        }
        if !model.hoverIsCompact {
            let full = attempt(false)
            if full.meetsTarget { return full }
        }
        return attempt(true)
    }

    /// Neither the full nor the compact summary could be placed clear of the labels with its arrow
    /// near the art (a tiny screen or extreme position): say so in the log rather than silently (#39).
    static func reportIfUnclear(_ placement: HoverPlacement) {
        guard !placement.meetsTarget else { return }
        FileHandle.standardError.write(Data(("GitHubPet: hover summary has no clear placement "
            + "(labels clear: \(placement.laneClear), arrow \(placement.arrowGap.rounded()) pt from the art)\n").utf8))
    }

    /// Beside the visible character (#27): above it, the arrow either covered the DEMO/count
    /// tags or sat more than 12 pt from the art. See `HoverPlacement`.
    /// An attention gesture with a lean is playing: hover placement then clears its swept outline.
    static func gesturePlaying(_ model: AppModel) -> Bool {
        model.activeClip?.state == .attention && model.pack?.attentionGesture != nil && !model.effectiveReducedMotion
    }

    static func hoverPlacement(panelFrame: CGRect, layout: MascotLayout, pack: MascotPack?, state: MascotState,
                               popover: CGSize, screen: CGRect, gesture: Bool = false) -> HoverPlacement {
        let art = gesture ? pack?.sweptAttentionProfile : pack?.artProfiles[state]
        return HoverPlacement.place(art: art ?? .placeholder, poses: pack?.poseProfiles[state] ?? [],
                             layout: layout, popover: popover,
                             panelOrigin: panelFrame.origin, screen: screen)
    }

    /// A 1×1 pt invisible, click-through window the popover points at. The arrow tip can lie
    /// outside the mascot panel (beside or just below a small character with a tall summary),
    /// and NSPopover won't show for a rect outside its view.
    static func makeHoverAnchor() -> NSPanel {
        let anchor = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.ignoresMouseEvents = true
        anchor.level = .floating
        anchor.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        anchor.isReleasedWhenClosed = false
        return anchor
    }

    /// Moves `anchor` so its outer edge on the popover's side is the arrow tip, then shows or
    /// re-aims `popover` at it.
    static func show(_ popover: NSPopover, placement: HoverPlacement, panelFrame: CGRect, anchor: NSPanel) {
        let tip = CGPoint(x: panelFrame.minX + placement.tip.x, y: panelFrame.minY + placement.tip.y)
        let right = placement.side == .right
        anchor.setFrame(CGRect(x: right ? tip.x - 1 : tip.x, y: tip.y - 0.5, width: 1, height: 1), display: false)
        anchor.orderFrontRegardless()
        guard let view = anchor.contentView else { return }
        // Showing again repositions an open popover, including onto the other side; setting only
        // positioningRect would keep its original edge (found by the content-growth probe).
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: right ? .maxX : .minX)
    }

    private func hideSummary() {
        popover?.performClose(nil)
        popover = nil
        summaryInputs = nil
        hoverAnchor.orderOut(nil)
    }

    /// Each state's frames have their own outline: re-aim the open summary when the mood changes.
    private func repositionSummaryIfNeeded() {
        // Re-place when the content's size, the panel, the mood or a gesture changed (e.g. Loading
        // replaced by results), re-choosing full or compact; never per animation frame.
        guard let popover, let placed = summaryInputs, let window = panel,
              placed.needsReplacement(for: inputs(popover: popover, panelFrame: window.frame)) else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let placement = Self.placeHover(popover, model: model, panelFrame: window.frame, screen: screen)
        Self.reportIfUnclear(placement)
        Self.show(popover, placement: placement, panelFrame: window.frame, anchor: hoverAnchor)
        summaryInputs = inputs(popover: popover, panelFrame: window.frame)
    }

    /// Where a dropped panel settles: fully on the display it mostly sits on, else unchanged (the
    /// next update falls back to the default spot).
    static func settledOrigin(_ origin: CGPoint, size: CGSize) -> CGPoint {
        PanelPosition.accepted(origin: origin, size: size, visibleFrames: NSScreen.screens.map(\.visibleFrame)) ?? origin
    }

    /// The frame's origin moved fully inside the display it mostly sits on (so the count/quality
    /// badge stays visible), or nil if it isn't mostly on any display.
    private func onScreen(_ frame: CGRect) -> CGPoint? {
        PanelPosition.accepted(origin: frame.origin, size: frame.size, visibleFrames: NSScreen.screens.map(\.visibleFrame))
    }

    private func defaultOrigin(size: CGSize) -> CGPoint {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
    }
}

/// Lets the container receive all mouse events while SwiftUI only draws.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Distinguishes click from drag and reports hover. For accessibility it is a single button
/// whose press action is the same as a click: it opens the shared Inbox.
final class MascotContainerView: NSView {
    var onClick: (() -> Void)?
    var accessibilityText: () -> String = { "" }
    var onDragEnded: ((CGPoint) -> Void)?
    var onHover: ((Bool) -> Void)?

    private var mouseDownScreenPoint: CGPoint?
    private var windowOriginAtMouseDown: CGPoint?
    private var dragged = false
    private static let dragThreshold: CGFloat = 3

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityRoleDescription() -> String? { "button" }
    override func accessibilityLabel() -> String? { accessibilityText() }
    override func accessibilityHelp() -> String? { "Opens the inbox" }
    override func accessibilityChildren() -> [Any]? { nil }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// Screen location of a press or release, taken from the event itself.
    private func screenPoint(_ event: NSEvent) -> CGPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenPoint = screenPoint(event)
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
        // A press that ends past the drag threshold is a drag even if no mouseDragged events
        // arrived (synthetic or coalesced input opened the Inbox instead of moving; QA, 3cf6fa7).
        if !dragged, let start = mouseDownScreenPoint, let origin = windowOriginAtMouseDown, let window {
            let now = screenPoint(event)
            let dx = now.x - start.x, dy = now.y - start.y
            if hypot(dx, dy) >= Self.dragThreshold {
                onHover?(false)
                dragged = true
                window.setFrameOrigin(CGPoint(x: origin.x + dx, y: origin.y + dy))
            }
        }
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
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.hoverLines(compact: compact).enumerated()), id: \.offset) { index, line in
                Text(line).font(index == 0 ? .callout.bold() : .caption).lineLimit(1)
            }
            if !compact {
                Text("Click to open inbox").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
    }
}
