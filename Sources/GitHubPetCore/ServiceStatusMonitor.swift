import Foundation

/// The result of one GitHub Status poll, from fixtures or from githubstatus.com.
public enum ServiceStatusOutcome: Equatable, Sendable {
    /// A verified, strictly decoded list of unresolved incidents (empty means none right now).
    case incidents([ServiceIncident])
    case failure(String)
}

/// Data quality of the GitHub Status source. Only `operational` means "no incidents" is known.
public enum ServiceStatusState: Equatable, Sendable {
    case loading
    /// Fresh success with no unresolved incidents.
    case operational
    /// Fresh success with at least one unresolved incident.
    case incidents
    case stale
    case error(String)

    public var isFresh: Bool { self == .operational || self == .incidents }

    /// Whether the held incidents came from a success that is still trusted for mood (fresh or stale,
    /// as for inbox items); a failed poll keeps last-known incidents for display only.
    public var hasUsableIncidents: Bool { isFresh || self == .stale }

    public func statusText(count: Int) -> String {
        switch self {
        case .loading: return "Checking GitHub status…"
        case .operational: return "No active GitHub incidents"
        case .incidents: return count == 1 ? "1 active GitHub incident" : "\(count) active GitHub incidents"
        case .stale: return "GitHub status is stale"
        case .error(let message): return "GitHub status unavailable: \(message)"
        }
    }
}

/// Folds GitHub Status polls into incident state and reports genuinely new incidents.
///
/// Rules (mirroring `InboxEngine`):
/// - the first success establishes the baseline silently; incidents already open are not announced;
/// - a poll is comparable only after a fresh previous success, so recovery from an error or
///   staleness records incidents silently (no replay);
/// - each incident ID is announced at most once, even if it disappears and comes back (also when
///   it comes back with a higher impact);
/// - updates (name, status, impact changes within the minor tier) revise rows silently. Escalation
///   of a known open incident to a higher tier than it has ever reached (minor → major, minor →
///   critical, major → critical; #37 parity) is announced once per tier, as urgent, on a comparable
///   poll. Downgrades are silent, and returning to a tier already reached is never re-announced;
/// - resolved incidents simply leave the list, without an event.
public final class ServiceStatusMonitor {
    public static let defaultStaleAfter: TimeInterval = 10 * 60

    public private(set) var incidents: [ServiceIncident] = []
    public private(set) var state: ServiceStatusState = .loading
    public private(set) var lastSuccess: Date?
    public let staleAfter: TimeInterval
    public let capacity: Int

    private var baselineEstablished = false
    private var previousWasComparable = false
    /// Incident IDs ever seen (bounded, oldest evicted first, current IDs refreshed).
    private var known: [String] = []
    private var knownSet: Set<String> = []
    /// Highest marker tier each known incident has reached, so each tier is announced at most once.
    private var highestTier: [String: IncidentMarker.Tier] = [:]

    public init(staleAfter: TimeInterval = ServiceStatusMonitor.defaultStaleAfter, capacity: Int = 512) {
        self.staleAfter = staleAfter
        self.capacity = max(1, capacity)
    }

    /// Apply one poll result; returns events for newly announced incidents, most severe first.
    @discardableResult
    public func apply(_ outcome: ServiceStatusOutcome, now: Date) -> [InboxEvent] {
        switch outcome {
        case .failure(let message):
            // Last-known incidents stay for display; the state says they are not current.
            state = .error(message)
            previousWasComparable = false
            return []
        case .incidents(let raw):
            let current = StatusPageDecoder.dedupe(raw.filter { ServiceStatusLink.isValidIncidentID($0.id) })
            let fresh = lastSuccess.map { now >= $0 && now.timeIntervalSince($0) < staleAfter } ?? false
            let comparable = baselineEstablished && previousWasComparable && fresh
            var events: [InboxEvent] = []
            // Escalation is only a change within one open incident: a reopened ID stays silent.
            let previousIDs = Set(incidents.map(\.id))
            for incident in current {
                let isNew = !knownSet.contains(incident.id)
                let tier = IncidentMarker.Tier(incident.impact)
                let escalated = previousIDs.contains(incident.id) && tier >= .major
                    && tier > (highestTier[incident.id] ?? .minor)
                if comparable && (isNew || escalated) { events.append(incident.event) }
            }
            for incident in current {
                remember(incident.id)
                let tier = IncidentMarker.Tier(incident.impact)
                if tier > (highestTier[incident.id] ?? .minor) { highestTier[incident.id] = tier }
            }
            highestTier = highestTier.filter { knownSet.contains($0.key) }
            incidents = current
            baselineEstablished = true
            previousWasComparable = true
            lastSuccess = now
            state = current.isEmpty ? .operational : .incidents
            return events
        }
    }

    /// Downgrade to `.stale` once the last success is too old. Returns true if state changed.
    @discardableResult
    public func refreshFreshness(now: Date) -> Bool {
        guard state.isFresh, let lastSuccess, now.timeIntervalSince(lastSuccess) >= staleAfter else { return false }
        markStale()
        return true
    }

    /// Force the stale state (fixture simulator and freshness checks).
    public func markStale() {
        guard state.isFresh else { return }
        state = .stale
        previousWasComparable = false
    }

    /// Forget everything: incidents, state, timestamps and baseline (data source switched).
    public func reset() {
        incidents = []
        state = .loading
        lastSuccess = nil
        resetBaseline()
    }

    /// Forget the baseline; the next success re-seeds without events.
    public func resetBaseline() {
        baselineEstablished = false
        previousWasComparable = false
        known.removeAll()
        knownSet.removeAll()
        highestTier.removeAll()
    }

    /// Whether any held incident is major or critical while the data is still usable.
    public var hasUrgentIncident: Bool {
        state.hasUsableIncidents && incidents.contains { $0.severity == .critical }
    }

    private func remember(_ id: String) {
        if knownSet.contains(id) {
            if let index = known.firstIndex(of: id) { known.remove(at: index) }
            known.append(id)
            return
        }
        if known.count >= capacity { knownSet.remove(known.removeFirst()) }
        known.append(id)
        knownSet.insert(id)
    }
}

/// Mood and alert policy for GitHub Status, layered over the inbox's own mood.
public enum ServiceStatusPolicy {
    /// A usable major/critical incident makes the mascot urgent, like a critical inbox item.
    /// Unseen new incidents raise attention only while alerts are allowed. A failed poll never
    /// changes the mood by itself (the Inbox status line carries it).
    public static func mood(base: MascotState, monitor: ServiceStatusMonitor, unseenIncidents: Int,
                            alertsAllowed: Bool) -> MascotState {
        if base == .urgent || monitor.hasUrgentIncident { return .urgent }
        if base == .attention || (alertsAllowed && unseenIncidents > 0) { return .attention }
        return .idle
    }
}
