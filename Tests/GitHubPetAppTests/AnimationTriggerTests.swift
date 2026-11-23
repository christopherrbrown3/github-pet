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

    private func model(_ clock: Clock, placeholderClips: Bool = true) -> AppModel {
        var arguments = ["GitHubPet", "--fixtures"]
        if placeholderClips { arguments.append("--placeholder-clips") }
        var options = LaunchOptions.parse(arguments: arguments, environment: [:])
        options.userDefaultsOverride = EphemeralDefaults(name: "dev.github-pet.tests.animation.\(UUID().uuidString)")
        _ = NSApplication.shared
        return AppModel(options: options, runtime: AppModel.Runtime(
            now: { clock.now }, systemReducedMotion: { clock.reduced }, schedulesTimers: false,
            mascotPackDirectory: { Self.root.appendingPathComponent("assets/mascots/\($0.rawValue)") }, clipSeed: 1))
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
        #expect(model(Clock(), placeholderClips: false).clipLibrary == .empty, "the bundled packs ship no clips yet")
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

    @Test func withoutTheClipsAnIncidentWavesOnceAndNeverPlaysUrgent() async {
        let clock = Clock(), app = model(clock, placeholderClips: false)
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
