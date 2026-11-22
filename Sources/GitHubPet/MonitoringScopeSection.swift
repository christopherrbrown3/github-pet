import GitHubPetCore
import SwiftUI

/// Settings › Monitoring scope: the account, the Monitor choice and a read-only summary of the
/// selection. Choosing and Apply happen in the Choose Repositories sheet (#137), the one place
/// that commits a selection; "Everything accessible" applies at once, since it has nothing to
/// check. Target names appear here because opening Settings is explicit; every other surface
/// shows counts.
struct MonitoringScopeSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: ScopeEditor
    /// Offscreen renders only: a generated selection longer than today's draft accepts.
    var entriesOverride: [ScopeEntry]?
    @State private var browser: ScopeBrowser?
    @State private var browserOpensAddByName = false
    @State private var browserSnapshot: ScopeEditor.DraftSnapshot?

    static let visibleRows = 6
    static let rowHeight: CGFloat = 36

    var body: some View {
        let entries = entriesOverride ?? ScopeEntry.entries(editor)
        Section {
            LabeledContent("Account") {
                Text(editor.accountDescription).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            LabeledContent("Active") {
                Text(model.scopeSummary.replacingOccurrences(of: "Monitoring scope · ", with: ""))
                    .lineLimit(2).multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            if let quality = model.scopeQuality {
                Text(quality).font(.caption).foregroundStyle(.orange)
            }
            Picker("Monitor", selection: Binding(get: { editor.draft.mode }, set: setMode)) {
                Text("Everything accessible").tag(MonitoringScope.Mode.everything)
                Text("Selected organizations and repositories").tag(MonitoringScope.Mode.selected)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings.scope.mode")
            if editor.draft.mode == .selected {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Selected · \(entries.count)").font(.headline).monospacedDigit()
                        .accessibilityAddTraits(.isHeader)
                    if entries.isEmpty {
                        Text("Nothing selected yet. Choose repositories or add one by name.").foregroundStyle(.secondary)
                    } else {
                        ScrollingEntryList(entries: entries, rowHeight: Self.rowHeight, maximumVisibleRows: Self.visibleRows) {
                            ScopeEntryRow(entry: $0)
                        }
                        .accessibilityIdentifier("settings.scope.selected")
                    }
                }
                HStack {
                    Button("Choose Repositories…") { openBrowser() }
                        .accessibilityHint("Opens a window to browse your organizations and repositories, then Apply.")
                        .accessibilityIdentifier("settings.scope.choose")
                    Button("Add by Name…") { openBrowser(addByName: true) }
                        .accessibilityHint("For organizations or repositories GitHub doesn't list.")
                }
            }
            if editor.hasChanges && browser == nil {
                HStack {
                    Label(editor.applyBlockedReason.map { "Not applied. \($0)" } ?? "Changes not applied yet.",
                          systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Review…") { openBrowser() }
                    Button("Discard") { editor.cancel() }
                        .accessibilityHint("Discards the draft and keeps the active monitoring scope.")
                }
            }
            if let status = editor.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Monitoring scope status: \(status)")
            }
        } header: {
            Text("Monitoring scope")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if model.simulatesScope {
                    Text("Simulated/Demo: offline checks, invented accounts, temporary settings.")
                } else if editor.isDemo {
                    Text("Demo scope: stored separately from GitHub accounts and checked offline only.")
                }
                Text("Applies to requested reviews and assigned issues. Public GitHub service incidents are always shown.")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $browser) { browser in
            ScopeBrowserSheet(model: model, browser: browser, addByName: browserOpensAddByName,
                              initialSnapshot: browserSnapshot) {
                self.browser = nil; browserSnapshot = nil
            }
        }
    }

    /// Everything has nothing to verify and applies at once. Selected opens the sheet, whose
    /// Cancel returns to the previous choice.
    private func setMode(_ mode: MonitoringScope.Mode) {
        guard mode != editor.draft.mode else { return }
        if mode == .everything {
            editor.setMode(.everything)
            editor.apply()
        } else {
            let before = editor.snapshotDraft()
            editor.setMode(.selected)
            openBrowser(snapshot: before)
        }
    }

    private func openBrowser(addByName: Bool = false, snapshot: ScopeEditor.DraftSnapshot? = nil) {
        browserOpensAddByName = addByName
        browserSnapshot = snapshot
        browser = model.makeScopeBrowser()
    }
}

/// Explicit --simulate-monitoring-scope launch only: drives Settings checks offline.
struct ScopeSettingsSimulationMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu("Simulated Settings checks") {
            if let simulation = model.scopeAccessSimulation { Text(simulation.status) }
            ForEach(ScopeAccessSimulation.DiscoveryMode.allCases, id: \.self) { mode in
                Button("Discovery: \(mode.rawValue)") { model.simulateScopeDiscovery(mode) }
            }
            Divider()
            ForEach(ScopeBrowseFixture.Mode.allCases, id: \.self) { mode in
                Button("Browse: \(mode.rawValue)") { model.scopeAccessSimulation?.setBrowse(mode) }
            }
            Divider()
            Button("Validation: normal") { model.simulateScopeValidation(.normal) }
            Button("Validation: network failure") { model.simulateScopeValidation(.networkFailure) }
            Button("Hold next validation") { model.simulateScopeHoldValidation() }
            Button("Deliver held replies") { model.simulateScopeDeliver() }
        }
    }
}
