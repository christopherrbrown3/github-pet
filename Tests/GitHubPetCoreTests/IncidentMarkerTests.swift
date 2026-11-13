import CoreGraphics
import Foundation
import Testing
@testable import GitHubPetCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func incident(_ id: String, _ impact: IncidentImpact = .minor, name: String? = nil, demo: Bool = false,
                      minutesAgo: Double = 0) -> ServiceIncident {
    ServiceIncident(id: id, name: name ?? "Incident \(id)", status: .investigating, impact: impact,
                    updatedAt: t0.addingTimeInterval(-minutesAgo * 60), isDemo: demo)
}

@Suite struct IncidentMarkerStateTests {
    @Test func onlyAFreshConfirmedIncidentShowsTheMarker() {
        let list = [incident("a1")]
        #expect(IncidentMarker.current(state: .incidents, incidents: list) != nil)
        for state in [ServiceStatusState.loading, .operational, .stale, .error("offline")] {
            #expect(IncidentMarker.current(state: state, incidents: list) == nil, "\(state)")
        }
        #expect(IncidentMarker.current(state: .incidents, incidents: []) == nil)
    }

    @Test func monitorDrivenStates() {
        let monitor = ServiceStatusMonitor(staleAfter: 600)
        func marker() -> IncidentMarker? { IncidentMarker.current(state: monitor.state, incidents: monitor.incidents) }
        #expect(marker() == nil)                                       // loading
        monitor.apply(.incidents([incident("a1", .major)]), now: t0)
        #expect(marker()?.tier == .major)
        monitor.refreshFreshness(now: t0 + 600)
        #expect(marker() == nil)                                       // stale keeps rows, no marker
        monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 700)
        monitor.apply(.failure("offline"), now: t0 + 760)
        #expect(marker() == nil)                                       // failure keeps rows, no marker
        monitor.apply(.incidents([]), now: t0 + 800)
        #expect(marker() == nil)                                       // resolved
    }

    @Test func tierFollowsTheMostSevereImpact() {
        #expect(IncidentMarker.current(state: .incidents, incidents: [incident("a1", .none)])?.tier == .minor)
        #expect(IncidentMarker.current(state: .incidents, incidents: [incident("a1", .minor)])?.tier == .minor)
        #expect(IncidentMarker.current(state: .incidents, incidents: [incident("a1", .major)])?.tier == .major)
        #expect(IncidentMarker.current(state: .incidents, incidents: [incident("a1", .critical)])?.tier == .critical)
        let mixed = IncidentMarker.current(state: .incidents,
                                           incidents: [incident("a1", .minor), incident("b2", .critical, minutesAgo: 30)])
        #expect(mixed?.tier == .critical)
        #expect(mixed?.lead.id == "b2")
        #expect(mixed?.count == 2)
    }

    private func phase(_ tier: IncidentMarker.Tier, at dt: TimeInterval, from: IncidentMarker.Tier? = nil,
                       start: Date? = t0, reduced: Bool = false, alerts: Bool = true) -> IncidentMarker.Phase {
        IncidentMarker(tier: tier, count: 1, lead: incident("a1")).phase(
            now: t0 + dt, burst: start.map { IncidentMarker.Burst(start: $0, fromTier: from) },
            reducedMotion: reduced, alertsAllowed: alerts)
    }

    @Test func burstPlaysSixSecondsThenHoldsStatic() {
        #expect(phase(.minor, at: 0).time == 0)
        #expect(phase(.minor, at: 5).time == 5)
        #expect(phase(.minor, at: 6) == .still)
        #expect(phase(.minor, at: -1) == .still)
        #expect(phase(.minor, at: 1, start: nil) == .still)   // baseline or reconnect: no event, static
        #expect(IncidentMarker.burstDuration == 6)
    }

    @Test func staticUnderReduceMotionQuietOrSnooze() {
        #expect(phase(.critical, at: 1, reduced: true) == .still)
        #expect(phase(.critical, at: 1, alerts: false) == .still)
    }

    @Test func newIncidentFadesEveryLayerInByOpacity() {
        let start = phase(.critical, at: 0)
        #expect(start.fading == Set(IncidentMarker.Layer.allCases))
        #expect(start.envelope == 0)
        for layer in IncidentMarker.Layer.allCases { #expect(start.opacity(layer) == 0) }
        let mid = phase(.critical, at: 0.15)
        #expect(mid.envelope > 0 && mid.envelope < 1)
        #expect(phase(.critical, at: 0.31).envelope == 1)
        #expect(phase(.critical, at: 2).opacity(.flames) == 1)
    }

    @Test func tierRiseFadesOnlyNewLayers() {
        let rise = phase(.major, at: 0.1, from: .minor)
        #expect(rise.fading == [.flames])
        #expect(rise.opacity(.siren) == 1 && rise.opacity(.beaconSweep) == 1)
        #expect(rise.opacity(.flames) < 1)
        #expect(phase(.critical, at: 0.1, from: .major).fading == [.smoke])
        #expect(phase(.critical, at: 0.1, from: .minor).fading == [.flames, .smoke])
        // A new incident while the same tier already shows: nothing blinks.
        #expect(phase(.major, at: 0, from: .major).fading.isEmpty)
    }

    @Test func settleCrossfadesToStaticOverTheLastSixHundredMs() {
        #expect(phase(.major, at: 5.3).staticWeight == 0)
        #expect(abs(phase(.major, at: 5.7).staticWeight - 0.5) < 1e-6)
        #expect(phase(.major, at: 5.99).staticWeight > 0.98)
    }

    @Test func layersPerTier() {
        #expect(IncidentMarker.layers(.minor) == [.beaconSweep, .siren])
        #expect(IncidentMarker.layers(.major) == [.beaconSweep, .siren, .flames])
        #expect(IncidentMarker.layers(.critical) == Set(IncidentMarker.Layer.allCases))
        #expect(IncidentMarker.layers(nil).isEmpty)
    }

    @Test func tiersAreOrdered() {
        #expect(IncidentMarker.Tier.minor < .major && IncidentMarker.Tier.major < .critical)
    }
}

@Suite struct IncidentMarkerTextTests {
    private func marker(_ incidents: [ServiceIncident]) -> IncidentMarker? {
        IncidentMarker.current(state: .incidents, incidents: incidents)
    }

    @Test func hoverLineNamesThePublicIncident() {
        #expect(marker([incident("a1", name: "Degraded Actions")])?.hoverLine == "GitHub incident: Degraded Actions")
        #expect(marker([incident("a1", .minor, name: "Pages slow"), incident("b2", .major, name: "Git outage")])?.hoverLine
                == "GitHub incidents: Git outage (+1 more)")
        #expect(marker([incident("a1", name: "Slow", demo: true)])?.hoverLine == "Demo GitHub incident: Slow")
        let long = marker([incident("a1", name: String(repeating: "x", count: 200))])!.hoverLine
        #expect(long == "GitHub incident: " + String(repeating: "x", count: 59) + "…")
    }

    @Test func fullHoverPutsTheIncidentOnTop() {
        let lines = ["3 items", "Review request"]
        #expect(IncidentMarker.hoverLines(lines, marker: nil) == lines)
        #expect(IncidentMarker.hoverLines(lines, marker: marker([incident("a1", name: "Slow")]))
                == ["GitHub incident: Slow", "3 items", "Review request"])
    }

    @Test func compactHoverStaysTwoLines() {
        let m = marker([incident("a1", name: "Slow")])
        #expect(IncidentMarker.compactHoverLines(dataState: .empty, items: [], unseenCount: 0, demo: false, marker: m)
                == ["GitHub incident: Slow", "All clear"])
        #expect(IncidentMarker.compactHoverLines(dataState: .empty, items: [], unseenCount: 0, demo: true, marker: m)
                == ["GitHub incident: Slow", "Demo · All clear"])
        #expect(IncidentMarker.compactHoverLines(dataState: .stale, items: [], unseenCount: 0, demo: false, marker: nil)
                == PrivacyText.compactSummary(dataState: .stale, items: [], unseenCount: 0))
    }

    @Test func accessibilityLabelCountsIncidentsSeparately() {
        let one = marker([incident("a1")])
        #expect(IncidentMarker.statusLabel(dataState: .ready, count: 3, demo: false, needsAttention: false, marker: one)
                == "GitHub Pet, 3 items, 1 active GitHub incident")
        let two = marker([incident("a1"), incident("b2")])
        #expect(IncidentMarker.statusLabel(dataState: .ready, count: 3, demo: true, needsAttention: true, marker: two)
                == "GitHub Pet, Demo data, 3 items, 2 active GitHub incidents, needs attention")
        // Without a marker it is exactly the existing label.
        #expect(IncidentMarker.statusLabel(dataState: .stale, count: 3, demo: false, needsAttention: true, marker: nil)
                == AccessibilityText.statusLabel(dataState: .stale, count: 3, demo: false, needsAttention: true))
    }

    @Test func badgeCountsActionableItemsOnly() {
        // The marker never feeds the badge: it is computed from inbox items alone.
        #expect(MascotPolicy.badge(dataState: .empty, count: 0) == nil)
        #expect(MascotPolicy.badge(dataState: .ready, count: 3) == "3")
    }
}

@Suite struct IncidentMarkerGeometryTests {
    private func layouts() throws -> [MascotLayout] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pack = try MascotPack.load(from: root.appendingPathComponent("assets/mascots/\(MascotPack.defaultPackID)")).get()
        return [64, 128, 256].flatMap { side in
            [MascotLayout(artSide: side, contours: pack.allContours), MascotLayout(artSide: side)]
        }
    }

    @Test func slotNeverOverlapsAnyLabel() throws {
        for layout in try layouts() {
            let slot = IncidentMarker.frame(in: layout)
            #expect(slot.height > layout.artSide / 3, "usable slot at \(layout.artSide): \(slot)")
            #expect(layout.artFrame.contains(slot), "inside the art square at \(layout.artSide)")
            #expect(slot.maxY <= layout.artFrame.maxY - 64 * layout.artSide / 256, "below the design keep-out")
            for label in layout.labelRects {
                #expect(!slot.intersects(label), "slot \(slot) vs label \(label) at \(layout.artSide)")
                #expect(label.minY - slot.maxY >= layout.minimumGap || slot.maxX <= label.minX || slot.minX >= label.maxX)
            }
        }
    }
}

/// The transcribed spec must match design's canonical json (docs/design/incidents/incident-marker.json,
/// PR #38). GITHUB_PET_INCIDENT_SPEC can point at another copy of it.
@Suite struct IncidentMarkerSpecTests {
    static let specURL: URL = {
        if let path = ProcessInfo.processInfo.environment["GITHUB_PET_INCIDENT_SPEC"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/design/incidents/incident-marker.json")
    }()

    @Test(.enabled(if: FileManager.default.fileExists(atPath: specURL.path),
                   "design's spec is not on this branch yet (PR #38)"))
    func transcribedSpecMatchesDesignJSON() throws {
        let decoded = try JSONDecoder().decode(IncidentMarkerSpec.self, from: Data(contentsOf: Self.specURL))
        #expect(decoded == IncidentMarkerSpec.standard)
        // Field by field too, so a drift names its section.
        #expect(decoded.flames == IncidentMarkerSpec.standard.flames)
        #expect(decoded.smoke == IncidentMarkerSpec.standard.smoke)
        #expect(decoded.siren == IncidentMarkerSpec.standard.siren)
        #expect(decoded.palette == IncidentMarkerSpec.standard.palette)
        #expect(decoded.timing == IncidentMarkerSpec.standard.timing)
        #expect(decoded.static == IncidentMarkerSpec.standard.static)
        #expect(decoded.sizeOverrides == IncidentMarkerSpec.standard.sizeOverrides)
    }

    @Test func everyPaletteTokenIsUsableInBothAppearances() {
        let spec = IncidentMarkerSpec.standard
        #expect(Set(spec.palette.light.keys) == Set(spec.palette.dark.keys))
        for token in Array(spec.palette.light.values) + Array(spec.palette.dark.values) {
            #expect(token.rgb != nil, "\(token.hex)")
            #expect((0...1).contains(token.alpha))
        }
        var used = Set(spec.flames.nestedScales.map(\.token))
        used.formUnion([spec.flames.rim.token, spec.smoke.color, "incident.beacon", "incident.siren.dome",
                        "incident.siren.domeShade", "incident.siren.base", "incident.siren.outline", "incident.siren.gloss"])
        #expect(used.isSubset(of: Set(spec.palette.light.keys)))
    }

    @Test func geometryStaysBelowTheKeepOut() {
        let spec = IncidentMarkerSpec.standard
        let top = spec.keepOut.topBandMaxY
        for side in [64.0, 128, 256] {
            for tier in [IncidentMarker.Tier.major, .critical] {
                for tongue in spec.tongues(tier, artSide: side) {
                    // Tallest flicker: heightBase + heightAmp * (waveOffset + sum of amps).
                    let f = spec.flames.flicker
                    let tallest = tongue.height * (f.heightBase + f.heightAmp * (f.waveOffset + f.waves.map(\.amp).reduce(0, +)))
                    #expect(spec.flames.baseY - tallest >= top, "\(tier) \(tongue) at \(side)")
                    let limit = tier == .critical ? spec.flames.maxTip.criticalMinY : spec.flames.maxTip.majorMinY
                    #expect(spec.flames.baseY - tallest >= limit, "\(tier) tip above maxTip: \(tongue) at \(side)")
                }
            }
        }
        let sweep = spec.beaconSweep
        #expect(sweep.center[1] - sweep.radius >= top)
        let smoke = spec.smoke
        for emitter in smoke.emitters {
            #expect(emitter.y + emitter.dy - smoke.radius[1] >= top)
        }
        for puff in smoke.static { #expect(puff.cy - puff.r >= top) }
    }

    @Test func sixtyFourOverrideAppliesBelowNinetySix() {
        let spec = IncidentMarkerSpec.standard
        #expect(spec.tongues(.major, artSide: 64).count == 3)
        #expect(spec.tongues(.major, artSide: 80).count == 3)
        #expect(spec.tongues(.major, artSide: 128).count == 6)
        #expect(spec.tongues(.minor, artSide: 128).isEmpty)
    }

    @Test func easeMatchesTheCurveEnds() {
        let curve = IncidentMarkerSpec.standard.timing.fadeInCurve
        #expect(IncidentMarker.ease(0, curve) == 0)
        #expect(IncidentMarker.ease(1, curve) == 1)
        #expect(IncidentMarker.ease(0.5, curve) > 0.5)   // ease-out: front-loaded
    }
}
