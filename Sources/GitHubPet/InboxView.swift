import GitHubPetCore
import SwiftUI

/// The shared inbox, used by the menu-bar popover and the Inbox window.
struct InboxView: View {
    @ObservedObject var model: AppModel
    var showsWindowButton = true
    /// Closing a real inbox marks its items seen; offscreen render copies must not.
    var marksSeenOnClose = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            content
            Divider()
            ServiceStatusSection(model: model)
            if let note = model.blockedLinkNote {
                Text(note).font(.caption).foregroundStyle(.red)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(minWidth: 360, idealWidth: 360)
        .onDisappear { if marksSeenOnClose { model.markAllSeen() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("GitHub Pet").font(.headline)
                if model.isDemo {
                    Text("DEMO")
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().strokeBorder(Color.secondary))
                        .accessibilityLabel("Demo data, not from GitHub")
                }
                Spacer()
                if model.settings.privacyMode {
                    // Session-only reveal (design spec); turning privacy on again re-hides.
                    Button(model.detailsRevealed ? "Hide details" : "Show details") {
                        model.detailsRevealed.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier("inbox.showDetails")
                }
                if let badge = model.badge {
                    Text(badge)
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        .accessibilityLabel(MascotPolicy.countDescription(dataState: model.dataState,
                                                                          count: model.items.count))
                }
            }
            if model.isDemo {
                Text("Demo data (fixtures): invented items, not from GitHub.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    .accessibilityIdentifier("inbox.status")
                if let last = model.lastSuccess, model.dataState != .ready, model.dataState != .empty {
                    Text("· last updated \(last.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            if let hint = model.dataState.hint {
                Text(hint).font(.caption.monospaced()).textSelection(.enabled)
            }
            if model.settings.isSnoozed(at: model.now), let until = model.settings.snoozeUntil {
                Text("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.settings.quietHours.contains(model.now) {
                Text("Quiet hours").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusIsDegraded: Bool { statusSymbol != nil }

    private var statusSymbol: String? {
        switch model.dataState {
        case .ready, .empty, .loading: return nil
        case .partial, .stale: return "exclamationmark.triangle.fill"
        case .ghMissing, .unauthenticated, .error: return "xmark.octagon.fill"
        }
    }

    /// Unknown or failed data is never rendered as an empty inbox.
    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            Text(emptyText)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
                .accessibilityIdentifier("inbox.empty")
        } else {
            let dimmed = !model.dataState.hasUsableItems || model.dataState == .stale
            if dimmed {
                Text("Showing last known items").font(.caption).foregroundStyle(.secondary)
            }
            // A ScrollView with only a max height collapses to zero inside auto-sized windows
            // and popovers (#20), and a lazy stack then realizes no rows (empty AX list).
            // Give it a real minimum height and realize every row.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.items) { item in
                        InboxRow(item: item, privacy: model.inboxPrivacy,
                                 unseen: model.isUnseen(item)) { model.open(item) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Self.listHeight(rows: model.items.count), maxHeight: Self.maxListHeight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Inbox items")
            .opacity(dimmed ? 0.55 : 1)
        }
    }

    static let rowHeight: CGFloat = 52
    static let maxListHeight: CGFloat = 360

    static func listHeight(rows: Int) -> CGFloat {
        min(CGFloat(rows) * rowHeight, maxListHeight)
    }

    private var emptyText: String {
        switch model.dataState {
        case .empty: return "All clear — nothing needs you."
        case .partial: return "No items in the sources that loaded."
        default: return "No data available yet."
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") { model.refresh() }
            Menu("Snooze") {
                ForEach(SnoozeOption.allCases, id: \.self) { option in
                    Button(option.title) { model.snooze(option) }
                }
                if model.settings.snoozeUntil != nil {
                    Divider()
                    Button("Turn off snooze") { model.cancelSnooze() }
                }
            }
            .fixedSize()
            if model.usingFixtures {
                SimulatorMenu(model: model).fixedSize()
            }
            Spacer()
            if showsWindowButton {
                Button { WindowPresenter.shared.showInbox(model: model) } label: {
                    Image(systemName: "macwindow")
                }
                .help("Open Inbox window")
            }
            Button { WindowPresenter.shared.showSettings(model: model) } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit GitHub Pet")
        }
        .controlSize(.small)
    }
}

struct InboxRow: View {
    let item: InboxItem
    let privacy: Bool
    let unseen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(unseen ? Color.accentColor : Color.clear)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                Image(systemName: icon).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PrivacyText.title(item, privacy: privacy)).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .accessibilityLabel(accessibilityText)
    }

    private var subtitle: String { PrivacyText.subtitle(item, privacy: privacy) }

    private var accessibilityText: String {
        (unseen ? "New. " : "") + PrivacyText.title(item, privacy: privacy) + ". " + subtitle
    }

    private var icon: String {
        switch item.kind {
        case .reviewRequest: return "eye"
        case .assignedIssue: return "smallcircle.filled.circle"
        case .authoredPullRequest: return "arrow.triangle.pull"
        case .ciFailure: return "xmark.octagon"
        case .entitlement: return "key"
        case .serviceIncident: return "exclamationmark.icloud"
        }
    }
}

/// GitHub Status (#11), with its own data quality. Only a fresh, verified success says there are
/// no incidents; loading, stale and failed checks say so and keep last-known incidents dimmed.
struct ServiceStatusSection: View {
    @ObservedObject var model: AppModel
    static let maxRows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).symbolRenderingMode(.multicolor).accessibilityHidden(true)
                }
                Text(model.serviceState.statusText(count: model.serviceIncidents.count))
                    .foregroundStyle(degraded ? .primary : .secondary)
                    .fontWeight(degraded ? .semibold : .regular)
                    .accessibilityIdentifier("inbox.serviceStatus")
                if let last = model.serviceLastSuccess, !model.serviceState.isFresh {
                    Text("· last checked \(last.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            if !model.serviceIncidents.isEmpty {
                let dimmed = !model.serviceState.isFresh
                if dimmed {
                    Text("Showing last known incidents").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    // Most severe first; the rest are counted so the popover stays a fixed size.
                    ForEach(model.serviceIncidents.prefix(Self.maxRows)) { incident in
                        IncidentRow(incident: incident, privacy: model.inboxPrivacy,
                                    unseen: model.isUnseen(incident)) { model.open(incident) }
                    }
                    if model.serviceIncidents.count > Self.maxRows {
                        Text("and \(model.serviceIncidents.count - Self.maxRows) more")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("GitHub service incidents")
                .opacity(dimmed ? 0.55 : 1)
            }
        }
    }

    private var degraded: Bool { symbol != nil }

    private var symbol: String? {
        switch model.serviceState {
        case .loading, .operational: return nil
        case .incidents, .stale: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct IncidentRow: View {
    let incident: ServiceIncident
    let privacy: Bool
    let unseen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(unseen ? Color.accentColor : Color.clear)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                Image(systemName: "exclamationmark.icloud").frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PrivacyText.title(item, privacy: privacy)).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Demo incidents have no status page: shown, but they open nothing.
        .disabled(incident.isDemo)
        .padding(.vertical, 3)
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
