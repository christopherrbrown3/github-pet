import AppKit
import GitHubPetCore

@main struct FreshnessQA {
    @MainActor static func main() {
        var failures = 0, checks = 0
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            checks += 1
            if value() { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
        }
        // Only the QA copy makes the existing clockOffset mutable. No system clock changes.
        for gap in [601.0, 1062.0] {
            for kind in ["entitlement", "workflow", "major", "critical"] {
                for refreshed in [false, true] {
                    let label = "gap=\(Int(gap)) \(kind) refresh=\(refreshed)"
                    let suite = "dev.github-pet.qa.freshness.\(UUID().uuidString)"
                    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
                    var options = LaunchOptions()
                    options.defaultsSuite = suite
                    options.snapshotDirectory = URL(fileURLWithPath: "/tmp/qa47-no-render")
                    options.forcePlaceholder = true
                    let model = AppModel(options: options)
                    model.settings.reducedMotion = true
                    let baseline = model.lastSuccess!
                    let inboxIDs = Set(model.items.map(\.id))
                    let serviceIDs = Set(model.serviceIncidents.map(\.id))
                    check(label + " baseline silent", model.unseenCount == 0 && model.unseenIncidents.isEmpty)
                    model.clockOffset += gap
                    check(label + " domain gap exceeds staleAfter", model.clock().timeIntervalSince(baseline) >= gap)
                    if refreshed {
                        model.refresh() // exact newly added snapshot ordering, unchanged fixture poll
                        check(label + " recovery silent and fresh", model.unseenCount == 0 && model.unseenIncidents.isEmpty && model.dataState == .ready && model.serviceState.isFresh)
                        check(label + " recovery rows unchanged", Set(model.items.map(\.id)) == inboxIDs && Set(model.serviceIncidents.map(\.id)) == serviceIDs)
                    }
                    switch kind {
                    case "entitlement": model.injectEntitlementEvent()
                    case "workflow": model.injectWorkflowFailure()
                    case "major": model.injectServiceIncident(.major)
                    default: model.injectServiceIncident(.critical)
                    }
                    let service = kind == "major" || kind == "critical"
                    let newIDs = service ? Set(model.serviceIncidents.map(\.id)).subtracting(serviceIDs) : Set(model.items.map(\.id)).subtracting(inboxIDs)
                    check(label + " exactly one new row", newIDs.count == 1)
                    let count = service ? model.unseenIncidents.count : model.unseenCount
                    check(label + (refreshed ? " new event once" : " negative control stays silent stale recovery"), count == (refreshed ? 1 : 0))
                    model.markAllSeen()
                    model.replaySnapshot()
                    model.refresh()
                    check(label + " unchanged/replayed snapshot none", model.unseenCount == 0 && model.unseenIncidents.isEmpty && model.markerBurst == nil)
                }
            }
        }
        print("RESULT checks=\(checks) failures=\(failures); clock seam only, no sleep/render/desktop claim")
        exit(failures == 0 ? 0 : 1)
    }
}
