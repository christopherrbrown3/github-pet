import Foundation
import Testing
@testable import GitHubPetCore

@Suite struct RepositoryScopeSessionTests {
    private let a = try! ScopeAccount(viewerID: "U_demo_A")
    private let b = try! ScopeAccount(viewerID: "U_demo_B")
    private var selected: MonitoringScope { try! MonitoringScope(selected: [MonitoringTarget(organization: "demo-a")]) }
    private func fixture(_ body: (RepositoryScopeSession, ScopeSelectionStore, UserDefaults) throws -> Void) rethrows {
        let name = "scope.session.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ScopeSelectionStore(defaults: defaults)
        try body(RepositoryScopeSession(store: store), store, defaults)
    }
    private func result(_ account: ScopeAccount, issues: [ScopedFetchIssue] = []) -> ScopedPollResult {
        ScopedPollResult(viewer: ScopeViewer(account: account, login: "demo_sim"), items: [FixtureSimulator.defaultItems()[0]],
                         issues: issues, successfulSources: 2)
    }
    @Test func knownSelectedIsFirstRequestAndUnknownBootstrapCannotDisplayEverything() throws {
        try fixture { session, store, _ in
            try store.save(selected, for: .github(a)); store.rememberAccount(a)
            session.startLive()
            let first = try #require(session.beginPoll())
            #expect(first.scope == selected && first.expectedAccount == a)
            if case .apply = session.receive(result(a), for: first).action {} else { Issue.record("bound selected applies") }
            store.rememberAccount(nil); session.startLive()
            let bootstrap = try #require(session.beginPoll())
            #expect(bootstrap.scope == .everything && bootstrap.expectedAccount == nil)
            let receipt = session.receive(result(a), for: bootstrap)
            #expect(receipt.resetRepositories)
            if case .refetch = receipt.action {} else { Issue.record("unrestricted rows discarded") }
            let next = try #require(session.beginPoll())
            #expect(next.scope == selected && next.expectedAccount == a)
        }
    }
    @Test func accountRoundTripRestoresEachRecordAndLateReplyCannotLandOrFinishNewFetch() throws {
        try fixture { session, store, _ in
            try store.save(selected, for: .github(a)); store.rememberAccount(a)
            session.startLive()
            let oldA = try #require(session.beginPoll())
            let changed = session.receive(result(b, issues: [.identityMismatch]), for: oldA)
            #expect(changed.resetRepositories && session.identity == .github(b) && session.scope == .everything)
            let boundB = try #require(session.beginPoll())
            if case .discard = session.receive(result(a), for: oldA).action {} else { Issue.record("old A discarded") }
            #expect(session.isCurrent(boundB))
            let returned = session.receive(result(a, issues: [.identityMismatch]), for: boundB)
            if case .refetch = returned.action {} else { Issue.record("return A requires selected refetch") }
            #expect(session.scope == selected)
            #expect(try #require(session.beginPoll()).expectedAccount == a)
        }
    }
    @Test func applyIsAtomicAndStaleValidationSourceChangesCannotPersist() throws {
        try fixture { session, store, _ in
            store.rememberAccount(a); session.startLive()
            let old = try #require(session.beginPoll()), generation = session.generation
            #expect(try session.apply(selected, for: .github(a), generation: generation))
            let next = try #require(session.beginPoll())
            if case .discard = session.receive(result(a), for: old).action {} else { Issue.record("pre-apply response discarded") }
            #expect(session.isCurrent(next))
            #expect(!(try session.apply(.everything, for: .github(a), generation: generation)))
            session.startDemo()
            #expect(!(try session.apply(.everything, for: .github(a), generation: session.generation)))
            #expect(store.load(for: .github(a)) == .scope(selected))
            #expect(store.load(for: .demo) == .scope(.everything))
        }
    }
    @Test func corruptSelectedAndBudgetFailureNeverBroadenOrAppearEmpty() throws {
        try fixture { session, store, defaults in
            store.rememberAccount(a)
            defaults.set(Data(#"{"mode":"selected","targets":[]}"#.utf8), forKey: ScopeSelectionStore.key(.github(a)))
            session.startLive()
            #expect(session.configurationError && session.scope == nil)
            let request = try #require(session.beginPoll())
            if case .apply(.failure) = session.receive(result(a), for: request).action {} else { Issue.record("corrupt record cannot accept bootstrap") }
            #expect(session.scope == nil && session.configurationError)
            if case .failure = session.failCycle(.deadline) {} else { Issue.record("budget exhaustion is explicit failure") }
            #expect(session.scope == nil)
        }
    }
    @Test func summariesNeverContainNamesAndEveryQualityRemainsVisible() throws {
        try fixture { session, store, _ in
            try store.save(selected, for: .github(a)); store.rememberAccount(a); session.startLive()
            #expect(!session.summary.contains("demo-a"))
            for issue in [ScopedFetchIssue.rateLimited, .outputLimit, .transport, .targetUnavailable(0), .capped("reviews0")] {
                let request = try #require(session.beginPoll())
                if case .apply(.snapshot(_, false)) = session.receive(result(a, issues: [issue]), for: request).action {} else { Issue.record("quality reaches engine incomplete") }
                #expect(session.qualitySummary != nil && !session.qualitySummary!.contains("demo-a"))
            }
        }
    }
}

@Suite struct SourceClipTests {
    @Test func repositoryResetKeepsConcurrentIncidentAtOriginalTimeAndNeverReplays() {
        let date = Date(timeIntervalSince1970: 100), event = InboxEvent(item: FixtureSimulator.defaultItems()[0])
        var queue = EventClipQueue()
        queue.enqueue([event], now: date, playable: true)
        queue.enqueue([event], now: date.addingTimeInterval(0.1), playable: true, origin: .serviceIncident)
        queue.clear(origin: .repository)
        #expect(queue.active?.origin == .serviceIncident && queue.active?.startedAt == date.addingTimeInterval(0.1))
        queue.tick(now: date.addingTimeInterval(3))
        #expect(queue.active == nil)
        queue.clear(origin: .repository)
        #expect(queue.active == nil)
    }
}

private final class CycleRunner: CommandRunner, @unchecked Sendable {
    var calls = 0
    let json = Data(#"{"data":{"viewer":{"id":"U_demo_A","login":"demo-a"},"reviews0":{"issueCount":0,"nodes":[],"pageInfo":{"hasNextPage":false}},"assigned0":{"issueCount":0,"nodes":[],"pageInfo":{"hasNextPage":false}}}}"#.utf8)
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls += 1
        return CommandResult(exitCode: 0, stdout: arguments.first == "api" ? json : Data())
    }
}
@Suite struct ScopeCycleBudgetTests {
    @Test func bootstrapAndRefetchConsumeOneAggregateBudget() {
        let runner = CycleRunner()
        let client = ScopedGhClient(locator: GhLocator(environment: [GhLocator.overrideVariable: "/fixture/gh"], isExecutable: { _ in true }), runner: runner)
        let shared = CommandBudget(timeout: 20, maximumBytes: runner.json.count * 2 - 1)
        #expect(client.fetch(scope: .everything, expectedAccount: nil, budget: shared).complete)
        #expect(shared.consumedBytes == runner.json.count)
        let second = client.fetch(scope: .everything, expectedAccount: nil, budget: shared)
        #expect(!second.complete && second.issues == [.outputLimit] && runner.calls == 4)
    }
    @Test func exhaustedCycleCannotStartAnotherPreflight() {
        let runner = CycleRunner()
        let client = ScopedGhClient(locator: GhLocator(environment: [GhLocator.overrideVariable: "/fixture/gh"], isExecutable: { _ in true }), runner: runner)
        let result = client.fetch(scope: .everything, expectedAccount: nil, budget: CommandBudget(timeout: 0))
        #expect(result.issues == [.deadline] && !result.complete && runner.calls == 0)
    }
}
