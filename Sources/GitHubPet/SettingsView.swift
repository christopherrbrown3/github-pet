import GitHubPetCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    static let minHeight: CGFloat = 660

    var body: some View {
        Form {
            MascotSettingsSection(model: model)
            LoginItemSection(settings: model.loginItem)
            PrivacyMotionSection(model: model)
            SnoozeQuietHoursSection(model: model)
            DataSourceSection(model: model)
            MonitoringScopeSection(model: model, editor: model.scopeEditor)
            AssignmentModeSection(model: model)
            EntitlementRepositoriesSection(model: model)
            WorkflowFailuresSection(model: model)
            UpdateStatusSection(updates: model.updates)
        }
        .formStyle(.grouped)
        // A grouped Form scrolls, so it reports almost no height of its own and the hosting
        // window opened as a bare title bar (QA, 3cf6fa7). Give it a real height to size to.
        .frame(width: 520)
        .frame(minHeight: Self.minHeight)
        .padding(.vertical, 8)
    }
}

struct AssignmentModeSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Notifications") {
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

struct MascotSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Mascot") {
            Toggle("Show mascot", isOn: $model.settings.mascotVisible)
                .accessibilityIdentifier("settings.mascotVisible")
            Picker("Skin", selection: $model.settings.mascotSkin) {
                ForEach(MascotSkin.allCases, id: \.self) { skin in
                    Text(skin.name).tag(skin)
                }
            }
            .disabled(model.mascotArtwork.locksPicker)
            .accessibilityIdentifier("settings.mascotSkin")
            HStack {
                Text("Size")
                // Labelled for VoiceOver: the sibling "Size" text doesn't label the control.
                Slider(value: $model.settings.mascotSize, in: PetSettings.mascotSizeRange, step: 16) {
                    Text("Mascot size")
                }
                .labelsHidden()
                .accessibilityLabel("Mascot size")
                .accessibilityValue("\(Int(model.settings.mascotSize)) points")
                Text("\(Int(model.settings.mascotSize)) pt").monospacedDigit().frame(width: 52)
            }
            Button("Reset position") {
                model.settings.mascotOriginX = nil
                model.settings.mascotOriginY = nil
            }
            if let notice = model.mascotArtwork.notice {
                Text(notice)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.mascotArtwork.errors.isEmpty {
                Text(model.mascotArtwork.errors.map(\.description).joined(separator: "\n"))
                    .font(.caption)
            }
        }
    }
}

struct PrivacyMotionSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Privacy and motion") {
            Toggle("Privacy mode (hide repository names and titles)", isOn: $model.settings.privacyMode)
            Toggle("Reduce motion", isOn: $model.settings.reducedMotion)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                Text("macOS Reduce Motion is on, so the mascot stays still.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SnoozeQuietHoursSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Snooze and quiet hours") {
            HStack {
                if model.settings.isSnoozed(at: model.now), let until = model.settings.snoozeUntil {
                    Text("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    Button("Turn off") { model.cancelSnooze() }
                } else {
                    Text("Not snoozed")
                    Spacer()
                    ForEach(SnoozeOption.allCases, id: \.self) { option in
                        Button(option.title) { model.snooze(option) }
                    }
                }
            }
            Toggle("Quiet hours", isOn: $model.settings.quietHours.enabled)
            HStack {
                DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("to", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
            }
            .disabled(!model.settings.quietHours.enabled)
            Text("While snoozed or in quiet hours the inbox keeps updating, but the mascot and menu-bar icon stay calm.")
                .font(.caption).foregroundStyle(.secondary)
        }
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

struct DataSourceSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Data source") {
            Picker("Source", selection: $model.settings.dataSource) {
                Text("Fixtures (offline)").tag(DataSourceMode.fixtures)
                Text("GitHub CLI (gh)").tag(DataSourceMode.githubCLI)
            }
            if let hint = model.dataState.hint, !GhSetup.links(for: model.dataState).isEmpty {
                Text("\(model.dataState.statusText). \(hint)").font(.caption.monospaced()).textSelection(.enabled)
                GhSetupView(state: model.dataState)
            }
            Text("GitHub data comes only from your installed gh CLI. GitHub Pet never reads or stores tokens.")
                .font(.caption).foregroundStyle(.secondary)
            Text("With the GitHub CLI source, service incidents come from the public githubstatus.com API, without sign-in. Fixtures use demo incidents.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// #8: review requests from these repositories show as entitlement approvals. Local only.
struct EntitlementRepositoriesSection: View {
    @ObservedObject var model: AppModel
    @State private var input = ""
    @State private var problem: EntitlementRepositories.Problem?

    var body: some View {
        Section("Entitlement approvals") {
            ForEach(model.settings.entitlementRepositories, id: \.self) { repository in
                HStack {
                    Image(systemName: "key").accessibilityHidden(true)
                    Text(repository)
                    Spacer()
                    Button("Remove") { model.removeEntitlementRepository(repository) }
                        .accessibilityLabel("Remove \(repository)")
                }
            }
            HStack {
                TextField("owner/name", text: $input)
                    .onSubmit(add)
                    .onChange(of: input) { _ in problem = nil }
                    .accessibilityIdentifier("settings.entitlementInput")
                Button("Add", action: add).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                Text(problem.message).font(.caption).foregroundStyle(.orange)
            }
            Text("Review requests from these repositories are shown as entitlement approvals (key icon). Opening one opens the pull request on GitHub; GitHub Pet never approves anything. The list is stored only on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        problem = model.addEntitlementRepository(input)
        if problem == nil { input = "" }
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
