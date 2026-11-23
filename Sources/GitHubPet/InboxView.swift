import GitHubPetCore
import SwiftUI

/// The shared inbox, used by the menu-bar popover and the Inbox window (#87 layout): the
/// selected mascot with its badge, an overview, then rows grouped by meaning. Content-aware: a
/// short queue sizes the window to its rows, a long one scrolls inside a fixed maximum height.
struct InboxView: View {
    @ObservedObject var model: AppModel
    var showsWindowButton: Bool
    /// Closing a real inbox marks its items seen; offscreen render copies must not.
    var marksSeenOnClose: Bool
    /// README renders only: hide the fixture Simulator menu, a developer control.
    var showsSimulator: Bool
    @State private var selection: InboxViewSelection
    /// The last local dismissal, offered back as Undo until it expires or something else happens.
    @State private var undo: UndoDismissal?
    /// Bumped by the Waiting on others tile: scroll its group into view once expanded (#148).
    @State private var waitingReveal = 0
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0

    init(model: AppModel, showsWindowButton: Bool = true, marksSeenOnClose: Bool = true,
         showsSimulator: Bool = true, initialSelection: InboxViewSelection = InboxViewSelection()) {
        self.model = model
        self.showsWindowButton = showsWindowButton
        self.marksSeenOnClose = marksSeenOnClose
        self.showsSimulator = showsSimulator
        _selection = State(initialValue: initialSelection)
    }

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            notes
            overview
            Divider()
            inboxContent
            // Incidents belong to the live Inbox, not to the local dismissed list.
            if !selection.showsDismissed(in: model.inboxDismissalContext) {
                ServiceIncidentsSection(model: model)
            }
            if let note = model.blockedLinkNote {
                Label(note, systemImage: "exclamationmark.triangle").font(.caption)
            }
            Divider()
            UpdateMenuRow(updates: model.updates)
            footer
        }
        .padding(12)
        .frame(minWidth: Self.width, idealWidth: Self.width)
        .onDisappear { if marksSeenOnClose { model.markAllSeen() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            InboxMascotHeader(model: model)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("GitHub Pet").font(.headline)
                    if model.isDemo {
                        Text("DEMO")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().strokeBorder(Color.secondary))
                            .accessibilityLabel("Demo data, not from GitHub")
                    }
                }
                HStack(spacing: 4) {
                    // Meaning is carried by primary-label words plus a symbol, never by colour
                    // alone (coloured caption text failed 4.5:1 contrast in light mode).
                    if let symbol = statusSymbol {
                        Image(systemName: symbol)
                            .symbolRenderingMode(.multicolor)
                            .accessibilityHidden(true)
                    }
                    Text(model.dataState.statusText)
                        .foregroundStyle(statusIsDegraded ? .primary : .secondary)
                        .fontWeight(statusIsDegraded ? .semibold : .regular)
                        .lineLimit(2)
                        .accessibilityIdentifier("inbox.status")
                }
                .font(.caption)
                Text(InboxPresentation.updatedText(lastSuccess: model.lastSuccess, dataState: model.dataState) {
                    $0.formatted(date: .omitted, time: .shortened)
                })
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("inbox.updated")
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if model.privacyMode { // #94: shown only while privacy mode is available and on
                    // Session-only reveal (design spec); turning privacy on again re-hides.
                    Button {
                        model.detailsRevealed.toggle()
                    } label: {
                        Image(systemName: model.detailsRevealed ? "eye.slash" : "eye")
                    }
                    .help(model.detailsRevealed ? "Hide details" : "Show details")
                    .accessibilityLabel(model.detailsRevealed ? "Hide details" : "Show details")
                    .accessibilityIdentifier("inbox.showDetails")
                }
                // A click while a poll is in flight is queued once, never dropped (#60).
                Button { model.requestRefresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(model.refreshing ? "Refreshing…" : "Refresh")
                .accessibilityLabel(model.refreshing ? "Refreshing" : "Refresh")
                .accessibilityIdentifier("inbox.refresh")
                .keyboardShortcut("r", modifiers: .command)
                Button { WindowPresenter.shared.showSettings(model: model) } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("inbox.settings")
            }
            .buttonStyle(.borderless)
            .imageScale(.large)
        }
    }

    private var statusIsDegraded: Bool { statusSymbol != nil }

    private var statusSymbol: String? {
        switch model.dataState {
        // Hidden matches are informational: no warning symbol and no degraded styling.
        case .ready, .empty, .hiddenOnly, .loading: return nil
        case .partial, .stale: return "exclamationmark.triangle.fill"
        case .ghMissing, .unauthenticated, .error: return "xmark.octagon.fill"
        }
    }

    /// Source, scope and setup notes: secondary captions, only when they say something.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let notice = model.demoNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("inbox.demoNotice")
            }
            Text(model.scopeSummary).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("inbox.monitoringScope")
            if let quality = model.scopeQuality {
                Text(quality)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("inbox.scopeQuality")
            }
            if let actions = model.actionsQuality {
                Text(actions).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("inbox.actionsQuality")
            }
            if let note = model.hiddenResultsNote {
                Label(note, systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("inbox.hiddenResults")
            }
            if let hint = model.dataState.hint {
                Text(hint).font(.caption.monospaced()).textSelection(.enabled)
            }
            GhSetupView(state: model.dataState)
            // #95: the Snoozed-until line is a snooze entry point.
            if model.settings.isSnoozed(at: model.now, features: model.features), let until = model.settings.snoozeUntil {
                Label("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened)) · still updating",
                      systemImage: "moon.zzz")
                    .font(.caption).foregroundStyle(.secondary)
            // #107: effective quiet hours only, so a hidden feature never shows a status.
            } else if model.settings.quietHoursActive(at: model.now, features: model.features) {
                Label("Quiet hours · still updating", systemImage: "moon")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Overview

    private var overviewModel: InboxOverview {
        InboxOverview(dataState: model.dataState, items: model.items,
                      allDismissed: model.allCurrentInboxItemsDismissed,
                      authoredWaiting: model.authoredWaitingCount, deploymentsWaiting: model.deploymentsWaitingCount,
                      deploymentsComplete: model.actionsQuality == nil,
                      serviceState: model.serviceState, incidents: model.serviceIncidents)
    }

    private var overview: some View {
        let overview = overviewModel
        let waitingHelp = [model.authoredWaitingNote, model.deploymentsWaitingNote].compactMap { $0 }
        return HStack(alignment: .top, spacing: 8) {
            OverviewTile(tile: overview.assigned, symbol: "tray.full")
                .help(model.inboxCountDescription)
                .accessibilityIdentifier("inbox.overview.assigned")
            // #148: reveals the Waiting on others group when there is one to show.
            OverviewTile(tile: overview.waiting, symbol: "hourglass", action: revealWaitingAction)
                .help(waitingHelp.isEmpty ? "Your pull requests and deployments waiting on someone else" : waitingHelp.joined(separator: "\n"))
                .accessibilityIdentifier("inbox.overview.waiting")
            OverviewTile(tile: overview.status, symbol: serviceSymbol)
                .help(serviceHelp)
                .accessibilityIdentifier("inbox.serviceStatus")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var revealWaitingAction: (() -> Void)? {
        guard model.waitingGroup.isShown, !selection.showsDismissed(in: model.inboxDismissalContext) else { return nil }
        return {
            selection.waitingExpanded = true
            waitingReveal += 1
        }
    }

    private var serviceSymbol: String {
        switch model.serviceState {
        case .loading: return "ellipsis.circle"
        case .operational: return "checkmark.circle.fill"
        case .incidents: return "exclamationmark.triangle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .error: return "xmark.octagon"
        }
    }

    /// Full status wording, including when the last good check was.
    private var serviceHelp: String {
        var text = model.serviceState.statusText(count: model.serviceIncidents.count)
        if let last = model.serviceLastSuccess, !model.serviceState.isFresh {
            text += " · last checked \(last.formatted(date: .omitted, time: .shortened))"
        }
        return text
    }

    // MARK: Items

    @ViewBuilder
    private var inboxContent: some View {
        let context = model.inboxDismissalContext
        let viewingDismissed = selection.showsDismissed(in: context)
        HStack(alignment: .firstTextBaseline) {
            Text(viewingDismissed ? "Dismissed here" : "Needs you")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if !viewingDismissed, model.dataState.hasUsableItems, !model.items.isEmpty {
                Text(model.badge.map { $0 == "1" ? "1 item" : "\($0) items" } ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let context {
                Button(viewingDismissed ? "Back to Inbox" : "View dismissed") {
                    selection.showDismissed(!viewingDismissed, in: context)
                    undo = nil
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier(viewingDismissed ? "inbox.backFromDismissed" : "inbox.viewDismissed")
            }
        }
        if let notice = model.inboxDismissalNotice {
            Text(notice).font(.caption)
                .accessibilityIdentifier("inbox.dismissalNotice")
        }
        if let undo, let context, !viewingDismissed {
            UndoBanner(undo: undo) {
                model.restoreInboxItem(undo.id, in: context)
                self.undo = nil
            }
            // A fixed, motion-free timeout; nothing animates while it is shown.
            .task(id: undo.id) {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled, self.undo?.id == undo.id { self.undo = nil }
            }
        }
        if viewingDismissed {
            DismissedInboxView(rows: model.dismissedInboxRows, privacy: model.inboxPrivacy) { id in
                if let context { model.restoreInboxItem(id, in: context) }
            }
        } else {
            content
        }
    }

    /// Unknown or failed data is never rendered as an empty inbox. The Waiting on others group
    /// (#148) follows the Needs you groups in the same list, so a long list scrolls to it.
    @ViewBuilder
    private var content: some View {
        let waiting = model.waitingGroup
        let waitingExpanded = selection.waitingExpanded && waiting.isShown
        let dimmed = !model.dataState.hasUsableItems || model.dataState == .stale
        if model.items.isEmpty {
            EmptyInboxView(model: model,
                           state: InboxEmptyState(dataState: model.dataState,
                                                  allDismissed: model.allCurrentInboxItemsDismissed))
        } else if dimmed {
            Label("Showing last known items", systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("inbox.lastKnown")
        }
        let sections = InboxPresentation.sections(model.items)
        if !sections.isEmpty || waiting.isShown {
            ScrollViewReader { proxy in
                let list = VStack(alignment: .leading, spacing: 8) {
                    ForEach(sections) { section in
                        InboxSectionView(section: section) { item in
                            InboxRow(item: item, privacy: model.inboxPrivacy, unseen: model.isUnseen(item), dimmed: dimmed,
                                     open: { model.open(item) }, dismiss: dismissAction(item))
                        }
                    }
                    if waiting.isShown {
                        WaitingSectionView(group: waiting, expanded: waitingExpanded,
                                           toggle: { selection.waitingExpanded.toggle() }) { item in
                            // Quieter than Needs you rows: never unseen, always the muted styling.
                            InboxRow(item: item, privacy: model.inboxPrivacy, unseen: false, dimmed: true,
                                     open: { model.open(item) }, dismiss: dismissAction(item))
                        }
                        .id(Self.waitingScrollID)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                let rows = model.items.count + (waitingExpanded ? max(1, waiting.items.count) : 0)
                Group {
                    // Short queues size to their rows (no blank region); long ones scroll in a fixed
                    // height. A ScrollView with only a max height collapses inside auto-sized windows
                    // and popovers (#20), so the scrolling case gets a real height.
                    if Self.scrolls(rows: rows, sections: sections.count + (waiting.isShown ? 1 : 0), textScale: textScale) {
                        ScrollView { list }
                            .frame(height: Self.maxListHeight)
                    } else {
                        list
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Inbox items")
                .onChange(of: waitingReveal) { _ in
                    // After the expansion has laid out; no animation, so Reduce Motion is respected.
                    DispatchQueue.main.async { proxy.scrollTo(Self.waitingScrollID, anchor: .top) }
                }
            }
        }
    }

    private func dismissAction(_ item: InboxItem) -> (() -> Void)? {
        guard let context = model.inboxDismissalContext, model.canDismissInboxItem(item) else { return nil }
        return {
            let title = PrivacyText.title(item, privacy: model.inboxPrivacy)
            model.dismissInboxItem(item.id, in: context)
            // Records are keyed by the item's digest (as the Dismissed list's Restore uses);
            // the raw id made Undo hide the banner without restoring anything.
            undo = UndoDismissal(id: EventBaseline.digest(item.id), title: title)
        }
    }

    static let maxListHeight = CGFloat(InboxRowMetrics.maxListHeight)
    static let waitingScrollID = "inbox.waitingGroup"

    /// `textScale` is 1 at the default text size and grows with Dynamic Type, so larger text
    /// scrolls the list instead of growing the window past the screen.
    static func scrolls(rows: Int, sections: Int, textScale: CGFloat = 1) -> Bool {
        InboxRowMetrics.scrolls(rows: rows, sections: sections, textScale: Double(textScale))
    }

    /// Height reserved for a flat list such as the dismissed items.
    static func listHeight(rows: Int, textScale: CGFloat = 1) -> CGFloat {
        min(CGFloat(rows) * 52 * max(1, textScale), maxListHeight)
    }

    // MARK: Footer

    private var snoozeMenu: some View {
        Menu {
            ForEach(SnoozeOption.allCases, id: \.self) { option in
                Button(option.title) { model.snooze(option) }
            }
            if model.settings.snoozeUntil != nil {
                Divider()
                Button("Turn off snooze") { model.cancelSnooze() }
            }
        } label: {
            Label("Snooze", systemImage: "moon.zzz")
        }
        .fixedSize()
        .help("Silence alerts; GitHub Pet keeps updating")
    }

    private var footer: some View {
        HStack {
            if model.features.snooze { snoozeMenu } // #95: snooze entry point
            if model.simulatesScope { ScopeSimulationMenu(model: model); ScopeSettingsSimulationMenu(model: model) }
            if showsSimulator && model.usingFixtures && !model.simulatesScope {
                SimulatorMenu(model: model).fixedSize()
            }
            Spacer()
            if showsWindowButton {
                Button { WindowPresenter.shared.showInbox(model: model) } label: {
                    Image(systemName: "macwindow")
                }
                .help("Open Inbox window")
                .accessibilityLabel("Open Inbox window")
            }
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit GitHub Pet")
                .accessibilityLabel("Quit GitHub Pet")
        }
        .controlSize(.small)
    }
}

struct UndoDismissal: Equatable {
    let id: String
    let title: String
}

/// "Dismissed · Undo" after a local hide. Says plainly that GitHub is unchanged.
struct UndoBanner: View {
    let undo: UndoDismissal
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Hid “\(undo.title)” here. GitHub is unchanged.")
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Undo", action: action)
                .controlSize(.small)
                .accessibilityLabel("Undo dismiss \(undo.title)")
                .accessibilityIdentifier("inbox.undoDismiss")
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
    }
}

/// The selected mascot's real artwork (a static pose for its mood, never animated here) with the
/// same blue count capsule the desktop pet shows, from the same count.
struct InboxMascotHeader: View {
    @ObservedObject var model: AppModel
    static let side: CGFloat = 52

    var body: some View {
        let pose = MascotPose(state: model.mascotState, frame: nil, clipElapsed: nil)
        let metrics = MascotLayout(artSide: 64).count
        ZStack(alignment: .topTrailing) {
            MascotStill(model: model, pose: pose)
                .frame(width: Self.side, height: Self.side)
            if let badge = model.mascotBadge {
                Tag(text: badge, role: model.mascotState == .urgent ? .urgentCount : .count, metrics: metrics)
                    .offset(x: 6, y: -4)
            }
        }
        .frame(width: Self.side + 6, height: Self.side)
        // One image announcing the count and state (stale, unknown, needs attention), as the
        // desktop pet and menu-bar icon do; the badge alone said only "4 items".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.statusAccessibilityLabel)
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("inbox.mascot")
    }
}

/// One still pose of the selected mascot: the loaded pack's own frame, or the placeholder.
struct MascotStill: View {
    @ObservedObject var model: AppModel
    let pose: MascotPose

    var body: some View {
        if let pack = model.pack {
            PackFigure(pack: pack, pose: pose)
        } else {
            PlaceholderFigure(pose: pose, date: model.now, reduced: true)
        }
    }
}

struct OverviewTile: View {
    let tile: InboxOverview.Tile
    let symbol: String
    /// A tile with an action is one button (#148: the Waiting on others tile reveals its group).
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { face.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(tile.accessibilityLabel)
                .accessibilityHint("Shows the Waiting on others group")
        } else {
            face
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tile.accessibilityLabel)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
                Text(tile.title).lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(tile.value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(tile.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.25)))
    }

    /// Tint supports the words; it never carries meaning on its own.
    private var tint: Color {
        switch tile.tone {
        case .neutral: return .secondary
        case .positive: return .green
        case .caution: return .orange
        case .critical: return .red
        }
    }

    private var symbolColor: Color { tile.tone == .neutral ? .secondary : tint }
}

struct InboxSectionView<Row: View>: View {
    let section: InboxSection
    @ViewBuilder let row: (InboxItem) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(section.group.title)
                Spacer()
                Text("\(section.items.count)").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(section.items) { item in
                    row(item)
                    if item.id != section.items.last?.id {
                        Divider().padding(.leading, 34)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.group.title)
    }
}

/// #148: your pull requests and deployments that need nothing from you, below the Needs you
/// groups. A disclosure (collapsed by default) whose header speaks its count; the count and note
/// follow the Waiting on others tile, so degraded data never reads as nothing waiting.
struct WaitingSectionView<Row: View>: View {
    let group: InboxWaitingGroup
    let expanded: Bool
    let toggle: () -> Void
    @ViewBuilder let row: (InboxItem) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    Text(InboxWaitingGroup.title)
                    Spacer()
                    Text(group.count).monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide what's waiting on others" : "Show what's waiting on others")
            .accessibilityLabel(group.accessibilityLabel)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Collapses the group" : "Expands the group")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("inbox.waiting.toggle")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    if let note = group.note {
                        Label(note, systemImage: group.lastKnown ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .accessibilityIdentifier("inbox.waiting.note")
                    }
                    ForEach(group.items) { item in
                        row(item)
                        if item.id != group.items.last?.id {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.02)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(InboxWaitingGroup.title)
    }
}

struct InboxRow: View {
    let item: InboxItem
    let privacy: Bool
    let unseen: Bool
    /// Last-known data (stale, partial, error). See `InboxDimming` for the contrast rules.
    var dimmed = false
    let open: () -> Void
    var dismiss: (() -> Void)?
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var glyphWidth = 16.0
    @ScaledMetric(relativeTo: .body) private var verticalPadding = 5.0

    private func alpha(_ role: InboxDimming.Role) -> Double {
        InboxDimming.alpha(role, dimmed: dimmed, increasedContrast: contrast == .increased)
    }

    var body: some View {
        // Large text wraps instead of truncating, and the row grows with it.
        let largeText = typeSize.isAccessibilitySize
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(unseen ? Color.accentColor : Color.clear)
                        .frame(width: 6, height: 6)
                    Image(systemName: item.kind.symbolName)
                        .foregroundStyle(item.kind.severity == .critical ? Color.red : Color.secondary)
                        .opacity(alpha(.glyph))
                        .frame(width: glyphWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).lineLimit(largeText ? 4 : 1).truncationMode(.tail)
                            .foregroundStyle(Color.primary.opacity(alpha(.title)))
                        Text(context).font(.caption).lineLimit(largeText ? 3 : 1)
                            .foregroundStyle(alpha(.context) == 1 ? AnyShapeStyle(.secondary)
                                                                  : AnyShapeStyle(Color.primary.opacity(alpha(.context))))
                            .fixedSize(horizontal: false, vertical: largeText)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(privacy ? "Open on GitHub" : "\(item.title)\nOpen on GitHub")
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Opens on GitHub")
            .accessibilityAction(named: "Open on GitHub", open)
            .modifier(OptionalAccessibilityAction(name: "Dismiss Here", action: dismiss))
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(hovering ? HierarchicalShapeStyle.secondary : .tertiary)
                .help("Dismiss here (GitHub is unchanged)")
                .accessibilityLabel("Dismiss \(title)")
                .accessibilityIdentifier("inbox.dismiss")
            }
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, verticalPadding)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : Color.clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open on GitHub", action: open)
            if let dismiss { Button("Dismiss Here", action: dismiss) }
        }
    }

    private var title: String { PrivacyText.title(item, privacy: privacy) }
    private var context: String { InboxPresentation.context(item, privacy: privacy) }

    private var accessibilityText: String {
        (unseen ? "New. " : "") + title + ". " + PrivacyText.subtitle(item, privacy: privacy)
    }
}

/// A named VoiceOver action only when the action exists (a row that can't be dismissed has none).
struct OptionalAccessibilityAction: ViewModifier {
    let name: String
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.accessibilityAction(named: name, action)
        } else {
            content
        }
    }
}

/// No rows. Only a verified empty inbox celebrates (a still mascot pose); every other state
/// says what is and isn't known.
struct EmptyInboxView: View {
    @ObservedObject var model: AppModel
    let state: InboxEmptyState

    var body: some View {
        VStack(spacing: 6) {
            if state.showsMascot {
                MascotStill(model: model, pose: MascotPose(state: .idle, frame: nil, clipElapsed: nil))
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
            } else if let symbol = state.symbolName {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(state.headline)
                .font(state.showsMascot ? .headline : .subheadline)
                .multilineTextAlignment(.center)
            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inbox.empty")
    }
}

/// GitHub Status incidents (#11) as their own group. The status itself lives in the overview
/// tile; only a fresh, verified success says there are none. Loading, stale and failed checks keep
/// last-known incidents dimmed.
struct ServiceIncidentsSection: View {
    @ObservedObject var model: AppModel
    static let maxRows = 4

    var body: some View {
        if !model.serviceIncidents.isEmpty {
            let dimmed = !model.serviceState.isFresh
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(InboxGroup.incidents.title)
                    Spacer()
                    if dimmed { Text("Last known").accessibilityIdentifier("inbox.incidentsLastKnown") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 0) {
                    // Most severe first; the rest are counted so the inbox stays compact.
                    ForEach(model.serviceIncidents.prefix(Self.maxRows)) { incident in
                        IncidentRow(incident: incident, privacy: model.inboxPrivacy,
                                    unseen: model.isUnseen(incident), dimmed: dimmed) { model.open(incident) }
                    }
                    if model.serviceIncidents.count > Self.maxRows {
                        Text("and \(model.serviceIncidents.count - Self.maxRows) more")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.bottom, 4)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("GitHub service incidents")
        }
    }
}

struct IncidentRow: View {
    let incident: ServiceIncident
    let privacy: Bool
    let unseen: Bool
    var dimmed = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var glyphWidth = 16.0
    @ScaledMetric(relativeTo: .body) private var verticalPadding = 5.0

    private func alpha(_ role: InboxDimming.Role) -> Double {
        InboxDimming.alpha(role, dimmed: dimmed, increasedContrast: contrast == .increased)
    }

    var body: some View {
        let largeText = typeSize.isAccessibilitySize
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(unseen ? Color.accentColor : Color.clear)
                    .frame(width: 6, height: 6)
                Image(systemName: ItemKind.serviceIncident.symbolName)
                    .foregroundStyle(incident.severity == .critical ? Color.red : Color.secondary)
                    .opacity(alpha(.glyph))
                    .frame(width: glyphWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PrivacyText.title(item, privacy: privacy)).lineLimit(largeText ? 4 : 1)
                        .foregroundStyle(Color.primary.opacity(alpha(.title)))
                    Text(subtitle).font(.caption).lineLimit(largeText ? 3 : 1)
                        .foregroundStyle(alpha(.context) == 1 ? AnyShapeStyle(.secondary)
                                                              : AnyShapeStyle(Color.primary.opacity(alpha(.context))))
                        .fixedSize(horizontal: false, vertical: largeText)
                }
                Spacer(minLength: 4)
                if !incident.isDemo {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Demo incidents have no status page: shown, but they open nothing.
        .disabled(incident.isDemo)
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, verticalPadding)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering && !incident.isDemo ? Color.primary.opacity(0.06) : Color.clear))
        .onHover { hovering = $0 }
        .help(incident.isDemo ? "Demo incident: no status page" : "Open on githubstatus.com")
        .accessibilityLabel((unseen ? "New. " : "") + PrivacyText.title(item, privacy: privacy) + ". " + subtitle)
    }

    private var item: InboxItem { incident.inboxItem }

    /// Impact and status are public status-page facts, so they stay visible in privacy mode.
    private var subtitle: String {
        ([incident.isDemo ? PrivacyText.demoLabel : nil, incident.impact.label, incident.status.label,
          incident.isDemo ? "No status page" : nil]
            .compactMap { $0 }).joined(separator: " · ")
    }
}

struct SimulatorMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu("Simulator") {
            Button("Inject entitlement event") { model.injectEntitlementEvent() }
            Button("Inject workflow failure (urgent)") { model.injectWorkflowFailure() }
            Button("Replay current snapshot") { model.replaySnapshot() }
            Toggle("Partial data", isOn: Binding(get: { model.partialPolls },
                                                 set: { model.setPartialPolls($0) }))
            Menu("GitHub service incident") {
                Button("Inject minor incident") { model.injectServiceIncident(.minor) }
                Button("Inject major incident (urgent)") { model.injectServiceIncident(.major) }
                Button("Inject critical incident (urgent)") { model.injectServiceIncident(.critical) }
                Divider()
                Button("Escalate one level") { model.escalateServiceIncidentsOneLevel() }
                Button("De-escalate one level (silent)") { model.deescalateServiceIncidentsOneLevel() }
                Button("Escalate all to major") { model.escalateServiceIncidents() }
                Divider()
                Button("Resolve all incidents") { model.resolveServiceIncidents() }
                Button("Reopen last resolved (silent)") { model.reopenLastResolvedIncident() }
                    .disabled(!model.canReopenServiceIncident)
                Button("Inject scheduled maintenance (ignored)") { model.injectScheduledMaintenance() }
                Divider()
                if model.serviceFetchFails {
                    Button("Status fetch recovers") { model.setServiceFetchFails(false) }
                } else {
                    Button("Status fetch fails") { model.setServiceFetchFails(true) }
                }
                Button("Mark status stale") { model.markServiceStale() }
                if !model.serviceIncidents.isEmpty {
                    Divider()
                    // Current tier per incident, for stepping through tier bursts.
                    ForEach(model.serviceIncidents) { incident in
                        Text("\(incident.name): \(IncidentMarker.Tier(impact: incident.impact).rawValue)")
                    }
                }
            }
            Button("Mark data stale") { model.markStale() }
            if model.simulatorConnected {
                Button("Simulate disconnect") { model.simulateDisconnect() }
            } else {
                Button("Reconnect") { model.simulateReconnect() }
            }
            Divider()
            Button("Reset baseline") { model.resetBaseline() }
        }
    }
}

/// Visible only for the explicit isolated offline launch flag; not the scope editor.
struct ScopeSimulationMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu("Simulated scope") {
            Text(model.scopeSimulationStatus)
            Text("Discarded late replies: \(model.discardedScopeReplies)")
            Button("Account A") { model.simulateScopeAccount(false) }
                .disabled(model.settings.dataSource != .githubCLI)
            Button("Account B") { model.simulateScopeAccount(true) }
                .disabled(model.settings.dataSource != .githubCLI)
            Divider()
            Button("Apply Selected (simulated validation)") { model.simulateScopeApply(true) }
                .disabled(model.settings.dataSource != .githubCLI)
            Button("Apply Everything (simulated validation)") { model.simulateScopeApply(false) }
                .disabled(model.settings.dataSource != .githubCLI)
            Button("Hold next repository reply") { model.simulateScopeHold() }
                .disabled(model.settings.dataSource != .githubCLI)
            Button("Deliver held replies") { model.simulateScopeDeliver() }
            Button("Deliver oldest held reply") { model.simulateScopeDeliverOne(newest: false) }
            Button("Deliver newest held reply") { model.simulateScopeDeliverOne(newest: true) }
            Button("Inject new repository row") { model.simulateScopeInject() }
                .disabled(model.settings.dataSource != .githubCLI)
            Button("Partial replies") { model.simulateScopePartial(true) }
                .disabled(model.settings.dataSource != .githubCLI)
            Button("Complete replies / recover") { model.simulateScopePartial(false) }
                .disabled(model.settings.dataSource != .githubCLI)
            Menu("Search visibility (#35)") {
                Button("All matches visible") { model.simulateScopeVisibility(.complete) }
                Button("Some matches hidden from account") { model.simulateScopeVisibility(.hidden) }
                Button("Only hidden matches") { model.simulateScopeVisibility(.hiddenOnly) }
                Button("Results capped") { model.simulateScopeVisibility(.capped) }
            }
            .disabled(model.settings.dataSource != .githubCLI)
            Divider()
            Button("Reload saved A (known viewer)") { model.simulateScopeReload() }
                .disabled(model.settings.dataSource != .githubCLI)
            Button("Reload saved A (unknown viewer)") { model.simulateScopeReload(forgetViewer: true) }
                .disabled(model.settings.dataSource != .githubCLI)
            Button("Corrupt saved A and reload") { model.simulateScopeReload(corrupt: true) }
                .disabled(model.settings.dataSource != .githubCLI)
            Button("Repair saved selections") { model.simulateScopeRepair() }
                .disabled(model.settings.dataSource != .githubCLI)
            Divider()
            Button("Inject minor public incident") { model.injectServiceIncident(.minor) }
            Button("Inject major public incident") { model.injectServiceIncident(.major) }
            Button("Resolve public incidents") { model.resolveServiceIncidents() }
        }
    }
}
