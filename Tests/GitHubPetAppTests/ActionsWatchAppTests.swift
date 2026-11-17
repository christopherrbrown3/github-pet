import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private let account = try! ScopeAccount(viewerID: "U_app_A")
private let pet = try! MonitoringTarget(repository: "example/pet")

/// Scripted inbox poll: no gh, no network.
private final class FakeScoped: ScopedPolling, @unchecked Sendable {
    let result: ScopedPollResult
    init(_ result: ScopedPollResult) { self.result = result }
    func fetch(scope: MonitoringScope, expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult { result }
    func fetchIdentity(expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult { result }
}
/// Records what the Actions side was asked for.
private final class FakeActions: ActionsPolling, @unchecked Sendable {
    let result: ScopedPollResult
    private(set) var requests: [(repositories: [MonitoringTarget], account: ScopeAccount?)] = []
    init(_ result: ScopedPollResult) { self.result = result }
    func fetch(repositories: [MonitoringTarget], expectedAccount: ScopeAccount?, budget: CommandBudget) -> ScopedPollResult {
        requests.append((repositories, expectedAccount)); return result
    }
}

@Suite @MainActor struct ActionsWatchAppTests {
    private let viewer = ScopeViewer(account: account, login: "app-user")
    private func request(identityOnly: Bool = false) throws -> ScopePollRequest {
        ScopePollRequest(generation: 1, serial: 1, scope: try MonitoringScope(selected: [pet]), expectedAccount: account,
                         identityOnly: identityOnly)
    }
    private var failure: InboxItem {
        InboxItem(id: "actions:CS_1", kind: .workflowFailure, repository: "example/pet", title: "CI failed on main",
                  url: URL(string: "https://github.com/example/pet/actions/runs/1"), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func actionsRunAfterAUsableInboxReplyForTheSameAccount() throws {
        let inbox = FakeScoped(ScopedPollResult(viewer: viewer, items: [], issues: [], successfulSources: 2))
        let actions = FakeActions(ScopedPollResult(viewer: viewer, items: [failure], issues: [], successfulSources: 1))
        let job = AppModel.ActionsJob(client: actions, repositories: [pet], makeBudget: { CommandBudget(timeout: 20) })
        let result = AppModel.poll(inbox, try request(), CommandBudget(timeout: 20), actions: job)
        #expect(result.complete && result.items == [failure])
        #expect(actions.requests.count == 1 && actions.requests[0].repositories == [pet] && actions.requests[0].account == account)
    }

    @Test func noActionsRequestWithoutAUsableInboxReplyOrAJob() throws {
        let actions = FakeActions(ScopedPollResult(viewer: viewer, items: [failure], issues: [], successfulSources: 1))
        let job = AppModel.ActionsJob(client: actions, repositories: [pet], makeBudget: { CommandBudget(timeout: 20) })
        let failed = AppModel.poll(FakeScoped(.failure(.transport)), try request(), CommandBudget(timeout: 20), actions: job)
        #expect(failed.items.isEmpty && actions.requests.isEmpty, "a failed inbox poll never adds Actions rows")
        let inbox = FakeScoped(ScopedPollResult(viewer: viewer, items: [], issues: [], successfulSources: 2))
        let off = AppModel.poll(inbox, try request(), CommandBudget(timeout: 20), actions: nil)
        #expect(off.complete && off.items.isEmpty && actions.requests.isEmpty)
    }

    @Test func settingsNoteIsHonestAboutWhatIsWatched() {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--fixtures"], environment: [:])
        options.forcePlaceholder = true
        options.userDefaultsOverride = EphemeralDefaults(name: "dev.github-pet.tests.actions.\(UUID().uuidString)")
        let actions = FakeActions(ScopedPollResult(viewer: nil, items: [], issues: [], successfulSources: 0))
        let app = AppModel(options: options, runtime: AppModel.Runtime(schedulesTimers: false, loginItemBackend: InertLogin(),
                                                                       actionsClient: actions))
        #expect(app.workflowWatchNote == nil, "off by default")
        app.settings.watchWorkflowFailures = true
        #expect(app.workflowWatchNote == "Workflow failures are watched with the GitHub CLI source.")
        app.refresh()
        #expect(actions.requests.isEmpty, "the Demo fixture source never queries Actions")
    }
}

private struct InertLogin: LoginItemBackend {
    var status: LoginItemStatus { .disabled }
    func register() throws {}
    func unregister() throws {}
}
