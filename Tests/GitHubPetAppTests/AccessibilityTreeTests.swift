import AppKit
import SwiftUI
import Testing
@testable import GitHubPet
@testable import GitHubPetCore

/// One node of the NSAccessibility tree, read with the same NSAccessibility selectors the system's
/// accessibility server uses. SwiftUI's own nodes (`AccessibilityNode`) implement them without
/// declaring `NSAccessibilityProtocol`, so they are read by selector.
struct AXNode {
    var type: String
    var role = "", subrole = "", label = "", title = "", value = "", help = "", identifier = ""
    var titleElement = ""
    var enabled: Bool?
    var customActions: [NSAccessibilityCustomAction] = []
    var children: [AXNode] = []
    weak var object: NSObject?

    /// What VoiceOver reads as the element's name: its label, title, or the text that titles it.
    var name: String { [label, title, titleElement].first { !$0.isEmpty } ?? "" }
    /// Everything read for the element: name and value (combined elements carry their text as value).
    var spoken: String { [name, value].filter { !$0.isEmpty }.joined(separator: ", ") }
    var all: [AXNode] { [self] + children.flatMap(\.all) }
    func first(id: String) -> AXNode? { all.first { $0.identifier == id } }
    var line: String {
        "\(role)\(subrole.isEmpty ? "" : "/\(subrole)") name=\"\(name)\" value=\"\(value)\" help=\"\(help)\" id=\(identifier)"
            + (enabled == false ? " disabled" : "") + (customActions.isEmpty ? "" : " actions=\(customActions.map(\.name))")
    }

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXTextField",
        "AXLink", "AXDisclosureTriangle", "AXComboBox", "AXIncrementor", "AXMenuItem",
    ]
    /// Scroll-bar parts are AppKit's own, named by their subrole.
    static let scrollerParts: Set<String> = ["AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]
    var isInteractive: Bool { Self.interactiveRoles.contains(role) && !Self.scrollerParts.contains(subrole) }

    /// An SF Symbol name (e.g. "arrow.clockwise") or a bare identifier is not a meaningful name.
    static func isMeaningful(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return trimmed.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#, options: .regularExpression) == nil
    }

    /// Every rule a tree must pass: named controls and images, disabled controls that say why.
    func problems() -> [String] {
        all.compactMap { node in
            if node.isInteractive, !Self.isMeaningful(node.name) { return "unlabelled control: \(node.line)" }
            if node.role == "AXImage", !Self.isMeaningful(node.name) { return "unlabelled image: \(node.line)" }
            if node.isInteractive, node.enabled == false, node.help.isEmpty, node.role != "AXSlider" {
                return "disabled without a reason: \(node.line)"
            }
            return nil
        }
    }
}

@MainActor enum AXReader {
    private static func string(_ object: NSObject, _ selector: String) -> String {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel), let value = object.perform(sel)?.takeUnretainedValue() else { return "" }
        if let text = value as? NSAttributedString { return text.string }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func bool(_ object: NSObject, _ selector: String) -> Bool? {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: sel), to: Getter.self)(object, sel)
    }

    private static func reference(_ object: NSObject, _ selector: String) -> AnyObject? {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel) else { return nil }
        return object.perform(sel)?.takeUnretainedValue()
    }

    private static func legacy(_ object: NSObject, _ attribute: NSAccessibility.Attribute) -> Any? {
        let sel = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: sel) else { return nil }
        return object.perform(sel, with: attribute.rawValue)?.takeUnretainedValue()
    }

    static func read(_ element: Any, depth: Int = 0) -> AXNode? {
        guard depth < 40, let object = element as? NSObject else { return nil }
        var node = AXNode(type: String(describing: type(of: object)))
        node.object = object
        node.role = string(object, "accessibilityRole")
        node.subrole = string(object, "accessibilitySubrole")
        node.label = string(object, "accessibilityLabel")
        node.title = string(object, "accessibilityTitle")
        node.value = string(object, "accessibilityValue")
        node.help = string(object, "accessibilityHelp")
        node.identifier = string(object, "accessibilityIdentifier")
        node.enabled = bool(object, "isAccessibilityEnabled")
        if let titled = reference(object, "accessibilityTitleUIElement") as? NSObject {
            node.titleElement = [string(titled, "accessibilityValue"), string(titled, "accessibilityLabel")]
                .first { !$0.isEmpty } ?? ""
        }
        node.customActions = reference(object, "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
        var children = reference(object, "accessibilityChildren") as? [Any] ?? []
        // List rows (NSOutlineRow) answer only the legacy attribute API, as the system's
        // accessibility server also asks it.
        if node.role.isEmpty, let legacyRole = legacy(object, .role) as? String {
            node.role = legacyRole
            children = legacy(object, .children) as? [Any] ?? children
        }
        node.children = children.compactMap { read($0, depth: depth + 1) }
        return node
    }

    /// The press VoiceOver sends (VO-Space): an accessibility action, not a mouse or key event.
    static func press(_ node: AXNode) -> Bool {
        guard let object = node.object else { return false }
        return bool(object, "accessibilityPerformPress") ?? false
    }

    static func perform(_ action: NSAccessibilityCustomAction) -> Bool {
        if let handler = action.handler { return handler() }
        if let target = action.target as? NSObject, let selector = action.selector { return target.perform(selector) != nil }
        return false
    }
}

/// Hosts a real view in an offscreen window and reads its tree. SwiftUI builds its accessibility
/// tree only while an assistive client asks for it: `AXEnhancedUserInterface` on the app (an
/// in-process attribute, as assistive apps set it; no tool is launched and nothing is written to
/// disk) makes it publish the same nodes VoiceOver reads.
@MainActor final class AXHost {
    let window: NSWindow
    let hosting: NSView

    init<V: View>(_ view: V, appearance: NSAppearance.Name, size: CGSize? = nil) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size ?? hosting.fittingSize)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        self.hosting = hosting
    }

    /// Waits, bounded, until the tree holds `until` (an identifier), then returns it.
    func tree(until identifier: String? = nil) async throws -> AXNode {
        NSApp.accessibilitySetValue(true, forAttribute: Self.enhanced)
        var node = AXNode(type: "none")
        for _ in 0..<40 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            node = AXReader.read(hosting) ?? node
            if node.all.count > 3, identifier.map({ node.first(id: $0) != nil }) ?? true { break }
        }
        return node
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        NSApp.accessibilitySetValue(false, forAttribute: Self.enhanced)
    }

    static let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
}

/// Never touches SMAppService.
private struct StubLoginBackend: LoginItemBackend {
    var status: LoginItemStatus
    func register() throws { throw CocoaError(.featureUnsupported) }
    func unregister() throws { throw CocoaError(.featureUnsupported) }
}

/// #13/#15/#104: VoiceOver reachability of the Inbox, Settings (Mascot and GitHub panes) and the
/// desktop mascot, from the real views' accessibility trees, offscreen, light and dark, in every
/// main source state. No mouse or keyboard events are sent and no assistive tool is launched.
/// What only a person with VoiceOver can confirm is listed in docs/accessibility-checklist.md.
@MainActor @Suite(.serialized) struct AccessibilityTreeTests {
    static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// A snapshot-mode model: Demo fixtures, in-memory defaults, never gh or the network.
    private func model() -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--render-snapshots", "/tmp/unused-a11y", "--placeholder"],
                                          environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "dev.github-pet.tests.a11y.\(UUID().uuidString)")
        _ = NSApplication.shared
        return AppModel(options: options, runtime: AppModel.Runtime(systemReducedMotion: { true }, schedulesTimers: false))
    }

    enum InboxState: String, CaseIterable { case loaded, empty, stale, partial, error, signedOut, ghMissing, loading, dismissed }

    private func prepare(_ state: InboxState, _ app: AppModel, _ selection: inout InboxViewSelection) {
        let items = SnapshotRenderer.inbox87Items(4)
        switch state {
        case .loaded: app.showFixtureItemsForSnapshot(items)
        case .empty: app.showFixtureItemsForSnapshot([])
        case .stale: app.showFixtureItemsForSnapshot(items); app.markStale()
        case .partial: app.showFixtureItemsForSnapshot(items); app.setPartialPolls(true)
        case .error: app.showFixtureItemsForSnapshot(items); app.simulateDisconnect()
        case .signedOut: app.showSourceFailureForSnapshot(.unauthenticated)
        case .ghMissing: app.showSourceFailureForSnapshot(.ghMissing)
        case .loading: app.showLoadingForSnapshot()
        case .dismissed:
            app.showFixtureItemsForSnapshot(items)
            if let context = app.inboxDismissalContext {
                for item in app.items.prefix(2) { app.dismissInboxItem(item.id, in: context) }
                selection.showDismissed(true, in: context)
            }
        }
    }

    private func inbox(_ app: AppModel, _ selection: InboxViewSelection = InboxViewSelection()) -> some View {
        InboxView(model: app, showsWindowButton: true, marksSeenOnClose: false, showsSimulator: true, initialSelection: selection)
    }

    @Test(arguments: InboxState.allCases, appearances)
    func inboxStateHasNamedControlsAndAnnouncesItsState(_ state: InboxState, _ appearance: NSAppearance.Name) async throws {
        let app = model()
        var selection = InboxViewSelection()
        prepare(state, app, &selection)
        let host = AXHost(inbox(app, selection), appearance: appearance)
        defer { host.close() }
        let tree = try await host.tree(until: "inbox.mascot")
        let dump = tree.all.map(\.line).joined(separator: "\n")
        #expect(tree.all.filter(\.isInteractive).count >= 5, "the real tree was read: \(dump)")
        #expect(tree.problems().isEmpty, "\(state) \(appearance.rawValue): \(tree.problems())\n\(dump)")

        // The header mascot and its badge: one image naming the count and the state.
        let mascot = try #require(tree.first(id: "inbox.mascot"), "\(dump)")
        #expect(mascot.role == "AXImage", "\(mascot.line)")
        #expect(mascot.label == app.statusAccessibilityLabel)
        let expected: [InboxState: String] = [
            .loaded: "4 items", .empty: "all clear", .stale: "stale", .partial: "some sources unavailable",
            .error: "Error", .signedOut: "Not signed in", .ghMissing: "GitHub CLI not found", .loading: "loading",
            .dismissed: "2 items",
        ]
        #expect(mascot.label.localizedCaseInsensitiveContains(expected[state]!), "\(state): \(mascot.label)")
        if let badge = app.mascotBadge?.filter(\.isNumber), !badge.isEmpty {
            #expect(mascot.label.contains(badge), "the badge's count is spoken: \(mascot.label)")
        }

        for id in ["inbox.refresh", "inbox.settings", "inbox.status", "inbox.overview.assigned", "inbox.serviceStatus"] {
            #expect(tree.first(id: id) != nil, "\(state): \(id) is reachable")
        }
        // Overview tiles read as text with their value.
        let assigned = try #require(tree.first(id: "inbox.overview.assigned"))
        #expect(assigned.role == "AXStaticText" && assigned.spoken.hasPrefix("Needs you: "), "\(assigned.line)")
        // Degraded states say so in words, never only in colour.
        let status = try #require(tree.first(id: "inbox.status"))
        #expect(status.value == app.dataState.statusText)
        switch state {
        case .partial:
            #expect(status.value.localizedCaseInsensitiveContains("partial"), "\(status.line)")
        case .stale, .error:
            #expect(tree.first(id: "inbox.lastKnown")?.spoken.contains("Showing last known items") == true, "\(state): \(dump)")
        case .empty, .loading:
            let empty = InboxEmptyState(dataState: app.dataState, allDismissed: app.allCurrentInboxItemsDismissed)
            #expect(tree.first(id: "inbox.empty")?.spoken.contains(empty.headline) == true, "\(state): \(dump)")
        case .signedOut, .ghMissing:
            let link = try #require(tree.first(id: state == .signedOut ? "ghsetup.signin" : "ghsetup.get"), "\(dump)")
            #expect(link.role == "AXLink" && !link.help.isEmpty, "\(link.line)")
            if state == .signedOut { #expect(tree.first(id: "ghsetup.copy")?.name.hasPrefix("Copy command: ") == true) }
        case .dismissed:
            let restores = tree.all.filter { $0.identifier == "inbox.restore" }
            #expect(restores.count == 2 && restores.allSatisfy { $0.name.hasPrefix("Restore ") && $0.name.count > 8 }, "\(dump)")
            #expect(tree.first(id: "inbox.backFromDismissed")?.role == "AXLink")
        case .loaded:
            break
        }
    }

    /// Each row is one button naming the title, kind and repository, with Open and Dismiss as named
    /// actions (VoiceOver's Actions rotor) plus a separate, named Dismiss button.
    @Test(arguments: appearances)
    func inboxRowsExposeTitleRepositoryKindAndNamedActions(_ appearance: NSAppearance.Name) async throws {
        let app = model()
        let items = SnapshotRenderer.inbox87Items(7)
        app.showFixtureItemsForSnapshot(items)
        let host = AXHost(inbox(app), appearance: appearance)
        defer { host.close() }
        let tree = try await host.tree(until: "inbox.dismiss")
        let dump = tree.all.map(\.line).joined(separator: "\n")
        #expect(tree.problems().isEmpty, "\(tree.problems())")
        #expect(tree.all.contains { $0.label == "Inbox items" }, "\(dump)")
        for item in app.items {
            let row = try #require(tree.all.first { $0.role == "AXButton" && $0.help == "Opens on GitHub" && $0.label.contains(item.title) },
                                   "row for \(item.title)\n\(dump)")
            #expect(row.label.contains(item.repository), "repository: \(row.label)")
            #expect(row.label.contains(item.kind.genericLabel), "kind: \(row.label)")
            let dismissible = app.canDismissInboxItem(item)
            #expect(Set(row.customActions.map(\.name)) == Set(["Open on GitHub"] + (dismissible ? ["Dismiss Here"] : [])), "\(row.line)")
            let dismiss = tree.all.first { $0.identifier == "inbox.dismiss" && $0.name == "Dismiss \(item.title)" }
            #expect((dismiss?.help == "Dismiss here (GitHub is unchanged)") == dismissible, "dismiss button for \(item.title)")
        }
        // Section headings are headings with their count.
        #expect(tree.all.filter { $0.role == "AXHeading" }.contains { $0.label.hasPrefix("Review requests, ") })
        #expect(tree.all.contains { $0.identifier == "inbox.mascot" && $0.label.contains("\(items.count) items") })
    }

    /// #148: the Waiting on others group is a collapsed disclosure whose header speaks its count and
    /// state; VoiceOver's press expands it and its rows read like other rows (quieter, never "New").
    /// The Waiting on others tile is a button that reveals the group.
    @Test(arguments: appearances)
    func waitingGroupIsADisclosureWithASpokenCountAndTheTileRevealsIt(_ appearance: NSAppearance.Name) async throws {
        for viaTile in [false, true] {
            let app = model()
            app.showFixtureItemsForSnapshot(SnapshotRenderer.inbox87Items(4))
            let waiting = app.waitingItems, unseen = app.unseenCount
            #expect(waiting.count == 3, "Demo shows waiting PRs and a deployment")
            let host = AXHost(inbox(app), appearance: appearance, size: CGSize(width: InboxView.width + 24, height: 1100))
            defer { host.close() }
            var tree = try await host.tree(until: "inbox.waiting.toggle")
            var dump = tree.all.map(\.line).joined(separator: "\n")
            #expect(tree.problems().isEmpty, "\(tree.problems())\n\(dump)")
            let header = try #require(tree.first(id: "inbox.waiting.toggle"), "\(dump)")
            #expect(header.role == "AXButton" && header.name == "Waiting on others, 3 items" && header.value == "Collapsed", "\(header.line)")
            #expect(header.help == "Expands the group", "VoiceOver's hint: \(header.line)")
            for item in waiting { #expect(!tree.all.contains { $0.label.contains(item.title) }, "collapsed by default: \(item.title)") }
            let tile = try #require(tree.first(id: "inbox.overview.waiting"), "\(dump)")
            #expect(tile.role == "AXButton" && tile.name.hasPrefix("Waiting on others: 3"), "\(tile.line)")

            #expect(AXReader.press(try #require(viaTile ? tile : header)))
            for _ in 0..<20 {
                tree = try await host.tree(until: "inbox.waiting.toggle")
                if tree.first(id: "inbox.waiting.toggle")?.value == "Expanded" { break }
            }
            dump = tree.all.map(\.line).joined(separator: "\n")
            #expect(tree.first(id: "inbox.waiting.toggle")?.value == "Expanded", "\(viaTile ? "tile" : "header") press expands: \(dump)")
            #expect(tree.problems().isEmpty, "\(tree.problems())")
            for item in waiting {
                let row = try #require(tree.all.first { $0.role == "AXButton" && $0.help == "Opens on GitHub" && $0.label.contains(item.title) },
                                       "row for \(item.title)\n\(dump)")
                #expect(!row.label.hasPrefix("New."), "waiting rows never read as new: \(row.label)")
                #expect(row.label.contains(item.attention ?? "?"), "says why it waits: \(row.label)")
                if let detail = item.detail { #expect(row.label.contains(detail) && row.help.isEmpty == false, "full reason spoken: \(row.label)") }
                let dismissible = app.canDismissInboxItem(item)
                #expect(Set(row.customActions.map(\.name)) == Set(["Open on GitHub"] + (dismissible ? ["Dismiss Here"] : [])), "\(row.line)")
            }
            #expect(tree.first(id: "inbox.waiting.toggle")?.help == "Collapses the group")
            #expect(app.badge == "4" && app.unseenCount == unseen, "expanding changes nothing that counts")
        }
    }

    /// The named Dismiss action works through accessibility alone, and the Undo it offers is a
    /// named button that brings the row back.
    @Test func dismissActionOffersANamedUndo() async throws {
        let app = model()
        app.showFixtureItemsForSnapshot(SnapshotRenderer.inbox87Items(4))
        let host = AXHost(inbox(app), appearance: .aqua)
        defer { host.close() }
        var tree = try await host.tree(until: "inbox.dismiss")
        let first = try #require(app.items.first)
        let row = try #require(tree.all.first { $0.role == "AXButton" && $0.label.contains(first.title) && !$0.customActions.isEmpty })
        let dismiss = try #require(row.customActions.first { $0.name == "Dismiss Here" })
        #expect(AXReader.perform(dismiss))
        #expect(!app.items.contains { $0.id == first.id }, "the named action dismissed the row")
        tree = try await host.tree(until: "inbox.undoDismiss")
        let undo = try #require(tree.first(id: "inbox.undoDismiss"), "\(tree.all.map(\.line).joined(separator: "\n"))")
        #expect(undo.role == "AXButton" && undo.name == "Undo dismiss \(first.title)", "\(undo.line)")
        #expect(tree.problems().isEmpty, "\(tree.problems())")
        #expect(AXReader.press(undo))
        for _ in 0..<20 where !app.items.contains(where: { $0.id == first.id }) { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(app.items.contains { $0.id == first.id }, "Undo restored the row")
    }

    // MARK: Settings

    enum SettingsCase: String, CaseIterable { case mascot, github, githubSignedOut, githubSelectedScope, mascotLoginPending }

    @Test(arguments: SettingsCase.allCases, appearances)
    func settingsPanesHaveNamedControlsAndDisabledOnesSayWhy(_ setting: SettingsCase, _ appearance: NSAppearance.Name) async throws {
        let app = model()
        app.showFixtureItemsForSnapshot(SnapshotRenderer.inbox87Items(4))
        var loginItem: LoginItemSettings?
        switch setting {
        case .githubSignedOut: app.showSourceFailureForSnapshot(.unauthenticated)
        case .githubSelectedScope: app.scopeEditor.setMode(.selected)
        case .mascotLoginPending: loginItem = LoginItemSettings(backend: StubLoginBackend(status: .notFound), openURL: { _ in })
        default: break
        }
        let pane: SettingsPane = setting.rawValue.hasPrefix("mascot") ? .mascot : .github
        // A tall host so the grouped Form lays out (and publishes) every row.
        let host = AXHost(SettingsView(model: app, pane: pane, loginItem: loginItem), appearance: appearance,
                          size: CGSize(width: 540, height: 2000))
        defer { host.close(); app.scopeEditor.cancel() }
        let tree = try await host.tree(until: pane == .mascot ? "settings.openAtLogin" : "settings.updateBeta")
        let dump = tree.all.map(\.line).joined(separator: "\n")
        #expect(tree.problems().isEmpty, "\(setting) \(appearance.rawValue): \(tree.problems())\n\(dump)")
        #expect(tree.all.filter { $0.subrole == "AXTabButton" || $0.type.contains("TabViewItem") }.allSatisfy { !$0.name.isEmpty })

        switch setting {
        case .mascot:
            let slider = try #require(tree.all.first { $0.role == "AXSlider" }, "\(dump)")
            #expect(slider.name == "Mascot size", "read once: \(slider.line)")
            #expect(tree.first(id: "settings.mascotVisible")?.name == "Show desktop pet")
            // This launch locks the picker; each card says so.
            for id in ["settings.mascotSkin.mona", "settings.mascotSkin.littleChris"] {
                let card = try #require(tree.first(id: id))
                #expect(card.role == "AXButton" && card.name.hasSuffix(" skin") && !card.value.isEmpty, "\(card.line)")
                #expect(card.enabled == false && card.help == "This launch uses the placeholder.", "\(card.line)")
            }
            // Unavailable login item: disabled, and the hint says why.
            let login = try #require(tree.first(id: "settings.openAtLogin"))
            #expect(login.name == "Open at login" && login.enabled == false, "\(login.line)")
            #expect(login.help.hasPrefix("Not available in this launch"), "\(login.line)")
        case .mascotLoginPending:
            let login = try #require(tree.first(id: "settings.openAtLogin"))
            #expect(login.enabled == false && login.help.hasPrefix("Unavailable. "), "\(login.line)")
            #expect(tree.first(id: "settings.openLoginItemsSettings")?.name == "Open Login Items Settings")
        case .github, .githubSelectedScope:
            #expect(tree.first(id: "settings.entitlementInput")?.name == "New entitlement repository, owner/name")
            #expect(tree.all.contains { $0.name == "Add entitlement repository" && $0.enabled == false && !$0.help.isEmpty })
            #expect(tree.first(id: "settings.recheck")?.name == "Recheck")
            // #137: Apply lives in the Choose Repositories sheet; Settings only summarizes.
            #expect(tree.first(id: "settings.scope.apply") == nil, "\(dump)")
            #expect(tree.first(id: "settings.scope.mode") != nil, "\(dump)")
            if setting == .githubSelectedScope {
                let choose = try #require(tree.first(id: "settings.scope.choose"), "\(dump)")
                #expect(choose.role == "AXButton" && choose.name == "Choose Repositories…" && !choose.help.isEmpty, "\(choose.line)")
                #expect(tree.all.contains { $0.role == "AXButton" && $0.name == "Add by Name…" && !$0.help.isEmpty }, "\(dump)")
            }
        case .githubSignedOut:
            let link = try #require(tree.first(id: "ghsetup.signin"), "\(dump)")
            #expect(link.name == "How to sign in" && !link.help.isEmpty)
            #expect(tree.all.contains { $0.role == "AXStaticText" && $0.value.contains("Not signed in") })
        }
    }

    // MARK: Desktop mascot

    /// The desktop pet is one button: its label carries the count and state, its art and badge are
    /// hidden, and its press opens the Inbox like a click.
    @Test(arguments: InboxState.allCases)
    func desktopMascotIsOneButtonAnnouncingCountAndState(_ state: InboxState) async throws {
        let app = model()
        var selection = InboxViewSelection()
        prepare(state, app, &selection)
        let container = MascotContainerView(frame: CGRect(x: 0, y: 0, width: 160, height: 180))
        let hosting = PassthroughHostingView(rootView: MascotView(model: app))
        hosting.frame = container.bounds
        container.addSubview(hosting)
        var opened = false
        container.onClick = { opened = true }
        container.accessibilityText = { MascotView.accessibilityLabel(app) }
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        NSApp.accessibilitySetValue(true, forAttribute: AXHost.enhanced)
        defer { window.orderOut(nil); NSApp.accessibilitySetValue(false, forAttribute: AXHost.enhanced) }
        try await Task.sleep(nanoseconds: 300_000_000)

        let node = try #require(AXReader.read(container))
        #expect(node.role == "AXButton" && node.help == "Opens the inbox", "\(node.line)")
        #expect(node.children.isEmpty, "art, DEMO and badge are not separate, unlabelled elements")
        #expect(node.label.hasPrefix(app.statusAccessibilityLabel), "\(node.label)")
        let words: [InboxState: String] = [
            .loaded: "4 items", .empty: "all clear", .stale: "stale", .partial: "some sources unavailable", .error: "Error",
            .signedOut: "Not signed in", .ghMissing: "GitHub CLI not found", .loading: "loading", .dismissed: "2 items",
        ]
        #expect(node.label.localizedCaseInsensitiveContains(words[state]!), "\(state): \(node.label)")
        #expect(app.isDemo == node.label.contains("Demo data"), "Demo is spoken whenever it is shown")
        #expect(container.accessibilityPerformPress() && opened, "VoiceOver's press opens the Inbox")
    }

    /// The audit itself catches each kind of gap, so a clean tree is not a vacuous pass.
    @Test func auditFlagsUnnamedControlsSymbolNamesUnlabelledImagesAndSilentDisabledControls() {
        var root = AXNode(type: "root", role: "AXGroup")
        root.children = [
            AXNode(type: "n", role: "AXButton"),
            AXNode(type: "n", role: "AXButton", label: "arrow.clockwise"),
            AXNode(type: "n", role: "AXImage"),
            AXNode(type: "n", role: "AXCheckBox", label: "Open at login", enabled: false),
            AXNode(type: "n", role: "AXButton", label: "Refresh"),
            AXNode(type: "n", role: "AXCheckBox", label: "Open at login", help: "Not available.", enabled: false),
            AXNode(type: "n", role: "AXButton", subrole: "AXIncrementPage"),
            AXNode(type: "n", role: "AXPopUpButton", titleElement: "Source"),
        ]
        let problems = root.problems()
        #expect(problems.count == 4, "\(problems)")
        #expect(problems.filter { $0.hasPrefix("unlabelled control") }.count == 2)
        #expect(problems.contains { $0.hasPrefix("unlabelled image") })
        #expect(problems.contains { $0.hasPrefix("disabled without a reason") })
    }

    // MARK: Keyboard

    /// What can be proven without key events: the AppKit-backed text fields are in the window's key
    /// view loop, every SwiftUI control publishes a press action, and Refresh has ⌘R. Tab order for
    /// plain SwiftUI buttons follows the system's Keyboard navigation setting and is checked by hand.
    @Test func keyboardReachabilityThatCanBeProvenOffscreen() async throws {
        let app = model()
        app.showFixtureItemsForSnapshot(SnapshotRenderer.inbox87Items(4))
        app.scopeEditor.setMode(.selected)
        let host = AXHost(SettingsView(model: app, pane: .github), appearance: .aqua, size: CGSize(width: 540, height: 2000))
        defer { host.close(); app.scopeEditor.cancel() }
        let tree = try await host.tree(until: "settings.entitlementInput")
        host.window.recalculateKeyViewLoop()
        var reached: [NSView] = []
        var view: NSView? = host.window.contentView?.nextValidKeyView
        while let current = view, !reached.contains(current), reached.count < 200 {
            reached.append(current)
            view = current.nextValidKeyView
        }
        let fields = reached.filter { $0 is NSTextField || String(describing: type(of: $0)).contains("TextField") }
        let textFieldNodes = tree.all.filter { $0.role == "AXTextField" }
        #expect(textFieldNodes.count >= 1, "the entitlement input (scope entries are added in the sheet, #137)")
        #expect(fields.count >= textFieldNodes.count, "every text field is in the key view loop: \(reached.map { type(of: $0) })")

        // ⌘R refreshes from the popover or Inbox window. There are no dialogs, so no default or
        // cancel buttons; the popover's first responder is AppKit's and is checked by hand.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/GitHubPet/InboxView.swift")
        #expect(try String(contentsOf: sources, encoding: .utf8).contains(#".keyboardShortcut("r", modifiers: .command)"#))

        let inboxHost = AXHost(inbox(app), appearance: .aqua)
        defer { inboxHost.close() }
        let inboxTree = try await inboxHost.tree(until: "inbox.refresh")
        for node in (tree.all + inboxTree.all) where node.isInteractive && node.type == "AccessibilityNode" && node.role == "AXButton" {
            let object = try #require(node.object)
            #expect(object.responds(to: NSSelectorFromString("accessibilityPerformPress")), "\(node.line) can be pressed")
        }
    }

    // MARK: Scope browser (#137)

    /// The Choose Repositories sheet on Demo fixtures: named controls, the search field's label,
    /// one checkbox element per repository carrying the whole sentence, and sidebar rows that say
    /// their state. Light and dark.
    @Test(arguments: appearances)
    func scopeBrowserSheetReadsOnceAndNamesEveryControl(_ appearance: NSAppearance.Name) async throws {
        let app = model()
        app.showFixtureItemsForSnapshot(SnapshotRenderer.inbox87Items(4))
        defer { app.scopeEditor.cancel() }
        let browser = app.makeScopeBrowser()
        browser.announce = { _ in }
        browser.sync()
        await browser.settle()
        let lumen = try #require(browser.owners.first { $0.login == "demo-lumen-labs" })
        browser.open(lumen)
        await browser.settle()
        let host = AXHost(ScopeBrowserSheet(model: app, browser: browser) {}.frame(width: 780, height: 540), appearance: appearance)
        defer { host.close() }
        let tree = try await host.tree(until: "scopeBrowser.apply")
        let dump = tree.all.map(\.line).joined(separator: "\n")
        #expect(tree.problems().isEmpty, "\(tree.problems())\n\(dump)")
        #expect(tree.all.contains { $0.role == "AXTextField" && $0.name == "Search repositories and organizations" }, "\(dump)")
        let row = try #require(tree.all.first { $0.role == "AXCheckBox" && $0.name.hasPrefix("lantern-api, demo-lumen-labs, ") },
                               "\(dump)")
        #expect(row.name.contains("pushed "), "\(row.line)")
        #expect(!tree.all.contains { $0.role == "AXStaticText" && ($0.value == "lantern-api" || $0.name == "lantern-api") },
                "the row's visible name is not read a second time")
        let all = try #require(tree.all.first { $0.role == "AXCheckBox" && $0.name.hasPrefix("All repositories in demo-lumen-labs") }, "\(dump)")
        #expect(!all.help.isEmpty)
        #expect(tree.all.contains { $0.name.hasPrefix("demo-tidewater, organization, repositories hidden by GitHub") }, "\(dump)")
        #expect(tree.all.contains { $0.role == "AXButton" && $0.name == "Add by Name…" })
        let apply = try #require(tree.first(id: "scopeBrowser.apply"))
        #expect(apply.enabled == false && apply.help.hasPrefix("No changes to apply."), "\(apply.line)")
    }
}
