import GitHubPetCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Mascot") {
                Toggle("Show mascot", isOn: $model.settings.mascotVisible)
                    .accessibilityIdentifier("settings.mascotVisible")
                HStack {
                    Text("Size")
                    Slider(value: $model.settings.mascotSize, in: PetSettings.mascotSizeRange, step: 16)
                    Text("\(Int(model.settings.mascotSize)) pt").monospacedDigit().frame(width: 52)
                }
                Button("Reset position") {
                    model.settings.mascotOriginX = nil
                    model.settings.mascotOriginY = nil
                }
                if !model.packErrors.isEmpty {
                    Text("Mascot pack rejected, using placeholder: "
                         + model.packErrors.map(\.description).joined(separator: "; "))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Privacy and motion") {
                Toggle("Privacy mode (hide repository names and titles)", isOn: $model.settings.privacyMode)
                Toggle("Reduce motion", isOn: $model.settings.reducedMotion)
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    Text("macOS Reduce Motion is on, so the mascot stays still.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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
            Section("Data source") {
                Picker("Source", selection: $model.settings.dataSource) {
                    Text("Fixtures (offline)").tag(DataSourceMode.fixtures)
                    Text("GitHub CLI (gh)").tag(DataSourceMode.githubCLI)
                }
                Text("GitHub data comes only from your installed gh CLI. GitHub Pet never reads or stores tokens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }

    /// Bridges a minutes-since-midnight field to a time-only `Date` in the local time zone.
    private func minuteBinding(_ keyPath: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding {
            let start = Calendar.current.startOfDay(for: Date())
            return start.addingTimeInterval(TimeInterval(model.settings.quietHours[keyPath: keyPath] * 60))
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.settings.quietHours[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }
}
