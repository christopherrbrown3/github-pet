import GitHubPetCore
import SwiftUI

/// Settings › Monitoring scope: native grouped-Form controls only. Target names appear here
/// because opening Settings is explicit; every other surface shows counts.
struct MonitoringScopeSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: ScopeEditor

    var body: some View {
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
            Picker("Monitor", selection: Binding(get: { editor.draft.mode }, set: { editor.setMode($0) })) {
                Text("Everything accessible").tag(MonitoringScope.Mode.everything)
                Text("Selected organizations and repositories").tag(MonitoringScope.Mode.selected)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings.scope.mode")
            if editor.draft.mode == .selected {
                TargetListEditor(editor: editor, kind: .organization)
                TargetListEditor(editor: editor, kind: .repository)
                suggestions
            }
            if let reason = editor.applyBlockedReason, editor.hasChanges || editor.identity == nil {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if let status = editor.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Monitoring scope status: \(status)")
            }
            HStack {
                if editor.phase == .validating { ProgressView().controlSize(.small).accessibilityLabel("Checking access") }
                Spacer()
                Button("Cancel") { editor.cancel() }
                    .disabled(!editor.hasChanges && editor.phase == .idle)
                    .accessibilityHint("Discards the draft and keeps the active monitoring scope.")
                Button("Apply") { editor.apply() }
                    .disabled(!editor.canApply)
                    .accessibilityHint("Checks access to every entry, then applies the scope.")
                    .accessibilityIdentifier("settings.scope.apply")
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
    }

    @ViewBuilder private var suggestions: some View {
        let lists = editor.suggestions
        HStack {
            Button("Find suggestions") { editor.loadSuggestions() }
                .disabled(!editor.canLoadSuggestions)
                .accessibilityHint("Asks the GitHub CLI for organizations and repositories you belong to. Typed entries work without it.")
            Menu("Organizations") {
                ForEach(lists.organizations, id: \.self) { value in
                    Button(value) { editor.useSuggestion(value, kind: .organization) }
                }
            }
            .disabled(lists.organizations.isEmpty)
            .accessibilityLabel("Organization suggestions, \(lists.organizations.count)")
            Menu("Repositories") {
                ForEach(lists.repositories, id: \.self) { value in
                    Button(value) { editor.useSuggestion(value, kind: .repository) }
                }
            }
            .disabled(lists.repositories.isEmpty)
            .accessibilityLabel("Repository suggestions, \(lists.repositories.count)")
            .fixedSize()
        }
        Text(editor.discoveryText).font(.caption).foregroundStyle(.secondary)
    }
}

/// One bounded list (at most 10 combined entries) with editable rows, inline errors and typed Add.
private struct TargetListEditor: View {
    @ObservedObject var editor: ScopeEditor
    let kind: MonitoringTarget.Kind

    private var noun: String { kind == .organization ? "Organization" : "Repository" }
    private var prompt: String { kind == .organization ? "login" : "owner/name" }

    var body: some View {
        let rows = editor.draft.rows(kind)
        VStack(alignment: .leading, spacing: 6) {
            Text(kind == .organization ? "Organizations" : "Repositories").font(.headline)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                let problem = editor.problem(row)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        TextField("\(noun) \(position + 1)", text: Binding(get: { row.text }, set: { editor.update(row.id, text: $0) }),
                                  prompt: Text(prompt))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("\(noun) \(position + 1)")
                            .accessibilityHint(problem?.message(for: kind) ?? "")
                        Button("Remove") { editor.remove(row.id) }
                            .accessibilityLabel("Remove \(noun.lowercased()) \(row.text)")
                    }
                    if let problem {
                        Label(problem.message(for: kind), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                            .accessibilityLabel("\(noun) \(position + 1) error: \(problem.message(for: kind))")
                    }
                }
            }
            let input = kind == .organization ? $editor.organizationInput : $editor.repositoryInput
            let inputProblem = kind == .organization ? editor.organizationInputProblem : editor.repositoryInputProblem
            HStack {
                TextField("Add \(noun.lowercased())", text: input, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { kind == .organization ? editor.addOrganization() : editor.addRepository() }
                    .accessibilityLabel("New \(noun.lowercased()), \(prompt)")
                    .accessibilityHint(inputProblem?.message(for: kind) ?? "Press Return or Add to put it in the draft.")
                Button("Add") { kind == .organization ? editor.addOrganization() : editor.addRepository() }
                    .accessibilityLabel("Add \(noun.lowercased())")
            }
            if let inputProblem {
                Label(inputProblem.message(for: kind), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityLabel("New \(noun.lowercased()) error: \(inputProblem.message(for: kind))")
            }
        }
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
            Button("Validation: normal") { model.simulateScopeValidation(.normal) }
            Button("Validation: network failure") { model.simulateScopeValidation(.networkFailure) }
            Button("Hold next validation") { model.simulateScopeHoldValidation() }
            Button("Deliver held replies") { model.simulateScopeDeliver() }
        }
    }
}
