import Foundation

/// Offline GitHub Status source for development and QA (the default, like inbox fixtures).
///
/// It keeps raw Statuspage records (open incidents, resolved ones and scheduled maintenance), and
/// every poll goes through the real `StatusPageDecoder` as JSON, so maintenance and resolved records
/// are filtered exactly as they are live. QA can inject any tier, escalate or de-escalate one level,
/// reopen, add maintenance, and make the status fetch fail or go stale, for this source only.
public final class ServiceStatusSimulator {
    /// One Statuspage incident record as the API would report it.
    public struct Record: Equatable, Sendable {
        public var id: String
        public var name: String
        public var status: IncidentStatus
        public var impact: IncidentImpact
        public var updatedAt: Date
        public var resolvedAt: Date?
    }

    public private(set) var records: [Record]
    /// Whole-simulator disconnect (inbox and service), from "Simulate disconnect".
    public var connected = true
    /// Service-status fetch failure only ("Status fetch fails").
    public var fetchFails = false
    private var resolvedOrder: [String] = []
    private let makeID: () -> String

    public init(incidents: [ServiceIncident] = ServiceStatusSimulator.defaultIncidents(),
                makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        records = incidents.map {
            Record(id: $0.id, name: $0.name, status: $0.status, impact: $0.impact, updatedAt: $0.updatedAt, resolvedAt: nil)
        }
        self.makeID = makeID
    }

    /// Unresolved incidents as the next successful poll would report them.
    public var incidents: [ServiceIncident] {
        if case .incidents(let list) = decode() { return list }
        return []
    }

    public func poll() -> ServiceStatusOutcome {
        guard connected else { return .failure("simulated disconnect") }
        guard !fetchFails else { return .failure("simulated status fetch failure") }
        return decode()
    }

    /// Fixed names per tier (Demo data), so snapshots are deterministic.
    public static func name(for impact: IncidentImpact) -> String {
        switch impact {
        case .critical: return "Major outage: github.com"
        case .major: return "Git operations outage"
        case .maintenance: return "Scheduled maintenance"
        default: return "Actions degraded"
        }
    }

    /// Add one unresolved incident with a never-before-used Statuspage-style ID.
    @discardableResult
    public func injectIncident(impact: IncidentImpact, now: Date = Date()) -> ServiceIncident {
        let id = newID()
        records.append(Record(id: id, name: Self.name(for: impact), status: .investigating, impact: impact,
                              updatedAt: now, resolvedAt: nil))
        return ServiceIncident(id: id, name: Self.name(for: impact), status: .investigating, impact: impact,
                               updatedAt: now, isDemo: true)
    }

    /// Add scheduled maintenance: Statuspage reports it, but it is never an incident.
    public func injectMaintenance(now: Date = Date()) {
        records.append(Record(id: newID(), name: Self.name(for: .maintenance), status: .scheduled, impact: .maintenance,
                              updatedAt: now, resolvedAt: nil))
    }

    /// Raise every open incident to major impact.
    public func escalateAll(now: Date = Date()) {
        updateOpen(now: now) { $0 < .major ? .major : $0 }
    }

    /// Every open incident one level up: none/minor → major → critical.
    public func escalateOneLevel(now: Date = Date()) {
        updateOpen(now: now) {
            switch $0 {
            case .none, .minor: return .major
            case .major, .critical: return .critical
            case .maintenance: return $0
            }
        }
    }

    /// Every open incident one level down: critical → major → minor.
    public func deescalateOneLevel(now: Date = Date()) {
        updateOpen(now: now) {
            switch $0 {
            case .critical: return .major
            case .major, .minor: return .minor
            case .none, .maintenance: return $0
            }
        }
    }

    /// Resolve every open incident: the next poll reports none of them.
    public func resolveAll(now: Date = Date()) {
        for index in records.indices where records[index].status.isUnresolvedIncident {
            records[index].status = .resolved
            records[index].resolvedAt = now
            records[index].updatedAt = now
            resolvedOrder.append(records[index].id)
        }
    }

    /// Reopen the most recently resolved incident under its old ID. Returns false if none.
    @discardableResult
    public func reopenLastResolved(now: Date = Date()) -> Bool {
        while let id = resolvedOrder.popLast() {
            guard let index = records.firstIndex(where: { $0.id == id && $0.status == .resolved }) else { continue }
            records[index].status = .investigating
            records[index].resolvedAt = nil
            records[index].updatedAt = now
            return true
        }
        return false
    }

    public var canReopen: Bool {
        resolvedOrder.contains { id in records.contains { $0.id == id && $0.status == .resolved } }
    }

    private func updateOpen(now: Date, _ change: (IncidentImpact) -> IncidentImpact) {
        for index in records.indices where records[index].status.isUnresolvedIncident {
            let impact = change(records[index].impact)
            guard impact != records[index].impact else { continue }
            records[index].impact = impact
            records[index].updatedAt = now
        }
    }

    private func newID() -> String {
        "demo" + String(makeID().filter { $0.isLetter || $0.isNumber }.lowercased().prefix(12))
    }

    /// The records as a Statuspage payload, through the real strict decoder, marked Demo.
    private func decode() -> ServiceStatusOutcome {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let incidents: [[String: Any]] = records.map { record in
            ["id": record.id, "name": record.name, "status": record.status.rawValue, "impact": record.impact.rawValue,
             "created_at": formatter.string(from: record.updatedAt), "updated_at": formatter.string(from: record.updatedAt),
             "resolved_at": record.resolvedAt.map { formatter.string(from: $0) } ?? NSNull()]
        }
        let payload: [String: Any] = ["page": ["id": "demopage0001", "name": "GitHub (Demo)"], "incidents": incidents]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            return .incidents(try StatusPageDecoder.unresolvedIncidents(from: data).map {
                var copy = $0
                copy.isDemo = true
                return copy
            })
        } catch {
            return .failure("simulated payload unreadable")
        }
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
