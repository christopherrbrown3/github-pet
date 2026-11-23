import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

/// #12: the event baseline and source quality survive a relaunch in the launch's own domain.
/// Each "relaunch" is a second AppModel over the same in-memory defaults.
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct BaselinePersistenceTests {
    private let launch = Date(timeIntervalSince1970: 1_763_208_000)
    private let demoKey = BaselineKey(source: .fixtures, identity: .demo, scope: .everything)

    private func fixtureModel(_ defaults: UserDefaults, now: Date, arguments: [String] = []) -> AppModel {
        var options = LaunchOptions.parse(arguments: ["app", "--fixtures", "--placeholder"] + arguments, environment: [:])
        options.userDefaultsOverride = defaults
        return AppModel(options: options, runtime: AppModel.Runtime(now: { now }, systemReducedMotion: { false },
                                                                     schedulesTimers: false))
    }

    private func freshDefaults() -> EphemeralDefaults {
        EphemeralDefaults(name: "baseline.app.tests.\(UUID().uuidString)")
    }

    /// Edits the saved record as if `id` had arrived after the last session quit.
    private func forget(_ id: String, in defaults: UserDefaults) throws {
        let store = EventBaselineStore(defaults: defaults)
        var record = try #require(store.load(for: demoKey))
        let before = record.digests.count
        record.digests.removeAll { $0 == EventBaseline.digest(id) }
        try #require(record.digests.count == before - 1)
        store.save(record)
    }

    private var arrivedWhileQuit: String { FixtureSimulator.defaultItems()[0].id }

    @Test func relaunchWithNothingNewAnnouncesNothing() throws {
        let defaults = freshDefaults()
        let first = fixtureModel(defaults, now: launch)
        #expect(first.dataState == .ready && first.unseenCount == 0)
        first.injectEntitlementEvent()
        #expect(first.unseenCount == 1)
        let saved = try #require(EventBaselineStore(defaults: defaults).load(for: demoKey))
        #expect(saved.quality == .ready && saved.baselineEstablished && saved.digests.count == 4)

        let relaunch = fixtureModel(defaults, now: launch + 3600)
        #expect(relaunch.dataState == .ready && relaunch.items.count == 3)
        #expect(relaunch.unseenCount == 0 && relaunch.activeClip == nil, "already-seen items are not re-announced")
    }

    // FAIL before #12: the relaunch re-baselined silently and the item was never announced.
    @Test func itemThatArrivedWhileQuitIsAnnouncedExactlyOnce() throws {
        let defaults = freshDefaults()
        _ = fixtureModel(defaults, now: launch)
        try forget(arrivedWhileQuit, in: defaults)

        let relaunch = fixtureModel(defaults, now: launch + 8 * 3600)
        #expect(relaunch.unseenCount == 1)
        #expect(relaunch.items.filter(relaunch.isUnseen).map(\.id) == [arrivedWhileQuit])
        relaunch.markAllSeen()
        relaunch.replaySnapshot()
        #expect(relaunch.unseenCount == 0, "announced once; the next poll is silent")
    }

    @Test func recordOlderThanADayRebaselinesSilently() throws {
        let defaults = freshDefaults()
        _ = fixtureModel(defaults, now: launch)
        try forget(arrivedWhileQuit, in: defaults)
        let relaunch = fixtureModel(defaults, now: launch + InboxEngine.restoredComparableWindow + 60)
        #expect(relaunch.dataState == .ready && relaunch.unseenCount == 0)
    }

    @Test func partialOrStaleQualityRelaunchRebaselinesSilentlyAndNeverLooksEmpty() throws {
        for makeIncomplete in [{ (app: AppModel) in app.setPartialPolls(true) }, { (app: AppModel) in app.markStale() }] {
            let defaults = freshDefaults()
            let first = fixtureModel(defaults, now: launch)
            makeIncomplete(first)
            let saved = try #require(EventBaselineStore(defaults: defaults).load(for: demoKey))
            #expect(saved.quality == .partial || saved.quality == .stale)
            try forget(arrivedWhileQuit, in: defaults)
            let relaunch = fixtureModel(defaults, now: launch + 60)
            #expect(relaunch.dataState == .ready && relaunch.unseenCount == 0)
        }
    }

    @Test func resetSettingsLaunchStartsAFreshBaseline() throws {
        let defaults = freshDefaults()
        _ = fixtureModel(defaults, now: launch)
        try forget(arrivedWhileQuit, in: defaults)
        let relaunch = fixtureModel(defaults, now: launch + 60, arguments: ["--reset-settings"])
        #expect(relaunch.unseenCount == 0)
    }

    @Test func corruptRecordRelaunchesWithFreshSilentBaseline() throws {
        let defaults = freshDefaults()
        defaults.set(Data("{corrupt".utf8), forKey: EventBaselineStore.key)
        let relaunch = fixtureModel(defaults, now: launch)
        #expect(relaunch.dataState == .ready && relaunch.unseenCount == 0)
        #expect(EventBaselineStore(defaults: defaults).load(for: demoKey)?.quality == .ready, "replaced by a valid record")
    }

    @Test func scopeChangeRelaunchStartsFreshAndKeepsNoOldRecord() throws {
        let defaults = freshDefaults()
        _ = fixtureModel(defaults, now: launch)
        try forget(arrivedWhileQuit, in: defaults)
        let narrowed = try MonitoringScope(selected: [MonitoringTarget(repository: "example/pet-demo")])
        try ScopeSelectionStore(defaults: defaults).save(narrowed, for: .demo)

        let relaunch = fixtureModel(defaults, now: launch + 60)
        #expect(relaunch.items.count == 2 && relaunch.unseenCount == 0)
        let store = EventBaselineStore(defaults: defaults)
        let newKey = BaselineKey(source: .fixtures, identity: .demo, scope: narrowed)
        #expect(store.load(for: newKey)?.digests.count == 2)
        #expect(store.load(for: demoKey) == nil)
    }

    @Test func inSessionScopeChangeStartsAFreshSilentBaseline() throws {
        let defaults = freshDefaults()
        let app = fixtureModel(defaults, now: launch)
        let narrowed = try MonitoringScope(selected: [MonitoringTarget(repository: "example/pet-tools")])
        #expect(app.applyRepositoryScope(narrowed, identity: .demo, generation: app.monitoringScopeGeneration))
        #expect(app.items.count == 1 && app.unseenCount == 0)
        let saved = EventBaselineStore(defaults: defaults).load(for: BaselineKey(source: .fixtures, identity: .demo, scope: narrowed))
        #expect(saved?.digests == [EventBaseline.digest(FixtureSimulator.defaultItems()[1].id)])
    }

    private func settled(_ model: AppModel) async throws {
        await model.repositoryPollSettled()
        try #require(!model.repositoryFetchInFlight)
    }

    @Test func accountSwitchStartsFreshWithNoLeakageAndStaysInTheThrowawayDomain() async throws {
        var options = LaunchOptions.parse(arguments: ["app", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        let suite = try #require(options.defaultsSuite)
        let instant = ContinuousClock.now  // frozen budget clock (#162): runner load never times a poll out
        let app = AppModel(options: options, runtime: AppModel.Runtime(now: { self.launch }, systemReducedMotion: { false },
                                                                        schedulesTimers: false, repositoryBudget: { CommandBudget(timeout: 20, now: { instant }) },
                                                                        scopeSimulationHoldLimit: nil))
        try await settled(app)
        let domain = EphemeralDefaults.named(suite)
        let store = EventBaselineStore(defaults: domain)
        func currentKey() throws -> BaselineKey {
            BaselineKey(source: .githubCLI, identity: try #require(app.monitoringScopeIdentity),
                        scope: try #require(app.activeMonitoringScope))
        }
        app.simulateScopeInject(); try await settled(app)
        #expect(app.unseenCount == 1)
        let digestsA = Set(try #require(store.load(for: try currentKey())).digests)
        #expect(!digestsA.isEmpty)

        app.simulateScopeAccount(true); try await settled(app)
        #expect(app.monitoringScopeIdentity == .github(ScopeSimulation.accountB))
        #expect(app.unseenCount == 0 && app.activeClip == nil, "account switch re-baselines silently")
        let recordB = try #require(store.load(for: try currentKey()))
        #expect(Set(recordB.digests).isDisjoint(with: digestsA), "no account A digests in B's baseline")

        app.simulateScopeAccount(false); try await settled(app)
        #expect(app.unseenCount == 0, "A -> B -> A is fresh and silent too")

        app.cleanupScopeSimulation()
        #expect(app.simulationDomainKeyCount == 0)
        #expect(!preferencesFileExists(suite), "no preferences file on disk")
    }

    @Test func snapshotLaunchUsesOnlyItsThrowawayDomain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-snapshot-\(UUID().uuidString)")
        var options = LaunchOptions.parse(arguments: ["app", "--render-snapshots", directory.path, "--placeholder"], environment: [:])
        // Snapshot launches resolve to the in-memory snapshot suite (SettingsScenarioRunnerTests);
        // a private stand-in here avoids racing that test over the shared per-process instance.
        #expect(options.userDefaults is EphemeralDefaults)
        let throwaway = freshDefaults()
        options.userDefaultsOverride = throwaway
        let app = AppModel(options: options, runtime: AppModel.Runtime(now: { self.launch }, systemReducedMotion: { false },
                                                                        schedulesTimers: false))
        #expect(app.dataState == .ready)
        #expect(throwaway.data(forKey: EventBaselineStore.key) != nil, "the baseline goes to the launch's domain")
    }
}
