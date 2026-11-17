import GitHubPetCore
import SwiftUI

/// Settings › GitHub Actions (#10): workflow failures and deployment approvals, each opt-in,
/// selected repositories only.
struct WorkflowFailuresSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("GitHub Actions") {
            Toggle("Watch workflow failures in selected repositories", isOn: $model.settings.watchWorkflowFailures)
                .accessibilityIdentifier("settings.watchWorkflowFailures")
            Toggle("Watch deployment approvals in selected repositories", isOn: $model.settings.watchDeploymentApprovals)
                .accessibilityIdentifier("settings.watchDeploymentApprovals")
            if let note = model.workflowWatchNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.workflowWatchNote")
            }
            Text("Workflow failures: GitHub Actions failures on each selected repository's default branch (its latest commit). Failures you triggered are urgent; others need attention.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Deployment approvals: runs waiting for a deployment you can approve, as GitHub reports for your account. Deployments waiting on other reviewers are only counted.")
                .font(.caption).foregroundStyle(.secondary)
            Text("A row opens the run on GitHub. GitHub Pet never approves, re-runs or changes anything.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
