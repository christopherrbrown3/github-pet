import AppKit
import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

/// #138 triggers on the real model: Demo fixtures, an ephemeral defaults domain, the repository's
/// packs (with or without placeholder clips) and a hand-driven app clock. No timers, no windows.
@Suite(.serialized) @MainActor struct AnimationTriggerTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_763_208_000)
        var reduced = false
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The bundled Mona without her incident clips (#138 frame sequences ship them), for the fallback.
    private static let withoutIncidentClips: URL = {
        let fm = FileManager.default
        let source = root.appendingPathComponent("assets/mascots/mona-pet-v1")
        let copy = fm.temporaryDirectory.appendingPathComponent("animation-tests-mona-\(UUID().uuidString)/mona-pet-v1")
        try? fm.createDirectory(at: copy, withIntermediateDirectories: true)
        for directory in ["frames", "accessories"] {
            try? fm.copyItem(at: source.appendingPathComponent(directory), to: copy.appendingPathComponent(directory))
        }
        if let data = try? Data(contentsOf: source.appendingPathComponent("manifest.json")),
           var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var clips = manifest["clips"] as? [String: Any] ?? [:]
            clips["incident-start"] = nil
            clips["incident-end"] = nil
            manifest["clips"] = clips
            try? JSONSerialization.data(withJSONObject: manifest).write(to: copy.appendingPathComponent("manifest.json"))
        }
        return copy.deletingLastPathComponent()
    }()

    private func model(_ clock: Clock, placeholderClips: Bool = true, packs: URL = root.appendingPathComponent("assets/mascots")) -> AppModel {
        var arguments = ["GitHubPet", "--fixtures"]
        if placeholderClips { arguments.append("--placeholder-clips") }
        var options = LaunchOptions.parse(arguments: arguments, environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "dev.github-pet.tests.animation.\(UUID().uuidString)")
        _ = NSApplication.shared
        return AppModel(options: options, runtime: AppModel.Runtime(
            now: { clock.now }, systemReducedMotion: { clock.reduced }, schedulesTimers: false,
            mascotPackDirectory: { packs.appendingPathComponent($0.rawValue) }, clipSeed: 1))
    }

    /// Yields after each step so other main-actor suites running in parallel are never starved.
    private func advance(_ app: AppModel, _ clock: Clock, by seconds: TimeInterval) async {
        clock.now += seconds
        app.tick()
        await Task.yield()
    }

    /// Leaves the model with no incident shown and no clip playing.
    private func clearIncidents(_ app: AppModel, _ clock: Clock) async {
        app.resolveServiceIncidents()
        await advance(app, clock, by: 5)
        #expect(app.incidentMarker == nil && app.activeClip == nil)
    }

    @Test func placeholderPackHasEveryClip() async {
        let app = model(Clock())
        for id in ClipCatalog.v1.ordered.map(\.id) + MascotClipID.heldStates { #expect(app.clipLibrary.has(id), "\(id)") }
        // Without placeholders the library is exactly what the bundled pack ships (#138).
        let bundled = model(Clock(), placeholderClips: false)
        #expect(bundled.mascotArtwork.pack != nil, "the bundled pack loads, not the placeholder")
        #expect(bundled.clipLibrary == ClipLibrary(pack: bundled.mascotArtwork.pack))
    }

    @Test func hatGoesOnOnceAndComesOffOnlyOnAFreshOperationalReply() async {
        let clock = Clock(), app = model(clock)
        await clearIncidents(app, clock)
        app.injectServiceIncident(.minor)
        #expect(app.activeClip?.kind == .incidentStart && app.activeClip?.origin == .serviceIncident)
        #expect(app.accessories == [AccessoryPolicy.firefighterHat])
        await advance(app, clock, by: 3)
        // Hat on: a second incident and an escalation get the marker burst only.
        app.injectServiceIncident(.minor)
        #expect(app.activeClip == nil && app.markerBurst != nil)
        await advance(app, clock, by: 7)
        app.escalateServiceIncidentsOneLevel()
        #expect(app.activeClip == nil && app.markerBurst != nil)
        await advance(app, clock, by: 7)
        app.resolveServiceIncidents()
        #expect(app.activeClip?.kind == .incidentEnd)
        #expect(app.accessories.isEmpty, "the hat leaves with the marker")
        await advance(app, clock, by: 4)
        // An unchanged operational poll replays nothing.
        app.resolveServiceIncidents()
        #expect(app.activeClip == nil)
    }

    /// Chris (#138): "sometimes it replays putting the hat back on". incident-start plays once per
    /// incident whatever happens while it is open, and incident-end once when it resolves.
    @Test func incidentStartPlaysOncePerIncidentAndEndOnceAtResolution() async {
        let clock = Clock(), app = model(clock, placeholderClips: false)
        await clearIncidents(app, clock)
        var starts = 0, ends = 0, seen: Set<Date> = []
        func observe() {
            guard let clip = app.activeClip, !seen.contains(clip.startedAt) else { return }
            if clip.kind == .incidentStart { starts += 1; seen.insert(clip.startedAt) }
            if clip.kind == .incidentEnd { ends += 1; seen.insert(clip.startedAt) }
        }
        func step(_ seconds: TimeInterval, _ action: () -> Void) async {
            action(); observe()
            await advance(app, clock, by: seconds); observe()
        }
        await step(3) { app.injectServiceIncident(.minor) }
        #expect(starts == 1)
        // Mid-incident: polls, a second incident, escalation and back, a new inbox item (mood change),
        // clicks after it, a fixture reload, a failed then recovered status fetch, stale status, the
        // dev replay, and a long quiet spell (doze, then a click wakes).
        await step(10) { app.setServiceFetchFails(false) }
        await step(10) { app.injectServiceIncident(.minor) }
        await step(10) { app.escalateServiceIncidentsOneLevel() }
        await step(10) { app.deescalateServiceIncidentsOneLevel() }
        await step(3) { app.injectEntitlementEvent() }
        await step(3) { app.mascotClicked() }
        await step(10) { app.replaySnapshot() }
        await step(10) { app.setServiceFetchFails(true) }
        await step(10) { app.setServiceFetchFails(false) }
        await step(10) { app.markServiceStale() }
        await step(10) { app.setServiceFetchFails(false) }
        for _ in 0..<(2 * ClipCatalog.v1.ordered.count) { await step(3) { app.replayNextClip() } }
        await step(20 * 60) {}
        await step(3) { app.mascotClicked() }
        await step(10) { app.setServiceFetchFails(false) }
        #expect(starts == 1, "incident-start replayed mid-incident")
        #expect(ends == 0)
        await step(4) { app.resolveServiceIncidents() }
        await step(10) { app.resolveServiceIncidents() }
        await step(10) { app.setServiceFetchFails(false) }
        #expect(starts == 1 && ends == 1)
        // A new incident is a new start.
        await step(3) { app.injectServiceIncident(.minor) }
        #expect(starts == 2)
    }

    @Test func withoutTheClipsAnIncidentWavesOnceAndNeverPlaysUrgent() async {
        let clock = Clock(), app = model(clock, placeholderClips: false, packs: Self.withoutIncidentClips)
        await clearIncidents(app, clock)
        app.injectServiceIncident(.critical)
        #expect(app.activeClip?.kind == .newItem && app.activeClip?.state == .attention, "the wave, never urgent")
        await advance(app, clock, by: 3)
        app.injectServiceIncident(.minor)
        #expect(app.activeClip == nil && app.markerBurst != nil, "a second incident: the marker burst only")
        await advance(app, clock, by: 7)
        app.escalateServiceIncidentsOneLevel()
        #expect(app.activeClip == nil, "an escalation: the marker burst only")
        await advance(app, clock, by: 3)
        app.resolveServiceIncidents()
        #expect(app.activeClip == nil, "no incident-end clip without the art")
        #expect(app.accessories.isEmpty)
    }

    @Test func reduceMotionPlaysNothingButStillWearsTheHat() async {
        let clock = Clock(), app = model(clock)
        await clearIncidents(app, clock)
        clock.reduced = true
        app.injectServiceIncident(.major)
        #expect(app.activeClip == nil && app.accessories == [AccessoryPolicy.firefighterHat])
        app.mascotClicked()
        app.mascotDragBegan()
        app.mascotDragEnded()
        #expect(app.clipStage.scheduled == nil)
        // Turning motion back on replays nothing.
        clock.reduced = false
        await advance(app, clock, by: 1)
        #expect(app.activeClip == nil && app.clipStage.scheduled == nil)
    }

    @Test func clicksPokeAndFiveQuickClicksMakeDizzy() async {
        let clock = Clock(), app = model(clock)
        await clearIncidents(app, clock)
        app.mascotClicked()
        #expect(app.clipStage.scheduled?.id == .poke)
        for _ in 0..<4 { clock.now += 0.3; app.mascotClicked() }
        #expect(app.clipStage.scheduled?.id == .dizzy)
        await advance(app, clock, by: 3)
        for _ in 0..<5 { clock.now += 0.3; app.mascotClicked() }
        #expect(app.clipStage.scheduled?.id != .dizzy, "dizzy waits out its 60 s cooldown")
    }

    @Test func dragHoldsThePoseAndDropPlaysUnlessAnEventIsStillRunning() async {
        let clock = Clock(), app = model(clock)
        await clearIncidents(app, clock)
        app.mascotDragBegan()
        #expect(app.clipStage.dragStart == clock.now)
        app.mascotDragMoved(x: 0, time: 0)
        app.mascotDragMoved(x: 40, time: 1.0 / 60)
        app.mascotDragMoved(x: 80, time: 2.0 / 60)
        #expect(app.clipStage.dragAngle > 0)
        clock.now += 1
        app.mascotDragEnded()
        #expect(app.clipStage.dragStart == nil && app.clipStage.scheduled?.id == .drop)
        // An event clip that started under the drag shows its remaining frames instead of the drop.
        await advance(app, clock, by: 2)
        app.mascotDragBegan()
        app.injectServiceIncident(.minor)
        #expect(app.activeClip?.kind == .incidentStart)
        clock.now += 0.5
        app.mascotDragEnded()
        #expect(app.clipStage.scheduled == nil && app.activeClip?.kind == .incidentStart)
    }

    @Test func dozeAfterFifteenQuietMinutesAndHoverWakes() async {
        let clock = Clock(), app = model(clock)
        await clearIncidents(app, clock)
        app.markAllSeen()
        try? #require(app.mascotState == .idle)
        // Fresh data is required, so poll as the app's timer would (no timers in tests).
        for minute in 0..<16 {
            app.replaySnapshot()
            await advance(app, clock, by: 60)
            if minute < 14 { #expect(app.clipStage.dozeStart == nil) }
        }
        #expect(app.dataState.countIsKnown)
        #expect(app.clipStage.dozeStart != nil)
        app.mascotHover(true)
        #expect(app.clipStage.dozeStart == nil)
        app.mascotHover(false)
        // Never while the incident marker shows.
        app.injectServiceIncident(.minor)
        for _ in 0..<20 { app.replaySnapshot(); await advance(app, clock, by: 60) }
        #expect(app.clipStage.dozeStart == nil)
        // Stale data never dozes either.
        app.resolveServiceIncidents()
        for _ in 0..<60 { await advance(app, clock, by: 60) }
        #expect(app.dataState == .stale && app.clipStage.dozeStart == nil)
    }

    private func rows(_ count: Int, _ tag: String) -> [InboxItem] {
        (0..<count).map {
            InboxItem(id: "reviewRequest:zero-\(tag)-\($0)", kind: .reviewRequest, repository: "example/pet",
                      title: "Fixture \($0)", url: nil, updatedAt: Date(timeIntervalSince1970: 1_763_200_000))
        }
    }

    /// inbox-zero (#138, QA): only a fresh poll going from at least one shown item (ready or partial)
    /// to verified empty plays it; never the launch baseline, all-dismissed or recovery from stale.
    @Test func inboxZeroOnlyForAFreshPollFromItemsToVerifiedEmpty() async throws {
        let clock = Clock(), app = model(clock)
        await clearIncidents(app, clock)
        func played() -> Bool { app.clipStage.scheduled?.id == .inboxZero }

        // An empty launch baseline (Loading, then an empty first poll) plays nothing.
        app.showLoadingForSnapshot()
        #expect(app.dataState == .loading)
        app.simulateFixtureItems([])
        #expect(app.dataState == .empty && !played(), "empty baseline at launch")
        await advance(app, clock, by: 10)

        // Dismissing every row leaves a ready inbox, never the verified-empty state.
        app.simulateFixtureItems(rows(2, "dismiss"))
        await advance(app, clock, by: 10)
        let context = try #require(app.inboxDismissalContext)
        for row in app.items where app.canDismissInboxItem(row) { app.dismissInboxItem(row.id, in: context) }
        await advance(app, clock, by: 10)
        app.replaySnapshot()
        #expect(app.items.isEmpty && app.dataState != .empty && !played(), "dismiss-all")

        // Stale, then an empty poll: recovery, not a transition from shown items.
        app.simulateFixtureItems(rows(3, "stale"))
        await advance(app, clock, by: 10)
        app.markStale()
        app.tick()
        #expect(app.dataState == .stale)
        app.simulateFixtureItems([])
        #expect(app.dataState == .empty && !played(), "stale to empty")
        await advance(app, clock, by: 10)

        // Partial with nothing shown, then empty: there were no items to clear.
        let issue = InboxItem(id: "assignedIssue:zero-partial", kind: .assignedIssue, repository: "example/pet",
                              title: "Fixture issue", url: nil, updatedAt: Date(timeIntervalSince1970: 1_763_200_000))
        app.simulateFixtureItems([issue])
        await advance(app, clock, by: 10)
        app.setPartialPolls(true)
        await advance(app, clock, by: 10)
        #expect(app.dataState == .partial && app.items.isEmpty)
        app.simulateFixtureItems([])
        #expect(app.dataState == .partial && app.items.isEmpty)
        app.setPartialPolls(false)   // polls: complete and empty
        #expect(app.dataState == .empty && !played(), "partial with no items to empty")
        await advance(app, clock, by: 10)

        // Three fresh items, then a fresh empty poll: plays once.
        app.simulateFixtureItems(rows(3, "zero"))
        await advance(app, clock, by: 10)
        #expect(app.dataState == .ready && app.items.count == 3)
        app.simulateFixtureItems([])
        #expect(app.dataState == .empty && played(), "3 items to empty")
        await advance(app, clock, by: 10)
        app.replaySnapshot()
        #expect(!played(), "an unchanged empty poll doesn't replay")

        // Within the 30-minute cooldown a second transition plays nothing; after it, it plays again.
        app.simulateFixtureItems(rows(1, "cooldown"))
        await advance(app, clock, by: 10)
        app.simulateFixtureItems([])
        #expect(app.dataState == .empty && !played(), "cooldown holds")
        clock.now += 31 * 60
        app.simulateFixtureItems(rows(1, "later"))
        await advance(app, clock, by: 10)
        app.simulateFixtureItems([])
        #expect(played(), "after 30 minutes")
    }

    /// Ambient clips are suppressed while the incident marker shows (#138, QA).
    @Test func noAmbientClipWhileTheIncidentMarkerShows() async {
        let clock = Clock(), app = model(clock)
        await clearIncidents(app, clock)
        app.injectServiceIncident(.minor)
        app.markAllSeen()
        #expect(app.incidentMarker != nil && app.mascotState == .idle)
        func ambient() -> Bool { app.clipStage.scheduled?.tier == .idleVariant }
        var sawAmbient = false
        for _ in 0..<(12 * 6) {
            app.replaySnapshot()
            await advance(app, clock, by: 10)
            sawAmbient = sawAmbient || ambient()
        }
        #expect(!sawAmbient, "12 minutes with the marker shown: no ambient clip")
        // Control: once the marker is gone, an ambient clip does play within the 2–5 minute gap.
        app.resolveServiceIncidents()
        app.mascotHover(true)
        app.mascotHover(false)
        for _ in 0..<(6 * 6) {
            app.replaySnapshot()
            await advance(app, clock, by: 10)
            sawAmbient = sawAmbient || ambient()
        }
        #expect(app.incidentMarker == nil && sawAmbient, "without the marker, ambient clips play")
    }

    @Test func dismissingANeedsYouRowPlaysItemCleared() async throws {
        let clock = Clock(), app = model(clock)
        await clearIncidents(app, clock)
        let context = try #require(app.inboxDismissalContext)
        let row = try #require(app.items.first { app.canDismissInboxItem($0) })
        app.dismissInboxItem(row.id, in: context)
        #expect(app.clipStage.scheduled?.id == .itemCleared)
        await advance(app, clock, by: 10)
        if let waiting = app.waitingItems.first(where: { app.canDismissInboxItem($0) }) {
            app.dismissInboxItem(waiting.id, in: context)
            #expect(app.clipStage.scheduled == nil, "a Waiting on others row plays nothing")
        }
    }
}
