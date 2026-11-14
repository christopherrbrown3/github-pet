import AppKit
import GitHubPetCore

@main struct FocusedQA {
    @MainActor static func main() throws {
        var failures = 0
        var checks = 0
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            checks += 1
            if value() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        let suite = "dev.github-pet.qa.codex.pr36.\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var options = LaunchOptions()
        options.defaultsSuite = suite
        options.snapshotDirectory = URL(fileURLWithPath: "/tmp/qa-pr36-no-render")
        options.forcePlaceholder = true
        let m = AppModel(options: options)
        let systemReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        print("system-reduce-motion=\(systemReduced)")
        check("baseline minor static", m.incidentMarker?.tier == .minor && m.markerBurst == nil && m.unseenIncidents.isEmpty)
        let initialBadge = m.badge
        m.injectServiceIncident(.minor)
        check("minor injection decoded Demo", m.serviceIncidents.count == 2 && m.serviceIncidents.allSatisfy(\.isDemo))
        check("incident leaves inbox badge unchanged", m.badge == initialBadge)
        check("minor event once", m.unseenIncidents.count == 1)
        if !systemReduced { check("minor starts burst", m.markerBurst != nil) }
        var burst = m.markerBurst
        m.refresh()
        check("unchanged poll preserves burst", m.markerBurst == burst && m.unseenIncidents.count == 1)
        m.escalateServiceIncidentsOneLevel()
        check("major tier", m.incidentMarker?.tier == .major)
        if !systemReduced { check("major starts distinct burst", m.markerBurst != nil && m.markerBurst != burst) }
        burst = m.markerBurst
        m.escalateServiceIncidentsOneLevel()
        check("critical tier", m.incidentMarker?.tier == .critical)
        if !systemReduced { check("critical starts distinct burst", m.markerBurst != nil && m.markerBurst != burst) }
        burst = m.markerBurst
        m.escalateServiceIncidentsOneLevel()
        check("critical repeated silent", m.markerBurst == burst)
        m.deescalateServiceIncidentsOneLevel()
        check("deescalation silent", m.incidentMarker?.tier == .major && m.markerBurst == burst)
        m.escalateServiceIncidentsOneLevel()
        check("rereaching critical silent", m.markerBurst == burst)
        m.injectScheduledMaintenance()
        check("maintenance ignored", m.serviceIncidents.count == 2 && m.markerBurst == burst)
        let inboxState = m.dataState
        m.setServiceFetchFails(true)
        check("service-only failure retained rows and inbox", m.serviceIncidents.count == 2 && m.dataState == inboxState && !m.serviceState.isFresh)
        check("failure never empty", m.serviceState.statusText(count: 2).contains("unavailable"))
        check("failure clears hidden burst", m.incidentMarker == nil && m.markerBurst == nil)
        m.setServiceFetchFails(false)
        check("quick recovery static", m.incidentMarker?.tier == .critical && m.markerBurst == nil)
        m.injectServiceIncident(.critical)
        m.markServiceStale()
        check("service-only stale retained rows and inbox", m.serviceState == .stale && m.serviceIncidents.count == 3 && m.dataState == inboxState)
        check("stale clears burst and marker", m.markerBurst == nil && m.incidentMarker == nil)
        m.refresh()
        check("stale recovery static", m.incidentMarker != nil && m.markerBurst == nil)
        m.injectServiceIncident(.major)
        m.resetBaseline()
        check("reset baseline cancels burst and unseen", m.markerBurst == nil && m.unseenIncidents.isEmpty && m.incidentMarker != nil)
        m.injectServiceIncident(.minor)
        m.resolveServiceIncidents()
        check("resolve hides marker cancels burst", m.incidentMarker == nil && m.markerBurst == nil && m.serviceIncidents.isEmpty)
        m.reopenLastResolvedIncident()
        check("quick reopen static", m.incidentMarker != nil && m.markerBurst == nil && m.unseenIncidents.isEmpty)
        m.injectServiceIncident(.minor)
        m.simulateDisconnect()
        check("disconnect cancels burst", m.markerBurst == nil && m.incidentMarker == nil)
        m.simulateReconnect()
        check("reconnect static", m.incidentMarker != nil && m.markerBurst == nil)
        for mode in ["reduce", "quiet", "snooze"] {
            m.injectServiceIncident(.critical)
            if !systemReduced { check("\(mode) has positive precondition", m.markerBurst != nil) }
            switch mode {
            case "reduce": m.settings.reducedMotion = true
            case "quiet":
                let parts = Calendar.current.dateComponents([.hour, .minute], from: m.clock())
                let minute = parts.hour! * 60 + parts.minute!
                m.settings.quietHours = QuietHours(enabled: true, startMinute: minute, endMinute: (minute + 1) % 1440)
            default: m.settings.snoozeUntil = m.clock().addingTimeInterval(3600)
            }
            check("\(mode) cancels immediately retains monitoring", m.markerBurst == nil && m.incidentMarker != nil && m.serviceState.isFresh)
            check("\(mode) static phase", m.markerPhase(at: m.clock(), reduced: m.effectiveReducedMotion) == .still)
            m.injectServiceIncident(.minor)
            check("\(mode) suppresses new burst", m.markerBurst == nil)
            m.settings.reducedMotion = false
            m.settings.quietHours.enabled = false
            m.settings.snoozeUntil = nil
            m.refresh()
            check("\(mode) no replay after unsuppress", m.markerBurst == nil)
        }
        for invalid in ["q\u{301}", "1\u{20E3}", "ａｂ", "a\u{200B}", "ABC", "../a"] {
            check("ASCII ID rejects \(invalid.debugDescription)", !ServiceStatusLink.isValidIncidentID(invalid) && ServiceStatusLink.incidentURL(id: invalid) == nil)
        }
        let monitor = ServiceStatusMonitor(capacity: 1)
        let t = Date()
        var list = (0..<4).map { ServiceIncident(id: "qa\($0)", name: "QA", status: .investigating, impact: .minor, updatedAt: t, isDemo: true) }
        check("over-capacity baseline silent", monitor.apply(.incidents(list), now: t).isEmpty)
        for step in 1...3 { check("over-capacity unchanged \(step)", monitor.apply(.incidents(list), now: t + Double(step)).isEmpty) }
        for (step, impact) in [(4, IncidentImpact.major), (6, IncidentImpact.critical)] {
            for i in list.indices { list[i].impact = impact }
            check("over-capacity tier \(impact) once", monitor.apply(.incidents(list), now: t + Double(step)).count == 4)
            check("over-capacity tier \(impact) no replay", monitor.apply(.incidents(list), now: t + Double(step + 1)).isEmpty)
        }
        print("RESULT checks=\(checks) failures=\(failures)")
        if systemReduced { print("BLOCKED positive AppModel bursts: system Reduce Motion ON; settings unchanged") }
        exit(failures == 0 ? 0 : 1)
    }
}
