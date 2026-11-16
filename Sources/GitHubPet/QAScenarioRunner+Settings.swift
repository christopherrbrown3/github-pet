import AppKit
import GitHubPetCore
import SwiftUI

/// PR B runner steps: each calls the same `ScopeEditor` method the Settings control does
/// (typed field + Add/Return, row field, Remove, mode radio, Apply, Cancel, Find suggestions,
/// suggestion menu item) or the Simulated Settings checks menu item.
extension QAScenarioRunner {
    private static let kinds = ["organization", "repository"]
    private static func kind(_ c: Context) throws -> MonitoringTarget.Kind {
        try c.string("kind", kinds) == "organization" ? .organization : .repository
    }
    /// Any text up to 200 characters: injection-shaped input is exactly what QA types.
    private static func text(_ c: Context) throws -> String {
        guard let value = c.step.params["text"] as? String, value.utf16.count <= 200 else {
            throw HarnessError(description: "\(c.step.action): \"text\" must be a string of at most 200 characters")
        }
        return value
    }
    /// 1-based position within the chosen list, as shown in Settings ("Organization 2").
    private static func row(_ c: Context) throws -> ScopeDraftRow {
        let position = Int(try c.number("index", 1...10))
        let rows = c.model.scopeEditor.draft.rows(try kind(c))
        guard rows.indices.contains(position - 1) else {
            throw HarnessError(description: "\(c.step.action): no \(try c.string("kind", kinds)) row \(position) (has \(rows.count))")
        }
        return rows[position - 1]
    }

    static let settingsActions: [String: Action] = [
        "settings-mode": Action(keys: ["mode"], validate: { _ = try $0.string("mode", ["everything", "selected"]) }) { c in
            c.model.scopeEditor.setMode(try c.string("mode", ["everything", "selected"]) == "selected" ? .selected : .everything)
        },
        "settings-add": Action(keys: ["kind", "text"], validate: { c in _ = try kind(c); _ = try text(c) }) { c in
            let editor = c.model.scopeEditor
            if try kind(c) == .organization { editor.organizationInput = try text(c); editor.addOrganization() }
            else { editor.repositoryInput = try text(c); editor.addRepository() }
        },
        "settings-edit": Action(keys: ["kind", "index", "text"], validate: { c in
            _ = try kind(c); _ = try c.number("index", 1...10); _ = try text(c)
        }) { c in c.model.scopeEditor.update(try row(c).id, text: try text(c)) },
        "settings-remove": Action(keys: ["kind", "index"], validate: { c in _ = try kind(c); _ = try c.number("index", 1...10) }) { c in
            c.model.scopeEditor.remove(try row(c).id)
        },
        "settings-apply": Action { c in c.model.scopeEditor.apply() },
        "settings-cancel": Action { c in c.model.scopeEditor.cancel() },
        "settings-find-suggestions": Action { c in c.model.scopeEditor.loadSuggestions() },
        "settings-use-suggestion": Action(keys: ["kind", "index"], validate: { c in _ = try kind(c); _ = try c.number("index", 1...150) }) { c in
            let kind = try kind(c), position = Int(try c.number("index", 1...150))
            let list = kind == .organization ? c.model.scopeEditor.suggestions.organizations : c.model.scopeEditor.suggestions.repositories
            guard list.indices.contains(position - 1) else {
                throw HarnessError(description: "settings-use-suggestion: no suggestion \(position) (has \(list.count))")
            }
            c.model.scopeEditor.useSuggestion(list[position - 1], kind: kind)
        },
        "discovery-mode": Action(keys: ["mode"], validate: {
            _ = try $0.string("mode", ScopeAccessSimulation.DiscoveryMode.allCases.map(\.rawValue))
        }) { c in
            c.model.simulateScopeDiscovery(ScopeAccessSimulation.DiscoveryMode(rawValue: try c.string("mode", ScopeAccessSimulation.DiscoveryMode.allCases.map(\.rawValue)))!)
        },
        "validation-mode": Action(keys: ["mode"], validate: {
            _ = try $0.string("mode", ScopeAccessSimulation.ValidationMode.allCases.map(\.rawValue))
        }) { c in
            c.model.simulateScopeValidation(ScopeAccessSimulation.ValidationMode(rawValue: try c.string("mode", ScopeAccessSimulation.ValidationMode.allCases.map(\.rawValue)))!)
        },
        "hold-validation": Action { c in c.model.simulateScopeHoldValidation() },
        /// The Monitoring scope section scrolled into view inside the same grouped Form, plus the
        /// whole Settings window at its minimum size (whose Form scrolls rather than growing).
        "open-scope-settings": Action { c in
            guard c.plan!.rendersPNGs else { return }
            let model = c.model!
            c.renders += await SnapshotRenderer.render(SettingsView(model: model), name: stem(c) + "-settings",
                                                       directory: c.plan!.output, appearance: .aqua, asWindow: true)
            c.renders += await SnapshotRenderer.render(
                Form { MonitoringScopeSection(model: model, editor: model.scopeEditor) }.formStyle(.grouped).frame(width: 520),
                name: stem(c) + "-scope-section", directory: c.plan!.output, appearance: .aqua)
        },
    ]

    /// What Settings › Monitoring scope shows (names appear only here, as in the app).
    static func settingsSnapshot(_ model: AppModel) -> Any {
        let editor = model.scopeEditor
        guard let data = try? JSONEncoder().encode(editor.snapshot),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return NSNull() }
        object["cancelEnabled"] = editor.hasChanges || editor.phase != .idle
        object["findSuggestionsEnabled"] = editor.canLoadSuggestions
        object["checksLaunched"] = editor.launchedChecks
        object["checksReceived"] = editor.receivedChecks
        object["simulatedChecks"] = model.scopeAccessSimulation?.status ?? NSNull()
        return object
    }

    static let settingsScenarios: [String: String] = [
        "settings-draft-apply-cancel": #"""
        {"name": "settings-draft-apply-cancel", "steps": [
          {"action": "settings-add", "kind": "organization", "text": "demo-b", "label": "draft-add-org"},
          {"action": "settings-add", "kind": "repository", "text": "demo-c/tools", "label": "draft-add-repo"},
          {"action": "settings-cancel", "label": "cancel-restores-active"},
          {"action": "settings-add", "kind": "organization", "text": "demo-b", "label": "draft-again-org"},
          {"action": "settings-add", "kind": "repository", "text": "demo-c/tools", "label": "draft-again-repo"},
          {"action": "settings-apply", "label": "apply-validated"},
          {"action": "settings-mode", "mode": "everything", "label": "draft-everything"},
          {"action": "settings-apply", "label": "apply-everything"},
          {"action": "open-scope-settings", "label": "settings-after-apply"}]}
        """#,
        "settings-invalid-input": #"""
        {"name": "settings-invalid-input", "steps": [
          {"action": "settings-add", "kind": "organization", "text": "org:demo is:pr", "label": "org-qualifier"},
          {"action": "settings-add", "kind": "organization", "text": "de mo", "label": "org-space"},
          {"action": "settings-add", "kind": "organization", "text": "demo\"){viewer{id}}", "label": "org-graphql"},
          {"action": "settings-add", "kind": "repository", "text": "demo/pet repo:other/x", "label": "repo-qualifier"},
          {"action": "settings-add", "kind": "repository", "text": "a/b/c", "label": "repo-extra-slash"},
          {"action": "settings-add", "kind": "organization", "text": "  Demo-B  ", "label": "org-trimmed"},
          {"action": "settings-add", "kind": "organization", "text": "DEMO-b", "label": "org-duplicate"},
          {"action": "settings-edit", "kind": "organization", "index": 2, "text": "demo b", "label": "edit-row-invalid"},
          {"action": "settings-apply", "label": "apply-blocked"},
          {"action": "settings-remove", "kind": "organization", "index": 2, "label": "remove-invalid-row"},
          {"action": "open-scope-settings", "label": "settings-clean-draft"}]}
        """#,
        "settings-max-10": #"""
        {"name": "settings-max-10", "steps": [
          {"action": "settings-add", "kind": "organization", "text": "demo-b", "label": "add-2"},
          {"action": "settings-add", "kind": "organization", "text": "demo-c", "label": "add-3"},
          {"action": "settings-add", "kind": "organization", "text": "demo-d", "label": "add-4"},
          {"action": "settings-add", "kind": "organization", "text": "demo-e", "label": "add-5"},
          {"action": "settings-add", "kind": "repository", "text": "demo-x/one", "label": "add-6"},
          {"action": "settings-add", "kind": "repository", "text": "demo-x/two", "label": "add-7"},
          {"action": "settings-add", "kind": "repository", "text": "demo-x/three", "label": "add-8"},
          {"action": "settings-add", "kind": "repository", "text": "demo-x/four", "label": "add-9"},
          {"action": "settings-add", "kind": "repository", "text": "demo-x/five", "label": "add-10"},
          {"action": "settings-add", "kind": "repository", "text": "demo-x/six", "label": "add-11-rejected"},
          {"action": "settings-apply", "label": "apply-ten"},
          {"action": "open-scope-settings", "label": "settings-ten"}]}
        """#,
        "settings-discovery-capped": #"""
        {"name": "settings-discovery-capped", "steps": [
          {"action": "discovery-mode", "mode": "capped", "label": "discovery-capped"},
          {"action": "settings-find-suggestions", "label": "find-capped"},
          {"action": "settings-use-suggestion", "kind": "organization", "index": 150, "label": "use-last-suggestion"},
          {"action": "settings-add", "kind": "repository", "text": "demo-z/not-suggested", "label": "typed-add-still-works"},
          {"action": "open-scope-settings", "label": "settings-capped"}]}
        """#,
        "settings-discovery-partial": #"""
        {"name": "settings-discovery-partial", "steps": [
          {"action": "discovery-mode", "mode": "partial", "label": "discovery-partial"},
          {"action": "settings-find-suggestions", "label": "find-partial"},
          {"action": "settings-add", "kind": "organization", "text": "demo-z", "label": "typed-add-still-works"},
          {"action": "open-scope-settings", "label": "settings-partial"}]}
        """#,
        "settings-discovery-denied": #"""
        {"name": "settings-discovery-denied", "steps": [
          {"action": "discovery-mode", "mode": "denied", "label": "discovery-denied"},
          {"action": "settings-find-suggestions", "label": "find-denied"},
          {"action": "settings-add", "kind": "organization", "text": "demo-z", "label": "typed-add-still-works"},
          {"action": "open-scope-settings", "label": "settings-denied"}]}
        """#,
        "settings-discovery-identity-mismatch": #"""
        {"name": "settings-discovery-identity-mismatch", "steps": [
          {"action": "settings-find-suggestions", "label": "find-complete"},
          {"action": "discovery-mode", "mode": "identityMismatch", "label": "discovery-mismatch"},
          {"action": "settings-find-suggestions", "label": "find-mismatch-discards"},
          {"action": "discovery-mode", "mode": "complete", "label": "discovery-complete"},
          {"action": "settings-find-suggestions", "label": "find-again"},
          {"action": "account", "account": "B", "label": "account-change-clears-hints"},
          {"action": "open-scope-settings", "label": "settings-account-b"}]}
        """#,
        "settings-validation-failure-keeps-active": #"""
        {"name": "settings-validation-failure-keeps-active", "steps": [
          {"action": "settings-add", "kind": "organization", "text": "demo-denied", "label": "add-denied-org"},
          {"action": "settings-add", "kind": "repository", "text": "elsewhere/pet", "label": "add-unknown-repo"},
          {"action": "settings-apply", "label": "apply-rejected"},
          {"action": "settings-remove", "kind": "organization", "index": 2, "label": "remove-denied"},
          {"action": "settings-edit", "kind": "repository", "index": 1, "text": "demo-renamed/pet", "label": "edit-renamed"},
          {"action": "settings-apply", "label": "apply-renamed-rejected"},
          {"action": "settings-edit", "kind": "repository", "index": 1, "text": "demo-b/pet", "label": "edit-valid"},
          {"action": "validation-mode", "mode": "networkFailure", "label": "network-failure-mode"},
          {"action": "settings-apply", "label": "apply-network-failure"},
          {"action": "validation-mode", "mode": "normal", "label": "network-normal"},
          {"action": "hold-validation", "label": "hold-next-validation"},
          {"action": "settings-apply", "label": "apply-held"},
          {"action": "account", "account": "B", "label": "account-b-discards-draft"},
          {"action": "deliver-all", "label": "deliver-late-validation"},
          {"action": "account", "account": "A", "label": "back-to-a-unchanged"},
          {"action": "open-scope-settings", "label": "settings-a"}]}
        """#,
        "settings-min-size-long-lists": #"""
        {"name": "settings-min-size-long-lists", "steps": [
          {"action": "settings-add", "kind": "organization", "text": "demo-organization-with-a-very-long-name", "label": "long-org-1"},
          {"action": "settings-add", "kind": "organization", "text": "demo-another-organization-long-name-x", "label": "long-org-2"},
          {"action": "settings-add", "kind": "organization", "text": "demo-third-organization-long-name-xyz", "label": "long-org-3"},
          {"action": "settings-add", "kind": "organization", "text": "demo-fourth-organization-long-name-xy", "label": "long-org-4"},
          {"action": "settings-add", "kind": "repository", "text": "demo-owner/a-much-longer-demo-repository-name-for-layout-one", "label": "long-repo-1"},
          {"action": "settings-add", "kind": "repository", "text": "demo-owner/a-much-longer-demo-repository-name-for-layout-two", "label": "long-repo-2"},
          {"action": "settings-add", "kind": "repository", "text": "demo-owner/a-much-longer-demo-repository-name-for-layout-three", "label": "long-repo-3"},
          {"action": "settings-add", "kind": "repository", "text": "demo-owner/a-much-longer-demo-repository-name-for-layout-four", "label": "long-repo-4"},
          {"action": "settings-add", "kind": "repository", "text": "demo-owner/a-much-longer-demo-repository-name-for-layout-five", "label": "long-repo-5"},
          {"action": "settings-edit", "kind": "organization", "index": 2, "text": "org:demo is:pr", "label": "inline-error"},
          {"action": "open-scope-settings", "label": "settings-long-lists"}]}
        """#,
    ]
}
