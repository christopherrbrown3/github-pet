import GitHubPetCore
import SwiftUI

/// Settings › Workflow failures (#10): opt-in, selected repositories only.
struct WorkflowFailuresSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Workflow failures") {
            Toggle("Watch workflow failures in selected repositories", isOn: $model.settings.watchWorkflowFailures)
                .accessibilityIdentifier("settings.watchWorkflowFailures")
            if let note = model.workflowWatchNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.workflowWatchNote")
            }
            Text("GitHub Actions failures on each selected repository's default branch (its latest commit). Failures you triggered are urgent; others need attention. A row opens the run on GitHub; nothing is re-run or changed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
