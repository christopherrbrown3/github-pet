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

    @Test func burstPlaysSixSecondsThenHoldsStatic() {
        func elapsed(_ dt: TimeInterval, start: Date? = t0) -> TimeInterval? {
            IncidentMarker.burstElapsed(now: t0 + dt, burstStart: start, reducedMotion: false, alertsAllowed: true)
        }
        #expect(elapsed(0) == 0)
        #expect(elapsed(5.5) == 5.5)
        #expect(elapsed(6) == nil)
        #expect(elapsed(-1) == nil)
        #expect(elapsed(1, start: nil) == nil)   // baseline or reconnect: no event, static
    }

    @Test func staticUnderReduceMotionQuietOrSnooze() {
        #expect(IncidentMarker.burstElapsed(now: t0 + 1, burstStart: t0, reducedMotion: true, alertsAllowed: true) == nil)
        #expect(IncidentMarker.burstElapsed(now: t0 + 1, burstStart: t0, reducedMotion: false, alertsAllowed: false) == nil)
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
