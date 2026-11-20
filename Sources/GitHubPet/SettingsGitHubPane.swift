import GitHubPetCore
import SwiftUI

/// Settings › GitHub (#87): the gh connection and its error, the data sources, monitoring scope,
/// entitlement repositories and Actions. gh is the only authenticated path; nothing here reads or
/// stores a token, and nothing writes to GitHub.
struct GitHubPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            GitHubConnectionSection(model: model)
            GitHubSourcesSection(model: model)
            MonitoringScopeSection(model: model, editor: model.scopeEditor)
            EntitlementRepositoriesSection(model: model)
            WorkflowFailuresSection(model: model)
            UpdateStatusSection(updates: model.updates)
        }
        .formStyle(.grouped)
    }
}

struct GitHubConnectionSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let summary = GhConnectionSummary(state: model.dataState, source: model.settings.dataSource)
        Section("GitHub CLI") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: summary.symbol)
                    .foregroundStyle(color(summary.level)).font(.title3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title).fontWeight(.semibold)
                    Text(summary.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Recheck") { model.refresh() }
                    .accessibilityHint("Asks the GitHub CLI again and updates this status.")
                    .accessibilityIdentifier("settings.recheck")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.ghStatus")
            Picker("Source", selection: $model.settings.dataSource) {
                Text("Fixtures (offline)").tag(DataSourceMode.fixtures)
                Text("GitHub CLI (gh)").tag(DataSourceMode.githubCLI)
            }
            if let hint = model.dataState.hint, !GhSetup.links(for: model.dataState).isEmpty {
                Text("\(model.dataState.statusText). \(hint)").font(.caption.monospaced()).textSelection(.enabled)
                GhSetupView(state: model.dataState)
            }
            Text("GitHub data comes only from your installed gh CLI.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("About GitHub access") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GitHub Pet never reads or stores tokens, and never signs in by itself. Sign in with gh in Terminal.")
                    Text("With the GitHub CLI source, service incidents come from the public githubstatus.com API, without sign-in. Fixtures use demo incidents.")
                    Text("GitHub Pet is read-only: opening an item opens its page on GitHub.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ level: GhConnectionSummary.Level) -> Color {
        switch level {
        case .connected: return .green
        case .checking, .demo: return .secondary
        case .needsSetup: return .orange
        case .problem: return .red
        }
    }
}

/// What the app watches, one row per source; GitHub status incidents are a source of their own.
struct GitHubSourcesSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Sources") {
            LabeledContent("Reviews and issues") {
                Text(model.dataState.statusText).multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            LabeledContent("GitHub status incidents") {
                Text(StatusSourceSummary.line(state: model.serviceState, incidentCount: model.serviceIncidents.count,
                                              source: model.settings.dataSource))
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.statusSource")
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
            DisclosureGroup("How entitlement approvals work") {
                Text("Review requests from these repositories are shown as entitlement approvals (key icon). Opening one opens the pull request on GitHub; GitHub Pet never approves anything. The list is stored only on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        problem = model.addEntitlementRepository(input)
        if problem == nil { input = "" }
    }
}
