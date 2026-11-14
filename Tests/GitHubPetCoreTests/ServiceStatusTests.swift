import Foundation
import Testing
@testable import GitHubPetCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func incident(_ id: String, _ impact: IncidentImpact = .minor, status: IncidentStatus = .investigating,
                      minutesAgo: Double = 0, name: String? = nil) -> ServiceIncident {
    ServiceIncident(id: id, name: name ?? "Incident \(id)", status: status, impact: impact,
                    updatedAt: t0.addingTimeInterval(-minutesAgo * 60))
}

/// A Statuspage payload with the given incident objects (JSON fragments).
private func payload(_ incidents: [String]) -> Data {
    Data(#"{"page":{"id":"kctbh9vrtdwd","name":"GitHub","url":"https://www.githubstatus.com"},"incidents":["#
        .appending(incidents.joined(separator: ","))
        .appending("]}").utf8)
}

private func raw(_ id: String, status: String = "investigating", impact: String = "minor",
                 created: String = "2026-11-13T09:10:00.000Z", updated: String? = "2026-11-13T09:35:00.000Z",
                 resolved: String? = nil, name: String = "Degraded Actions") -> String {
    let updatedField = updated.map { #","updated_at":"\#($0)""# } ?? ""
    let resolvedField = resolved.map { #""\#($0)""# } ?? "null"
    return #"{"id":"\#(id)","name":"\#(name)","status":"\#(status)","impact":"\#(impact)","created_at":"\#(created)""#
        + updatedField + #","resolved_at":\#(resolvedField),"incident_updates":[],"components":[]}"#
}

@Suite struct StatusPageDecoderTests {
    @Test func sampleKeepsOnlyUnresolvedIncidents() throws {
        let incidents = try StatusPageDecoder.unresolvedIncidents(from: Data(ServiceStatusSimulator.sampleUnresolvedJSON.utf8))
        #expect(incidents.map(\.id) == ["demoactions01"])
        #expect(incidents.first?.impact == .minor)
        #expect(incidents.first?.status == .investigating)
        #expect(incidents.first?.updatedAt == ISO8601DateFormatter().date(from: "2026-11-13T09:35:00Z"))
    }

    @Test func everyUnresolvedStatusIsAnIncident() throws {
        let data = payload([raw("a1", status: "investigating"), raw("b2", status: "identified"),
                            raw("c3", status: "monitoring")])
        #expect(Set(try StatusPageDecoder.unresolvedIncidents(from: data).map(\.id)) == ["a1", "b2", "c3"])
    }

    @Test func maintenanceAndResolvedAreNeverIncidents() throws {
        let data = payload([
            raw("m1", status: "scheduled", impact: "maintenance"),
            raw("m2", status: "in_progress", impact: "maintenance"),
            raw("m3", status: "verifying", impact: "none"),
            raw("m4", status: "completed", impact: "minor"),
            raw("m5", status: "investigating", impact: "maintenance"),
            raw("r1", status: "resolved", impact: "major"),
            raw("r2", status: "postmortem", impact: "critical"),
            raw("r3", status: "monitoring", impact: "major", resolved: "2026-11-13T10:00:00Z"),
        ])
        #expect(try StatusPageDecoder.unresolvedIncidents(from: data).isEmpty)
    }

    @Test func emptyListDecodesAsNone() throws {
        #expect(try StatusPageDecoder.unresolvedIncidents(from: payload([])).isEmpty)
    }

    @Test func dedupesByIDKeepingLatestAndSortsBySeverity() throws {
        let data = payload([
            raw("a1", impact: "minor", updated: "2026-11-13T09:00:00Z", name: "Old"),
            raw("a1", impact: "major", updated: "2026-11-13T09:30:00Z", name: "New"),
            raw("b2", impact: "critical", updated: "2026-11-13T08:00:00Z"),
            raw("c3", impact: "none", updated: "2026-11-13T09:50:00Z"),
        ])
        let incidents = try StatusPageDecoder.unresolvedIncidents(from: data)
        #expect(incidents.map(\.id) == ["b2", "a1", "c3"])
        #expect(incidents[1].name == "New")
        #expect(incidents[1].impact == .major)
    }

    @Test func newerResolvedRecordRetiresOlderOpenOne() throws {
        let data = payload([
            raw("a1", status: "investigating", updated: "2026-11-13T09:00:00Z"),
            raw("a1", status: "resolved", updated: "2026-11-13T09:30:00Z", resolved: "2026-11-13T09:30:00Z"),
            raw("b2", status: "resolved", updated: "2026-11-13T09:00:00Z", resolved: "2026-11-13T09:00:00Z"),
            raw("b2", status: "identified", updated: "2026-11-13T09:30:00Z"),
        ])
        #expect(try StatusPageDecoder.unresolvedIncidents(from: data).map(\.id) == ["b2"])
    }

    @Test func missingUpdatedAtFallsBackToCreated() throws {
        let incidents = try StatusPageDecoder.unresolvedIncidents(from: payload([raw("a1", updated: nil)]))
        #expect(incidents.first?.updatedAt == ISO8601DateFormatter().date(from: "2026-11-13T09:10:00Z"))
    }

    @Test(arguments: [
        ("not json", StatusDecodeError.malformed),
        (#"{"incidents":[]}"#, .malformed),
        (#"{"page":{"id":"x"}}"#, .malformed),
        (#"{"page":{"id":""},"incidents":[]}"#, .malformed),
        (#"{"page":{"id":"x"},"incidents":{}}"#, .malformed),
        (#"[]"#, .malformed),
    ])
    func malformedPayloadsAreRejected(_ text: String, _ expected: StatusDecodeError) {
        #expect(throws: expected) { try StatusPageDecoder.unresolvedIncidents(from: Data(text.utf8)) }
    }

    @Test(arguments: [
        (raw("a1", status: "exploded"), "status"),
        (raw("a1", impact: "catastrophic"), "impact"),
        (raw("A1"), "id"),
        (raw("../x"), "id"),
        (raw(""), "id"),
        (raw(String(repeating: "a", count: 33)), "id"),
        (raw("a1", created: "yesterday"), "created_at"),
        (raw("a1", updated: "soon"), "updated_at"),
        (raw("a1", resolved: "garbage"), "resolved_at"),
        (raw("a1", name: "  "), "name"),
    ])
    func invalidIncidentRejectsWholePayload(_ incident: String, _ field: String) {
        // One bad incident alongside a good one: never a silently shorter list.
        #expect(throws: StatusDecodeError.invalidIncident(field)) {
            try StatusPageDecoder.unresolvedIncidents(from: payload([raw("good1"), incident]))
        }
    }

    @Test func missingRequiredFieldIsMalformed() {
        let data = payload([#"{"id":"a1","name":"x","status":"investigating","created_at":"2026-11-13T09:10:00Z"}"#])
        #expect(throws: StatusDecodeError.malformed) { try StatusPageDecoder.unresolvedIncidents(from: data) }
    }

    @Test func tooManyIncidentsIsRejected() {
        let many = (0...StatusPageDecoder.maxIncidents).map { raw("i\($0)") }
        #expect(throws: StatusDecodeError.tooManyIncidents) {
            try StatusPageDecoder.unresolvedIncidents(from: payload(many))
        }
    }

    @Test func namesAreSingleLineAndBounded() {
        #expect(StatusPageDecoder.sanitizedName("  Line one\nline\ttwo\u{0}  ") == "Line one line two")
        let long = StatusPageDecoder.sanitizedName(String(repeating: "x", count: 1000))
        #expect(long.count == StatusPageDecoder.maxNameLength)
        #expect(long.hasSuffix("…"))
    }
}

@Suite struct ServiceStatusLinkTests {
    @Test func incidentURLIsTheOnlyAcceptedShape() {
        #expect(ServiceStatusLink.incidentURL(id: "kctbh9vrtdwd")?.absoluteString
                == "https://www.githubstatus.com/incidents/kctbh9vrtdwd")
        #expect(incident("abc123").url?.absoluteString == "https://www.githubstatus.com/incidents/abc123")
    }

    @Test(arguments: [
        "http://www.githubstatus.com/incidents/abc123",
        "https://githubstatus.com/incidents/abc123",
        "https://www.githubstatus.com.evil.example/incidents/abc123",
        "https://evil.example/incidents/abc123",
        "https://github.com/incidents/abc123",
        "https://www.githubstatus.com/incidents/abc123?x=1",
        "https://www.githubstatus.com/incidents/abc123#top",
        "https://www.githubstatus.com:8443/incidents/abc123",
        "https://user:pw@www.githubstatus.com/incidents/abc123",
        "https://www.githubstatus.com/incidents/abc123/extra",
        "https://www.githubstatus.com/incidents/",
        "https://www.githubstatus.com/incidents/ABC123",
        "https://www.githubstatus.com/history",
        "https://www.githubstatus.com/api/v2/incidents/abc123",
        "javascript:alert(1)",
    ])
    func otherURLsAreRejected(_ text: String) {
        #expect(ServiceStatusLink.validated(URL(string: text)) == nil)
    }

    @Test func invalidIDsHaveNoURL() {
        for id in ["", "A1", "a/b", "a.b", "a b", "%2e%2e", String(repeating: "a", count: 33)] {
            #expect(ServiceStatusLink.incidentURL(id: id) == nil)
        }
        #expect(ServiceStatusLink.validated(nil as URL?) == nil)
    }
}

@Suite struct ServiceStatusMonitorTests {
    @Test func startsUnknownNotNone() {
        let monitor = ServiceStatusMonitor()
        #expect(monitor.state == .loading)
        #expect(!monitor.state.isFresh)
        #expect(monitor.state.statusText(count: 0) != ServiceStatusState.operational.statusText(count: 0))
    }

    @Test func freshNoneAndFreshIncidents() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([]), now: t0)
        #expect(monitor.state == .operational)
        #expect(monitor.state.statusText(count: 0) == "No active GitHub incidents")
        monitor.apply(.incidents([incident("a1")]), now: t0 + 60)
        #expect(monitor.state == .incidents)
        #expect(monitor.state.statusText(count: 1) == "1 active GitHub incident")
        #expect(monitor.state.statusText(count: 2) == "2 active GitHub incidents")
    }

    @Test func failureBeforeAnySuccessIsNotNone() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.failure("timed out"), now: t0)
        #expect(monitor.state == .error("timed out"))
        #expect(monitor.incidents.isEmpty)
        #expect(monitor.state != .operational)
        #expect(monitor.state.statusText(count: 0) == "GitHub status unavailable: timed out")
    }

    @Test func failureAfterNoneIsNotNone() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([]), now: t0)
        monitor.apply(.failure("HTTP 503"), now: t0 + 60)
        #expect(monitor.state == .error("HTTP 503"))
        #expect(!monitor.state.isFresh)
    }

    @Test func failureKeepsLastKnownIncidentsButNotForMood() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1", .major)]), now: t0)
        #expect(monitor.hasUrgentIncident)
        monitor.apply(.failure("offline"), now: t0 + 60)
        #expect(monitor.incidents.map(\.id) == ["a1"])
        #expect(!monitor.state.hasUsableIncidents)
        #expect(!monitor.hasUrgentIncident)
    }

    @Test func staleAfterThreshold() {
        let monitor = ServiceStatusMonitor(staleAfter: 600)
        monitor.apply(.incidents([]), now: t0)
        #expect(!monitor.refreshFreshness(now: t0 + 599))
        #expect(monitor.state == .operational)
        #expect(monitor.refreshFreshness(now: t0 + 600))
        #expect(monitor.state == .stale)
        #expect(monitor.state.statusText(count: 0) == "GitHub status is stale")
        #expect(!monitor.refreshFreshness(now: t0 + 700))
    }

    @Test func staleNeverAppliesBeforeASuccessOrAfterAnError() {
        let monitor = ServiceStatusMonitor(staleAfter: 600)
        #expect(!monitor.refreshFreshness(now: t0 + 9999))
        #expect(monitor.state == .loading)
        monitor.apply(.failure("x"), now: t0)
        monitor.markStale()
        #expect(monitor.state == .error("x"))
    }

    @Test func staleKeepsMajorIncidentUrgent() {
        let monitor = ServiceStatusMonitor(staleAfter: 600)
        monitor.apply(.incidents([incident("a1", .critical)]), now: t0)
        monitor.refreshFreshness(now: t0 + 601)
        #expect(monitor.state == .stale)
        #expect(monitor.hasUrgentIncident)
    }

    @Test func baselineDoesNotAnimate() {
        let monitor = ServiceStatusMonitor()
        #expect(monitor.apply(.incidents([incident("a1", .critical), incident("b2")]), now: t0).isEmpty)
        #expect(monitor.incidents.count == 2)
    }

    @Test func genuinelyNewIncidentAnimatesOnce() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1")]), now: t0)
        let events = monitor.apply(.incidents([incident("a1"), incident("b2")]), now: t0 + 60)
        #expect(events.map(\.item.id) == ["incident:b2"])
        #expect(events.first?.item.kind == .serviceIncident)
        #expect(monitor.apply(.incidents([incident("a1"), incident("b2")]), now: t0 + 120).isEmpty)
    }

    @Test func duplicateIDsInOnePollAreOneIncident() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([]), now: t0)
        let events = monitor.apply(.incidents([incident("b2", minutesAgo: 5), incident("b2", .major)]), now: t0 + 60)
        #expect(events.count == 1)
        #expect(monitor.incidents.count == 1)
        #expect(monitor.incidents.first?.impact == .major)
    }

    @Test func severityFollowsImpact() {
        #expect(IncidentImpact.none.severity == .actionable)
        #expect(IncidentImpact.minor.severity == .actionable)
        #expect(IncidentImpact.major.severity == .critical)
        #expect(IncidentImpact.critical.severity == .critical)
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([]), now: t0)
        let events = monitor.apply(.incidents([incident("n1", .none), incident("m1", .minor),
                                               incident("j1", .major), incident("c1", .critical)]), now: t0 + 60)
        let severities = Dictionary(uniqueKeysWithValues: events.map { ($0.item.id, $0.severity) })
        #expect(severities == ["incident:n1": .actionable, "incident:m1": .actionable,
                               "incident:j1": .critical, "incident:c1": .critical])
        // Most severe first, so the gesture leads with the urgent incident.
        #expect(events.first?.item.id == "incident:c1")
    }

    @Test func urgentOnlyForMajorOrCritical() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1", .minor), incident("b1", .none)]), now: t0)
        #expect(!monitor.hasUrgentIncident)
        monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 60)
        #expect(monitor.hasUrgentIncident)
    }

    @Test func updatesReviseSilently() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1", .minor, status: .investigating)]), now: t0)
        let events = monitor.apply(.incidents([incident("a1", .none, status: .monitoring, minutesAgo: -1,
                                                        name: "Renamed")]), now: t0 + 60)
        #expect(events.isEmpty)
        #expect(monitor.incidents.first?.status == .monitoring)
        #expect(monitor.incidents.first?.name == "Renamed")
    }

    @Test func escalationIsAnnouncedOncePerTierReached() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1", .minor)]), now: t0)
        #expect(monitor.apply(.incidents([incident("a1", .none)]), now: t0 + 30).isEmpty)   // same tier
        let events = monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 60)
        #expect(events.map(\.item.id) == ["incident:a1"])
        #expect(events.first?.severity == .critical)
        // Major → critical is a new tier (#37 parity): announced once.
        #expect(monitor.apply(.incidents([incident("a1", .critical)]), now: t0 + 120).count == 1)
        // Downgrades and returns to tiers already reached stay silent.
        #expect(monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 180).isEmpty)
        #expect(monitor.apply(.incidents([incident("a1", .critical)]), now: t0 + 240).isEmpty)
        #expect(monitor.apply(.incidents([incident("a1", .minor)]), now: t0 + 300).isEmpty)
        #expect(monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 360).isEmpty)
    }

    @Test func minorStraightToCriticalIsOneEvent() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1", .minor)]), now: t0)
        #expect(monitor.apply(.incidents([incident("a1", .critical)]), now: t0 + 60).count == 1)
        #expect(monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 120).isEmpty)
    }

    @Test func newMajorIncidentEscalatesOnlyToCritical() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([]), now: t0)
        #expect(monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 60).count == 1)
        #expect(monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 90).isEmpty)
        #expect(monitor.apply(.incidents([incident("a1", .critical)]), now: t0 + 120).count == 1)
    }

    @Test func tierReachedWhileNotComparableIsNeverAnnounced() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1", .minor)]), now: t0)
        monitor.apply(.failure("offline"), now: t0 + 30)
        #expect(monitor.apply(.incidents([incident("a1", .critical)]), now: t0 + 60).isEmpty)   // reconnect
        #expect(monitor.apply(.incidents([incident("a1", .critical)]), now: t0 + 120).isEmpty)
        #expect(monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 180).isEmpty)
    }

    @Test func recoveryLeavesWithoutAnimation() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([]), now: t0)
        monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 60)
        let events = monitor.apply(.incidents([]), now: t0 + 120)
        #expect(events.isEmpty)
        #expect(monitor.incidents.isEmpty)
        #expect(monitor.state == .operational)
        #expect(!monitor.hasUrgentIncident)
        // A resolved incident reopening under the same ID is not new.
        #expect(monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 180).isEmpty)
    }

    @Test func reopeningAtHigherImpactIsNotAnEscalation() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1", .minor)]), now: t0)
        monitor.apply(.incidents([]), now: t0 + 60)
        #expect(monitor.apply(.incidents([incident("a1", .major)]), now: t0 + 120).isEmpty)
        #expect(monitor.hasUrgentIncident)
    }

    @Test func errorReconnectDoesNotReplay() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1")]), now: t0)
        monitor.apply(.failure("offline"), now: t0 + 60)
        // Incidents opened (or escalated) while we could not see are recorded silently.
        let events = monitor.apply(.incidents([incident("a1", .critical), incident("b2", .major)]), now: t0 + 120)
        #expect(events.isEmpty)
        #expect(monitor.state == .incidents)
        #expect(monitor.apply(.incidents([incident("a1", .critical), incident("b2", .major)]), now: t0 + 180).isEmpty)
        // After the silent recovery, a later new incident animates again.
        #expect(monitor.apply(.incidents([incident("a1"), incident("b2"), incident("c3")]), now: t0 + 240).count == 1)
    }

    @Test func staleReconnectDoesNotReplay() {
        let monitor = ServiceStatusMonitor(staleAfter: 600)
        monitor.apply(.incidents([]), now: t0)
        monitor.refreshFreshness(now: t0 + 700)
        #expect(monitor.apply(.incidents([incident("b2", .major)]), now: t0 + 710).isEmpty)
        #expect(monitor.state == .incidents)
    }

    @Test func oldLastSuccessIsNotComparableEvenWithoutAFreshnessTick() {
        // E.g. after sleep: the timer that marks stale may not have run before the next poll.
        let monitor = ServiceStatusMonitor(staleAfter: 600)
        monitor.apply(.incidents([]), now: t0)
        #expect(monitor.apply(.incidents([incident("b2")]), now: t0 + 601).isEmpty)
        // Clock moved backwards: not comparable either.
        #expect(monitor.apply(.incidents([incident("b2"), incident("c3")]), now: t0).isEmpty)
    }

    @Test func markStaleBreaksComparability() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([]), now: t0)
        monitor.markStale()
        #expect(monitor.state == .stale)
        #expect(monitor.apply(.incidents([incident("b2")]), now: t0 + 10).isEmpty)
    }

    @Test func resetForgetsEverythingAndRebaselines() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1")]), now: t0)
        monitor.reset()
        #expect(monitor.state == .loading)
        #expect(monitor.incidents.isEmpty)
        #expect(monitor.lastSuccess == nil)
        #expect(monitor.apply(.incidents([incident("b2")]), now: t0 + 60).isEmpty)
    }

    @Test func resetBaselineKeepsRowsButReseedsSilently() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([incident("a1")]), now: t0)
        monitor.resetBaseline()
        #expect(monitor.incidents.count == 1)
        #expect(monitor.apply(.incidents([incident("a1"), incident("b2")]), now: t0 + 60).isEmpty)
        #expect(monitor.apply(.incidents([incident("a1"), incident("b2"), incident("c3")]), now: t0 + 120).count == 1)
    }

    @Test func invalidIDsNeverEnterTheMonitor() {
        let monitor = ServiceStatusMonitor()
        monitor.apply(.incidents([]), now: t0)
        #expect(monitor.apply(.incidents([incident("../evil"), incident("")]), now: t0 + 60).isEmpty)
        #expect(monitor.incidents.isEmpty)
    }

    @Test func boundedMemoryEvictsOldestNotCurrent() {
        let monitor = ServiceStatusMonitor(capacity: 2)
        monitor.apply(.incidents([incident("a1")]), now: t0)
        monitor.apply(.incidents([incident("a1"), incident("b2")]), now: t0 + 10)
        monitor.apply(.incidents([incident("a1"), incident("c3")]), now: t0 + 20)   // evicts b2, keeps a1
        #expect(monitor.apply(.incidents([incident("a1"), incident("c3")]), now: t0 + 30).isEmpty)
    }
}

@Suite struct ServiceStatusPolicyTests {
    private func monitor(_ outcomes: [ServiceStatusOutcome]) -> ServiceStatusMonitor {
        let monitor = ServiceStatusMonitor()
        for (index, outcome) in outcomes.enumerated() { monitor.apply(outcome, now: t0 + Double(index)) }
        return monitor
    }

    @Test func majorIncidentMakesTheMascotUrgent() {
        let m = monitor([.incidents([incident("a1", .major)])])
        #expect(ServiceStatusPolicy.mood(base: .idle, monitor: m, unseenIncidents: 0, alertsAllowed: false) == .urgent)
    }

    @Test func minorIncidentAloneStaysIdle() {
        let m = monitor([.incidents([incident("a1", .minor)])])
        #expect(ServiceStatusPolicy.mood(base: .idle, monitor: m, unseenIncidents: 0, alertsAllowed: true) == .idle)
    }

    @Test func unseenIncidentNeedsAlertsAllowed() {
        let m = monitor([.incidents([incident("a1", .minor)])])
        #expect(ServiceStatusPolicy.mood(base: .idle, monitor: m, unseenIncidents: 1, alertsAllowed: true) == .attention)
        // Snoozed or quiet hours: the row still shows, but the mascot stays calm.
        #expect(ServiceStatusPolicy.mood(base: .idle, monitor: m, unseenIncidents: 1, alertsAllowed: false) == .idle)
    }

    @Test func failureNeverChangesTheMoodByItself() {
        let m = monitor([.incidents([incident("a1", .critical)]), .failure("offline")])
        #expect(ServiceStatusPolicy.mood(base: .idle, monitor: m, unseenIncidents: 0, alertsAllowed: true) == .idle)
        #expect(ServiceStatusPolicy.mood(base: .attention, monitor: m, unseenIncidents: 0, alertsAllowed: true) == .attention)
    }

    @Test func inboxMoodIsKept() {
        let m = monitor([.incidents([])])
        #expect(ServiceStatusPolicy.mood(base: .urgent, monitor: m, unseenIncidents: 0, alertsAllowed: true) == .urgent)
        #expect(ServiceStatusPolicy.mood(base: .attention, monitor: m, unseenIncidents: 0, alertsAllowed: true) == .attention)
    }

    @Test func urgentIncidentGesturePlaysUrgentAndRespectsMotionSettings() {
        let m = ServiceStatusMonitor()
        m.apply(.incidents([]), now: t0)
        let events = m.apply(.incidents([incident("a1", .critical)]), now: t0 + 1)
        var queue = EventClipQueue()
        queue.enqueue(events, now: t0 + 1, playable: true)
        #expect(queue.active?.state == .urgent)
        var still = EventClipQueue()
        still.enqueue(events, now: t0 + 1, playable: false)   // reduced motion, snooze or quiet hours
        #expect(still.active == nil)
    }

    @Test func incidentRowsFollowPrivacy() {
        let item = incident("a1", name: "Degraded Actions").inboxItem
        #expect(item.id == "incident:a1")
        #expect(PrivacyText.title(item, privacy: true) == "GitHub service incident")
        #expect(PrivacyText.title(item, privacy: false) == "Degraded Actions")
        #expect(item.url?.absoluteString == "https://www.githubstatus.com/incidents/a1")
    }

    @Test func demoIncidentsOpenNothing() {
        var demo = incident("demoactions01")
        demo.isDemo = true
        #expect(demo.url == nil)
        #expect(demo.inboxItem.url == nil)
        #expect(ServiceStatusSimulator.defaultIncidents().allSatisfy { $0.url == nil })
    }
}

@Suite struct ServiceStatusSimulatorTests {
    @Test func defaultFixtureIsDemoAndExcludesMaintenance() {
        let incidents = ServiceStatusSimulator.defaultIncidents()
        #expect(incidents.map(\.id) == ["demoactions01"])
        #expect(incidents.allSatisfy { $0.isDemo })
        #expect(ServiceStatusSimulator().poll() == .incidents(incidents))
    }

    @Test func injectedIncidentsHaveUniqueValidIDs() {
        var counter = 0
        let simulator = ServiceStatusSimulator(incidents: []) {
            counter += 1
            return "ABCD-\(counter)-ef"
        }
        let a = simulator.injectIncident(impact: .major, now: t0)
        let b = simulator.injectIncident(impact: .minor, now: t0)
        #expect(a.id != b.id)
        #expect(ServiceStatusLink.isValidIncidentID(a.id))
        #expect(a.isDemo && a.status == .investigating)
        #expect(simulator.incidents.count == 2)
    }

    @Test func disconnectEscalateAndResolve() {
        let simulator = ServiceStatusSimulator()
        simulator.connected = false
        #expect(simulator.poll() == .failure("simulated disconnect"))
        simulator.connected = true
        simulator.escalateAll(now: t0)
        #expect(simulator.incidents.allSatisfy { $0.impact == .major })
        simulator.resolveAll()
        #expect(simulator.poll() == .incidents([]))
    }
}

// MARK: Client

private struct FakeTransport: StatusTransport {
    var result: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) { try result(request) }
}

private func response(_ code: Int = 200, type: String? = "application/json; charset=utf-8",
                      url: URL = ServiceStatusClient.endpoint) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                    headerFields: type.map { ["Content-Type": $0] } ?? [:])!
}

private func client(maxBytes: Int = ServiceStatusClient.defaultMaxBytes,
                    _ result: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) -> ServiceStatusClient {
    ServiceStatusClient(transport: FakeTransport(result: result), maxBytes: maxBytes)
}

@Suite struct ServiceStatusClientTests {
    @Test func endpointIsTheOfficialUnauthenticatedAPI() {
        #expect(ServiceStatusClient.endpoint.absoluteString == "https://www.githubstatus.com/api/v2/incidents/unresolved.json")
        #expect(ServiceStatusClient.isAllowed(ServiceStatusClient.endpoint))
    }

    @Test func successDecodesAndSendsNoCredentials() async {
        let outcome = await client { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url == ServiceStatusClient.endpoint)
            #expect(request.httpShouldHandleCookies == false)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.timeoutInterval == ServiceStatusClient.defaultTimeout)
            return (payload([raw("a1", impact: "major")]), response())
        }.fetch()
        #expect(outcome == .incidents([ServiceIncident(id: "a1", name: "Degraded Actions", status: .investigating,
                                                       impact: .major,
                                                       updatedAt: StatusPageDecoder.date("2026-11-13T09:35:00Z")!)]))
    }

    @Test func emptyIsAVerifiedNone() async {
        #expect(await client { _ in (payload([]), response()) }.fetch() == .incidents([]))
    }

    @Test(arguments: [
        ("http://www.githubstatus.com/api/v2/incidents/unresolved.json"),
        ("https://githubstatus.com/api/v2/incidents/unresolved.json"),
        ("https://evil.example/api/v2/incidents/unresolved.json"),
        ("https://www.githubstatus.com:8443/api/v2/incidents/unresolved.json"),
    ])
    func endpointOutsideTheAllowlistIsNeverRequested(_ text: String) async {
        let client = ServiceStatusClient(endpoint: URL(string: text)!, transport: FakeTransport { _ in
            Issue.record("transport must not be called")
            return (payload([]), response())
        })
        #expect(await client.fetch() == .failure("unexpected host"))
    }

    @Test func redirectedResponseFromAnotherHostIsRejected() async {
        let outcome = await client { _ in (payload([]), response(url: URL(string: "https://evil.example/x.json")!)) }.fetch()
        #expect(outcome == .failure("unexpected host"))
    }

    @Test(arguments: [301, 404, 429, 500, 503])
    func httpErrorsAreFailures(_ code: Int) async {
        #expect(await client { _ in (payload([]), response(code)) }.fetch() == .failure("HTTP \(code)"))
    }

    @Test(arguments: [nil, "text/html", "application/jsonp", "text/json", ""] as [String?])
    func nonJSONIsAFailure(_ type: String?) async {
        #expect(await client { _ in (payload([]), response(type: type)) }.fetch() == .failure("unexpected response type"))
    }

    @Test(arguments: ["application/json", "Application/JSON; charset=utf-8", "application/json ;charset=UTF-8"])
    func jsonMediaTypeIsAccepted(_ type: String) async {
        #expect(await client { _ in (payload([]), response(type: type)) }.fetch() == .incidents([]))
    }

    @Test func oversizeBodyIsAFailure() async {
        let outcome = await client(maxBytes: 64) { _ in (payload([raw("a1")]), response()) }.fetch()
        #expect(outcome == .failure("response too large"))
    }

    @Test func undecodableBodyIsAFailureNotNone() async {
        #expect(await client { _ in (Data("{}".utf8), response()) }.fetch() == .failure("unreadable response"))
        #expect(await client { _ in (payload([raw("a1", status: "weird")]), response()) }.fetch()
                == .failure("unreadable response"))
    }

    @Test(arguments: [
        (URLError.Code.timedOut, "timed out"),
        (.notConnectedToInternet, "offline"),
        (.httpTooManyRedirects, "unexpected host"),
        (.cannotFindHost, "network error \(URLError.Code.cannotFindHost.rawValue)"),
    ])
    func transportErrorsAreFailures(_ code: URLError.Code, _ message: String) async {
        #expect(await client { _ in throw URLError(code) }.fetch() == .failure(message))
    }

    @Test func unexpectedErrorsAreFailures() async {
        struct Odd: Error {}
        #expect(await client { _ in throw Odd() }.fetch() == .failure("request failed"))
    }
}

// MARK: URLSession transport (stubbed, never touches the network)

/// Per-URL canned behaviour for `StubProtocol`, so parallel tests do not interfere.
private final class StubRegistry: @unchecked Sendable {
    enum Behaviour { case respond(Int, [String: String], Data), hang, drip(TimeInterval) }
    static let shared = StubRegistry()
    private let lock = NSLock()
    private var behaviours: [URL: Behaviour] = [:]
    private var seen: [URL: URLRequest] = [:]

    func set(_ behaviour: Behaviour, for url: URL) { lock.withLock { behaviours[url] = behaviour } }
    func behaviour(for url: URL) -> Behaviour? { lock.withLock { behaviours[url] } }
    func record(_ request: URLRequest) { lock.withLock { if let url = request.url { seen[url] = request } } }
    func request(for url: URL) -> URLRequest? { lock.withLock { seen[url] } }
}

private final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let behaviour = StubRegistry.shared.behaviour(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        StubRegistry.shared.record(request)
        switch behaviour {
        case .hang:
            break   // never answers: the session's request timeout must fire
        case .drip(let interval):
            // One byte per interval, forever: the inactivity timer never fires, only the deadline.
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            drip(every: interval)
        case .respond(let code, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            if (300..<400).contains(code), let location = headers["Location"], let target = URL(string: location) {
                // Offer the redirect; the transport must refuse it.
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Several chunks, so the size cap is enforced while streaming.
            var offset = 0
            while offset < body.count {
                let end = min(offset + 1024, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private let stopLock = NSLock()
    private var stopped = false

    private func drip(every interval: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, !self.stopLock.withLock({ self.stopped }) else { return }
            self.client?.urlProtocol(self, didLoad: Data("[".utf8))
            self.drip(every: interval)
        }
    }

    override func stopLoading() { stopLock.withLock { stopped = true } }
}

/// CI runners have been seen stalling the whole test process for 25–40 s, so only the hanging
/// case relies on a short timeout; everything else gets one far beyond any stall.
private func stubTransport(timeout: TimeInterval = 120) -> URLSessionStatusTransport {
    URLSessionStatusTransport(timeout: timeout) { $0.protocolClasses = [StubProtocol.self] }
}

private func stubURL(_ name: String) -> URL {
    URL(string: "https://www.githubstatus.com/stub/\(name)-\(UUID().uuidString.lowercased()).json")!
}

/// Transport pieces checked without URLSession, independent of runner timing.
@Suite struct StatusTransportUnitTests {
    private struct Bytes: AsyncSequence {
        typealias Element = UInt8
        var data: Data
        struct AsyncIterator: AsyncIteratorProtocol {
            var iterator: Data.Iterator
            mutating func next() async -> UInt8? { iterator.next() }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(iterator: data.makeIterator()) }
    }

    @Test func collectEnforcesTheCap() async throws {
        let body = Data(repeating: 7, count: 4096)
        #expect(try await URLSessionStatusTransport.collect(Bytes(data: body), expectedLength: -1, maxBytes: 4096) == body)
        await #expect(throws: StatusFetchError.tooLarge) {
            _ = try await URLSessionStatusTransport.collect(Bytes(data: body + Data([1])), expectedLength: -1, maxBytes: 4096)
        }
        await #expect(throws: StatusFetchError.tooLarge) {
            _ = try await URLSessionStatusTransport.collect(Bytes(data: Data()), expectedLength: 4097, maxBytes: 4096)
        }
    }

    @Test func configurationKeepsNoState() {
        let config = URLSessionStatusTransport(timeout: 15).configuration
        #expect(config.httpCookieStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(config.timeoutIntervalForRequest == 15)
        #expect(config.timeoutIntervalForResource == 15)
        #expect(config.waitsForConnectivity == false)
        #expect(config.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    @Test func redirectsAreRefused() {
        let transport = URLSessionStatusTransport(timeout: 15)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: ServiceStatusClient.endpoint)
        let redirect = HTTPURLResponse(url: ServiceStatusClient.endpoint, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://evil.example/"])!
        var followed: URLRequest? = URLRequest(url: URL(string: "https://placeholder.invalid")!)
        transport.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                             newRequest: URLRequest(url: URL(string: "https://evil.example/")!)) { followed = $0 }
        #expect(followed == nil)
    }

    @Test(arguments: [(NSURLAuthenticationMethodHTTPBasic, URLSession.AuthChallengeDisposition.cancelAuthenticationChallenge),
                      (NSURLAuthenticationMethodClientCertificate, .cancelAuthenticationChallenge),
                      (NSURLAuthenticationMethodServerTrust, .performDefaultHandling)])
    func onlyServerTrustIsHandled(_ method: String, _ expected: URLSession.AuthChallengeDisposition) {
        let transport = URLSessionStatusTransport(timeout: 15)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let space = URLProtectionSpace(host: ServiceStatusLink.host, port: 443, protocol: "https", realm: nil,
                                       authenticationMethod: method)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                                   previousFailureCount: 0, failureResponse: nil, error: nil,
                                                   sender: ChallengeSender())
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?
        transport.urlSession(session, task: session.dataTask(with: ServiceStatusClient.endpoint),
                             didReceive: challenge) { disposition = $0; credential = $1 }
        #expect(disposition == expected)
        #expect(credential == nil)
    }

    private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }
}

@Suite struct URLSessionStatusTransportTests {
    @Test func returnsBodyAndSendsNoCookiesOrCredentials() async throws {
        let url = stubURL("ok")
        let body = payload([raw("a1")])
        StubRegistry.shared.set(.respond(200, ["Content-Type": "application/json"], body), for: url)
        let (data, response) = try await stubTransport().get(URLRequest(url: url), maxBytes: 1 << 20)
        #expect(data == body)
        #expect(response.statusCode == 200)
        let sent = try #require(StubRegistry.shared.request(for: url))
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func oversizeStreamIsAbandoned() async {
        let url = stubURL("big")
        StubRegistry.shared.set(.respond(200, ["Content-Type": "application/json"], Data(count: 10_000)), for: url)
        await #expect(throws: StatusFetchError.tooLarge) {
            _ = try await stubTransport().get(URLRequest(url: url), maxBytes: 4096)
        }
    }

    @Test func declaredOversizeIsRejectedBeforeReading() async {
        let url = stubURL("declared")
        StubRegistry.shared.set(.respond(200, ["Content-Type": "application/json", "Content-Length": "10000"],
                                         Data(count: 10_000)), for: url)
        await #expect(throws: StatusFetchError.tooLarge) {
            _ = try await stubTransport().get(URLRequest(url: url), maxBytes: 4096)
        }
    }

    @Test func exactlyMaxBytesIsAccepted() async throws {
        let url = stubURL("exact")
        StubRegistry.shared.set(.respond(200, ["Content-Type": "application/json"], Data(count: 4096)), for: url)
        let (data, _) = try await stubTransport().get(URLRequest(url: url), maxBytes: 4096)
        #expect(data.count == 4096)
    }

    // Wall-clock guard: a broken timeout fails the test instead of hanging CI.
    @Test(.timeLimit(.minutes(1))) func hangingServerTimesOut() async {
        let url = stubURL("hang")
        StubRegistry.shared.set(.hang, for: url)
        await #expect {
            _ = try await stubTransport(timeout: 0.5).get(URLRequest(url: url, timeoutInterval: 0.5), maxBytes: 4096)
        } throws: { error in
            (error as? URLError)?.code == .timedOut
        }
    }

    /// The timeout bounds the whole fetch (resource deadline), not just inactivity.
    @Test(.timeLimit(.minutes(1))) func slowDripHitsTheTotalDeadline() async {
        let url = stubURL("drip")
        StubRegistry.shared.set(.drip(0.3), for: url)
        let started = Date()
        await #expect {
            _ = try await stubTransport(timeout: 2).get(URLRequest(url: url, timeoutInterval: 2), maxBytes: 1 << 20)
        } throws: { error in
            (error as? URLError)?.code == .timedOut
        }
        // At least the deadline; the upper bound is the time limit (CI stalls make a tight bound flaky).
        #expect(Date().timeIntervalSince(started) >= 1.9)
    }

    @Test func redirectsAreNotFollowed() async throws {
        let url = stubURL("redirect")
        let target = stubURL("target")
        StubRegistry.shared.set(.respond(302, ["Location": target.absoluteString], Data()), for: url)
        StubRegistry.shared.set(.respond(200, ["Content-Type": "application/json"], payload([])), for: target)
        let (_, response) = try await stubTransport().get(URLRequest(url: url), maxBytes: 4096)
        #expect(response.statusCode == 302)
        #expect(StubRegistry.shared.request(for: target) == nil)
    }

    @Test func clientMapsTransportTimeout() async {
        let url = stubURL("client-hang")
        StubRegistry.shared.set(.hang, for: url)
        let client = ServiceStatusClient(endpoint: url, transport: stubTransport(timeout: 0.5), timeout: 0.5)
        #expect(await client.fetch() == .failure("timed out"))
    }
}

/// Each Simulator action, through the real decoder, monitor and marker: event or no event.
@Suite struct ServiceStatusSimulatorActionTests {
    private final class Harness {
        let simulator: ServiceStatusSimulator
        let monitor = ServiceStatusMonitor()
        var now = t0

        init(_ incidents: [ServiceIncident] = []) {
            var counter = 0
            simulator = ServiceStatusSimulator(incidents: incidents) {
                counter += 1
                return String(format: "%012d", counter)
            }
            poll()   // baseline
        }

        @discardableResult
        func poll() -> [InboxEvent] {
            now += 30
            return monitor.apply(simulator.poll(), now: now)
        }

        var marker: IncidentMarker? { IncidentMarker.current(state: monitor.state, incidents: monitor.incidents) }
    }

    @Test func injectEachTierIsANewUrgentOrAttentionEvent() {
        let h = Harness()
        h.simulator.injectIncident(impact: .critical, now: h.now)
        let events = h.poll()
        #expect(events.count == 1)
        #expect(events.first?.severity == .critical)
        #expect(h.marker?.tier == .critical)
        #expect(h.monitor.incidents.first?.name == "Major outage: github.com")
        h.simulator.injectIncident(impact: .minor, now: h.now)
        #expect(h.poll().first?.severity == .actionable)
        h.simulator.injectIncident(impact: .major, now: h.now)
        #expect(h.poll().first?.severity == .critical)
        #expect(h.monitor.incidents.count == 3)
        #expect(Set(h.monitor.incidents.map(\.id)).count == 3)
    }

    @Test func escalateOneLevelBurstsOncePerTierAndDeescalateIsSilent() {
        let h = Harness()
        h.simulator.injectIncident(impact: .minor, now: h.now)
        #expect(h.poll().count == 1)                           // new
        h.simulator.escalateOneLevel(now: h.now)
        #expect(h.poll().count == 1)                           // minor -> major
        #expect(h.marker?.tier == .major)
        h.simulator.escalateOneLevel(now: h.now)
        #expect(h.poll().count == 1)                           // major -> critical
        #expect(h.marker?.tier == .critical)
        h.simulator.escalateOneLevel(now: h.now)
        #expect(h.poll().isEmpty)                              // already critical
        h.simulator.deescalateOneLevel(now: h.now)
        #expect(h.poll().isEmpty)                              // critical -> major: silent
        #expect(h.marker?.tier == .major)
        h.simulator.deescalateOneLevel(now: h.now)
        #expect(h.poll().isEmpty)                              // major -> minor: silent
        #expect(h.marker?.tier == .minor)
        h.simulator.escalateOneLevel(now: h.now)
        #expect(h.poll().isEmpty)                              // back to major: tier already reached
    }

    @Test func escalateAllToMajorStillWorks() {
        let h = Harness()
        h.simulator.injectIncident(impact: .minor, now: h.now)
        h.poll()
        h.simulator.escalateAll(now: h.now)
        #expect(h.poll().count == 1)
        #expect(h.simulator.incidents.allSatisfy { $0.impact == .major })
    }

    @Test func resolveIsQuietAndReopenIsSilent() {
        let h = Harness()
        h.simulator.injectIncident(impact: .major, now: h.now)
        h.poll()
        #expect(!h.simulator.canReopen)
        h.simulator.resolveAll(now: h.now)
        #expect(h.poll().isEmpty)
        #expect(h.monitor.state == .operational)
        #expect(h.marker == nil)
        #expect(h.simulator.canReopen)
        #expect(h.simulator.reopenLastResolved(now: h.now))
        #expect(h.poll().isEmpty)                              // same ID: silent
        #expect(h.marker?.tier == .major)
        #expect(!h.simulator.reopenLastResolved(now: h.now))   // nothing left to reopen
    }

    @Test func scheduledMaintenanceIsNeverAnIncident() {
        let h = Harness()
        h.simulator.injectMaintenance(now: h.now)
        #expect(h.poll().isEmpty)
        #expect(h.monitor.incidents.isEmpty)
        #expect(h.monitor.state == .operational)
        #expect(h.marker == nil)
        h.simulator.injectIncident(impact: .minor, now: h.now)
        h.poll()
        h.simulator.injectMaintenance(now: h.now)
        #expect(h.poll().isEmpty)
        #expect(h.monitor.incidents.count == 1)
        // Escalating never turns maintenance into an incident.
        h.simulator.escalateOneLevel(now: h.now)
        h.poll()
        #expect(h.monitor.incidents.count == 1)
    }

    @Test func statusFetchFailureIsNeverNoIncidentsAndRecoveryIsSilent() {
        let h = Harness()
        h.simulator.injectIncident(impact: .major, now: h.now)
        h.poll()
        h.simulator.fetchFails = true
        #expect(h.poll().isEmpty)
        #expect(h.monitor.state == .error("simulated status fetch failure"))
        #expect(h.monitor.incidents.count == 1)                // last known, dimmed
        #expect(h.marker == nil)
        #expect(!h.monitor.hasUrgentIncident)
        // Opened while failing: recorded silently on recovery.
        h.simulator.injectIncident(impact: .critical, now: h.now)
        h.simulator.fetchFails = false
        #expect(h.poll().isEmpty)
        #expect(h.monitor.state == .incidents)
        #expect(h.marker?.tier == .critical)
    }

    @Test func fetchFailureBeforeAnySuccessIsUnknown() {
        let simulator = ServiceStatusSimulator(incidents: [])
        simulator.fetchFails = true
        let monitor = ServiceStatusMonitor()
        monitor.apply(simulator.poll(), now: t0)
        #expect(monitor.state != .operational)
        #expect(!monitor.state.isFresh)
    }

    @Test func markStaleHidesTheMarkerAndRecoveryIsSilent() {
        let h = Harness()
        h.simulator.injectIncident(impact: .minor, now: h.now)
        h.poll()
        h.monitor.markStale()
        #expect(h.monitor.state == .stale)
        #expect(h.marker == nil)
        h.simulator.injectIncident(impact: .major, now: h.now)
        #expect(h.poll().isEmpty)
        #expect(h.marker?.tier == .major)
    }

    @Test func disconnectFailsTheServiceSourceToo() {
        let simulator = ServiceStatusSimulator()
        simulator.connected = false
        #expect(simulator.poll() == .failure("simulated disconnect"))
    }
}
