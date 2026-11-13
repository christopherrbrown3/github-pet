import Foundation

/// Offline GitHub Status source for development and QA (the default, like inbox fixtures).
/// Its baseline comes from a Statuspage-shaped sample decoded by the real `StatusPageDecoder`,
/// and QA can inject, escalate and resolve incidents or simulate a failed fetch.
public final class ServiceStatusSimulator {
    public private(set) var incidents: [ServiceIncident]
    public var connected = true
    private let makeID: () -> String

    public init(incidents: [ServiceIncident] = ServiceStatusSimulator.defaultIncidents(),
                makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.incidents = incidents
        self.makeID = makeID
    }

    public func poll() -> ServiceStatusOutcome {
        connected ? .incidents(incidents) : .failure("simulated disconnect")
    }

    /// Add one unresolved incident with a never-before-used Statuspage-style ID.
    @discardableResult
    public func injectIncident(impact: IncidentImpact, now: Date = Date()) -> ServiceIncident {
        let token = String(makeID().filter { $0.isLetter || $0.isNumber }.lowercased().prefix(12))
        let incident = ServiceIncident(id: "demo\(token)", name: "Fixture incident: degraded service (\(token.prefix(8)))",
                                       status: .investigating, impact: impact, updatedAt: now, isDemo: true)
        incidents = StatusPageDecoder.dedupe(incidents + [incident])
        return incident
    }

    /// Raise every incident to major impact (escalation).
    public func escalateAll(now: Date = Date()) {
        incidents = StatusPageDecoder.dedupe(incidents.map {
            var copy = $0
            if copy.impact < .major { copy.impact = .major }
            copy.updatedAt = now
            return copy
        })
    }

    /// Resolve everything: the next poll reports no unresolved incidents.
    public func resolveAll() {
        incidents = []
    }

    /// Statuspage `incidents/unresolved.json` sample: one minor incident plus scheduled maintenance
    /// and a resolved incident, which must both be excluded.
    public static let sampleUnresolvedJSON = """
    {
      "page": {"id": "demopage0001", "name": "GitHub (Demo)", "url": "https://www.githubstatus.com",
               "time_zone": "Etc/UTC", "updated_at": "2026-11-13T09:40:00.000Z"},
      "incidents": [
        {"id": "demoactions01", "name": "Demo: Delayed GitHub Actions job starts", "status": "investigating",
         "impact": "minor", "created_at": "2026-11-13T09:10:00.000Z", "updated_at": "2026-11-13T09:35:00.000Z",
         "monitoring_at": null, "resolved_at": null, "shortlink": "https://stspg.io/demo",
         "incident_updates": [], "components": []},
        {"id": "demomaint0001", "name": "Demo: Scheduled database maintenance", "status": "scheduled",
         "impact": "maintenance", "created_at": "2026-11-13T08:00:00.000Z", "updated_at": "2026-11-13T08:00:00.000Z",
         "monitoring_at": null, "resolved_at": null},
        {"id": "demoresolved1", "name": "Demo: Resolved incident", "status": "resolved",
         "impact": "major", "created_at": "2026-11-13T07:00:00.000Z", "updated_at": "2026-11-13T07:30:00.000Z",
         "monitoring_at": null, "resolved_at": "2026-11-13T07:30:00.000Z"}
      ]
    }
    """

    public static func defaultIncidents() -> [ServiceIncident] {
        let decoded = (try? StatusPageDecoder.unresolvedIncidents(from: Data(sampleUnresolvedJSON.utf8))) ?? []
        return decoded.map {
            var copy = $0
            copy.isDemo = true
            return copy
        }
    }
}
