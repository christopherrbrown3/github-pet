import GitHubPetCore
import SwiftUI

/// Settings (#87): compact native panes. Every control from the former long scroll lives in
/// exactly one pane: Mascot (pet, skin, size, motion, startup), Alerts (snooze, quiet hours,
/// privacy, review filter) and GitHub (CLI connection, sources, scope, Actions). While snooze,
/// quiet hours and privacy are all hidden (#94, #95, #107) there is no Alerts tab, and the review
/// filter, its only remaining control, sits in the GitHub pane.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var pane: SettingsPane
    /// Render checks only: a stand-in for the system login item.
    private let loginItem: LoginItemSettings
    static let minHeight: CGFloat = 660

    init(model: AppModel, pane: SettingsPane = .mascot, loginItem: LoginItemSettings? = nil) {
        self.model = model
        self.loginItem = loginItem ?? model.loginItem
        _pane = State(initialValue: Self.visiblePane(pane, features: model.features))
    }

    /// A hidden pane can't be selected: Alerts opens the GitHub pane, which then holds its review filter.
    static func visiblePane(_ pane: SettingsPane, features: FeatureSet) -> SettingsPane {
        guard !features.settingsPanes.contains(pane) else { return pane }
        return pane == .alerts ? .github : .mascot
    }

    var body: some View {
        TabView(selection: $pane) {
            MascotPane(model: model, loginItem: loginItem)
                .tabItem { Label(SettingsPane.mascot.title, systemImage: SettingsPane.mascot.symbol) }
                .tag(SettingsPane.mascot)
            if model.features.showsAlertsPane {
                AlertsPane(model: model)
                    .tabItem { Label(SettingsPane.alerts.title, systemImage: SettingsPane.alerts.symbol) }
                    .tag(SettingsPane.alerts)
            }
            GitHubPane(model: model)
                .tabItem { Label(SettingsPane.github.title, systemImage: SettingsPane.github.symbol) }
                .tag(SettingsPane.github)
        }
        // A grouped Form scrolls, so it reports almost no height of its own and the hosting
        // window opened as a bare title bar (QA, 3cf6fa7). Give it a real height to size to.
        .frame(width: 520)
        .frame(minHeight: Self.minHeight)
        .padding(.vertical, 8)
    }
}

// MARK: - Mascot

struct MascotPane: View {
    @ObservedObject var model: AppModel
    let loginItem: LoginItemSettings

    var body: some View {
        Form {
            Section {
                Toggle("Show desktop pet", isOn: $model.settings.mascotVisible)
                    .accessibilityIdentifier("settings.mascotVisible")
                Text("Hiding the pet only hides the character. Monitoring, the inbox and the menu-bar icon keep working.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            MascotSkinSection(model: model)
            Section("Size and motion") {
                HStack {
                    Text("Size")
                    Spacer()
                    Text("\(Int(model.settings.mascotSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 2) {
                    // Labelled for VoiceOver: the sibling "Size" text doesn't label the control.
                    Slider(value: $model.settings.mascotSize, in: PetSettings.mascotSizeRange, step: 16) {
                        Text("Mascot size")
                    }
                    .labelsHidden()
                    .accessibilityLabel("Mascot size")
                    .accessibilityValue("\(Int(model.settings.mascotSize)) points")
                    HStack {
                        Text("Small"); Spacer(); Text("Large")
                    }
                    .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Button("Reset position") {
                    model.settings.mascotOriginX = nil
                    model.settings.mascotOriginY = nil
                }
                Toggle("Reduce motion", isOn: $model.settings.reducedMotion)
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    Text("macOS Reduce Motion is on, so the mascot stays still.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LoginItemSection(settings: loginItem)
        }
        .formStyle(.grouped)
    }
}

/// Skin cards: the real bundled frames (never a redraw) at the chosen size's proportions, with
/// the same blue count capsule the desktop pet wears.
struct MascotSkinSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Choose a mascot") {
            HStack(spacing: 12) {
                ForEach(MascotSkin.allCases, id: \.self) { skin in
                    SkinCard(model: model, skin: skin)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.mascotSkin")
            if let notice = model.mascotArtwork.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if !model.mascotArtwork.errors.isEmpty {
                Text(model.mascotArtwork.errors.map(\.description).joined(separator: "\n"))
                    .font(.caption)
            }
            Text("The count badge is a preview. It shows your real unread count on the desktop pet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SkinCard: View {
    @ObservedObject var model: AppModel
    let skin: MascotSkin
    private static let art: CGFloat = 96

    private var selected: Bool { model.settings.mascotSkin == skin }
    private var locked: Bool { model.mascotArtwork.locksPicker }

    var body: some View {
        let artwork = model.artwork(for: skin)
        let layout = model.layout(model.settings.mascotSize)
        // Badge proportions follow the chosen size relative to the art, so the card shows how a
        // count reads at this size.
        let scale = Self.art / layout.artSide
        let badge = model.mascotBadge ?? "4"
        Button {
            model.settings.mascotSkin = skin
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    figure(artwork)
                        .frame(width: Self.art, height: Self.art)
                    Tag(text: badge, role: .count, metrics: layout.count)
                        .scaleEffect(max(scale, 0.75), anchor: .topTrailing)
                        .offset(x: 6, y: -2)
                }
                .frame(width: Self.art + 12, height: Self.art)
                HStack(spacing: 4) {
                    Text(skin.name).fontWeight(.semibold)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel("\(skin.name) skin")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.mascotSkin.\(skin == .mona ? "mona" : "littleChris")")
    }

    @ViewBuilder private func figure(_ artwork: MascotArtwork) -> some View {
        let pose = MascotPose(state: .idle, frame: 0, clipElapsed: nil)
        if let pack = artwork.pack {
            PackFigure(pack: pack, pose: pose)
        } else {
            PlaceholderFigure(pose: pose, date: Date(timeIntervalSinceReferenceDate: 0), reduced: true)
        }
    }
}

/// Reads the system state when shown and when the app becomes active (the user may approve or
/// remove the item in System Settings meanwhile); only flipping the toggle changes it.
struct LoginItemSection: View {
    @ObservedObject var settings: LoginItemSettings

    var body: some View {
        Section("Startup") {
            Toggle("Open at login", isOn: Binding(get: { settings.isOn }, set: { settings.setEnabled($0) }))
                .disabled(!settings.isAvailable || settings.status == nil)
                .accessibilityValue(Text(verbatim: settings.summary))
                .accessibilityIdentifier("settings.openAtLogin")
            Text(settings.summary)
                .font(.caption).foregroundStyle(settings.failure == nil ? .secondary : Color.orange)
                .accessibilityIdentifier("settings.openAtLoginStatus")
        }
        .onAppear { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }
}

// MARK: - Alerts

struct AlertsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let features = model.features
        let state = AlertSuppression(model.settings, at: model.now, features: features)
        Form {
            if features.snooze { // #95: the one switch for snooze entry points
            Section("Snooze") {
                HStack {
                    Image(systemName: state.isSnoozed ? "bell.slash.fill" : "bell")
                        .foregroundStyle(state.isSnoozed ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                    Text(state.snoozeLine).fontWeight(.medium)
                        .accessibilityIdentifier("settings.snoozeState")
                    Spacer()
                    if state.isSnoozed {
                        Button("Turn off") { model.cancelSnooze() }
                    }
                }
                if !state.isSnoozed {
                    HStack {
                        ForEach(SnoozeOption.allCases, id: \.self) { option in
                            Button(option.title) { model.snooze(option) }
                        }
                    }
                }
            }
            }
            if features.quietHours { // #107: the one switch for quiet-hours entry points
            Section("Quiet hours") {
                Toggle("Quiet hours", isOn: $model.settings.quietHours.enabled)
                HStack {
                    DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("to", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                }
                .disabled(!model.settings.quietHours.enabled)
                Text(state.quietHoursLine).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.quietHoursState")
            }
            }
            if features.snooze || features.quietHours {
            Section {
                Label(AlertSuppression.explanation, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.suppressionNote")
            }
            }
            if features.privacyMode { // #94: the one switch for privacy-mode entry points
                Section("Privacy") {
                    Toggle("Privacy mode (hide repository names and titles)", isOn: $model.settings.privacyMode)
                        .accessibilityIdentifier("settings.privacyMode")
                }
            }
            AssignmentModeSection(model: model)
        }
        .formStyle(.grouped)
    }

    /// Bridges a minutes-since-midnight field to a time-only `Date` in the local time zone.
    private func minuteBinding(_ keyPath: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding {
            // Set the wall-clock hour and minute directly; adding seconds to midnight would be
            // off by an hour on daylight-saving transition days.
            let minute = model.settings.quietHours[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                                         of: model.now) ?? model.now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.settings.quietHours[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }
}

struct AssignmentModeSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Review requests") {
            Picker("Assignment filter", selection: $model.settings.assignmentMode) {
                Text("Show all notifications").tag(AssignmentMode.all)
                Text("Show only assigned to @me").tag(AssignmentMode.direct)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings.assignmentMode")
            Text("All includes pull request reviews requested from you or your teams. The @me option includes reviews requested directly from you. Both show issues assigned to you.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
