import Foundation

/// Statuspage incident impact, lowest to highest. `maintenance` marks scheduled maintenance.
public enum IncidentImpact: String, Codable, CaseIterable, Comparable, Sendable {
    case none
    case minor
    case major
    case critical
    case maintenance

    private var rank: Int {
        switch self {
        case .maintenance: return -1
        case .none: return 0
        case .minor: return 1
        case .major: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: IncidentImpact, rhs: IncidentImpact) -> Bool { lhs.rank < rhs.rank }

    /// Major and critical outages are urgent; none and minor only need attention.
    public var severity: EventSeverity { self >= .major ? .critical : .actionable }

    public var label: String {
        switch self {
        case .none: return "No impact"
        case .minor: return "Minor impact"
        case .major: return "Major impact"
        case .critical: return "Critical impact"
        case .maintenance: return "Maintenance"
        }
    }
}

/// Statuspage lifecycle for incidents and scheduled maintenance. Any other value is a decode error.
public enum IncidentStatus: String, Codable, CaseIterable, Sendable {
    case investigating, identified, monitoring, resolved, postmortem
    case scheduled, inProgress = "in_progress", verifying, completed

    /// Only these mean an unresolved incident. Resolved incidents and maintenance never qualify.
    public var isUnresolvedIncident: Bool {
        self == .investigating || self == .identified || self == .monitoring
    }

    public var label: String {
        switch self {
        case .inProgress: return "In progress"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// One confirmed, unresolved GitHub service incident.
public struct ServiceIncident: Identifiable, Hashable, Sendable {
    /// Statuspage incident ID; the only key used for dedupe and new-incident detection.
    public var id: String
    public var name: String
    public var status: IncidentStatus
    public var impact: IncidentImpact
    public var updatedAt: Date
    /// Invented fixture data. Always labelled "Demo".
    public var isDemo: Bool

    public init(id: String, name: String, status: IncidentStatus, impact: IncidentImpact,
                updatedAt: Date, isDemo: Bool = false) {
        self.id = id
        self.name = name
        self.status = status
        self.impact = impact
        self.updatedAt = updatedAt
        self.isDemo = isDemo
    }

    public var severity: EventSeverity { impact.severity }

    /// The only link an incident opens: https://www.githubstatus.com/incidents/<id>.
    public var url: URL? { ServiceStatusLink.incidentURL(id: id) }

    /// Inbox form, so incidents share event clips and privacy text with other items.
    public var inboxItem: InboxItem {
        InboxItem(id: "incident:\(id)", kind: .serviceIncident, repository: ServiceStatusLink.host,
                  title: name, url: url, updatedAt: updatedAt, isDemo: isDemo)
    }

    public var event: InboxEvent { InboxEvent(item: inboxItem, severity: severity) }
}

/// Builds and checks githubstatus.com incident links. Nothing else is ever opened for an incident.
public enum ServiceStatusLink {
    public static let host = "www.githubstatus.com"

    /// Statuspage IDs are short lowercase alphanumerics (e.g. `kctbh9vrtdwd`).
    public static func isValidIncidentID(_ id: String) -> Bool {
        (1...32).contains(id.count) && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    public static func incidentURL(id: String) -> URL? {
        guard isValidIncidentID(id) else { return nil }
        return validated(URL(string: "https://\(host)/incidents/\(id)"))
    }

    /// Accepts exactly `https://www.githubstatus.com/incidents/<id>`: no credentials, port,
    /// query or fragment, and no other path.
    public static func validated(_ url: URL?) -> URL? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == host,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else {
            return nil
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "incidents",
              isValidIncidentID(String(parts[2])) else { return nil }
        return url
    }
}

public enum StatusDecodeError: Error, Equatable, Sendable {
    case malformed
    case tooManyIncidents
    case invalidIncident(String)
}

/// Strict decoder for the Statuspage `incidents/unresolved.json` (and `incidents.json`) payload.
///
/// The whole payload is rejected, never partly used, when the shape is wrong, an ID is not a
/// Statuspage ID, a status or impact is unknown, or a date is unreadable: unknown data must
/// surface as a fetch failure, not as fewer incidents.
public enum StatusPageDecoder {
    public static let maxIncidents = 200
    public static let maxNameLength = 300

    private struct Payload: Decodable {
        struct Page: Decodable { var id: String }
        var page: Page
        var incidents: [Incident]
    }

    private struct Incident: Decodable {
        var id: String
        var name: String
        var status: String
        var impact: String
        var created_at: String
        var updated_at: String?
        var resolved_at: String?
    }

    /// Unresolved incidents only, deduped by ID (latest update wins), most severe then newest first.
    /// Resolved incidents and scheduled maintenance are dropped.
    public static func unresolvedIncidents(from data: Data) throws -> [ServiceIncident] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw StatusDecodeError.malformed
        }
        guard !payload.page.id.isEmpty else { throw StatusDecodeError.malformed }
        guard payload.incidents.count <= maxIncidents else { throw StatusDecodeError.tooManyIncidents }
        var incidents: [ServiceIncident] = []
        for raw in payload.incidents {
            guard ServiceStatusLink.isValidIncidentID(raw.id) else { throw StatusDecodeError.invalidIncident("id") }
            guard let status = IncidentStatus(rawValue: raw.status) else {
                throw StatusDecodeError.invalidIncident("status")
            }
            guard let impact = IncidentImpact(rawValue: raw.impact) else {
                throw StatusDecodeError.invalidIncident("impact")
            }
            guard let created = date(raw.created_at) else { throw StatusDecodeError.invalidIncident("created_at") }
            var updated = created
            if let text = raw.updated_at {
                guard let parsed = date(text) else { throw StatusDecodeError.invalidIncident("updated_at") }
                updated = parsed
            }
            let name = sanitizedName(raw.name)
            guard !name.isEmpty else { throw StatusDecodeError.invalidIncident("name") }
            guard status.isUnresolvedIncident, impact != .maintenance, raw.resolved_at == nil else { continue }
            incidents.append(ServiceIncident(id: raw.id, name: name, status: status, impact: impact, updatedAt: updated))
        }
        return dedupe(incidents)
    }

    /// One incident per ID (the most recently updated), most severe first, then newest.
    public static func dedupe(_ incidents: [ServiceIncident]) -> [ServiceIncident] {
        var byID: [String: ServiceIncident] = [:]
        for incident in incidents {
            if let existing = byID[incident.id], existing.updatedAt >= incident.updatedAt { continue }
            byID[incident.id] = incident
        }
        return byID.values.sorted {
            if $0.impact != $1.impact { return $0.impact > $1.impact }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    /// Single line, no control characters, bounded length.
    static func sanitizedName(_ name: String) -> String {
        let flattened = String(name.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
        })
        let trimmed = flattened.trimmingCharacters(in: .whitespaces)
        return trimmed.count > maxNameLength ? String(trimmed.prefix(maxNameLength - 1)) + "…" : trimmed
    }

    /// Statuspage timestamps: ISO 8601 with or without fractional seconds and with an offset.
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
