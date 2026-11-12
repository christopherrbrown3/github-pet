import GitHubPetCore
import SwiftUI

/// The shared inbox, used by the menu-bar popover and the Inbox window.
struct InboxView: View {
    @ObservedObject var model: AppModel
    var showsWindowButton = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            content
            if let note = model.blockedLinkNote {
                Text(note).font(.caption).foregroundStyle(.red)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(minWidth: 340, idealWidth: 360)
        .onDisappear { model.markAllSeen() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("GitHub Pet").font(.headline)
                Spacer()
                if let badge = model.badge {
                    Text(badge)
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        .accessibilityLabel("\(badge) items")
                }
            }
            HStack(spacing: 6) {
                Text(model.dataState.statusText)
                    .foregroundStyle(statusColor)
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

    private var statusColor: Color {
        switch model.dataState {
        case .ready, .empty: return .secondary
        case .loading: return .secondary
        case .partial, .stale: return .orange
        case .ghMissing, .unauthenticated, .error: return .red
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.items) { item in
                        InboxRow(item: item, privacy: model.settings.privacyMode,
                                 unseen: model.isUnseen(item)) { model.open(item) }
                    }
                }
            }
            .frame(maxHeight: 320)
            .opacity(dimmed ? 0.55 : 1)
        }
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

    private var subtitle: String {
        if let repo = PrivacyText.repository(item, privacy: privacy) {
            return "\(item.kind.genericLabel) · \(repo)"
        }
        return item.kind.genericLabel
    }

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
        }
    }
}

struct SimulatorMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu("Simulator") {
            Button("Inject entitlement event") { model.injectEntitlementEvent() }
            Button("Replay current snapshot") { model.replaySnapshot() }
            Button("Next poll: partial") { model.nextPollPartial() }
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
