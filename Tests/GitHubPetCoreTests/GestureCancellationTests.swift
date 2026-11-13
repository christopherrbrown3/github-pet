import Foundation
import Testing
@testable import GitHubPetCore

@Suite struct GestureCancellationTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    /// 2027-01-15 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_800_014_400)

    private func cancels(_ change: (inout PetSettings) -> Void, from start: PetSettings = PetSettings()) -> Bool {
        var new = start
        change(&new)
        return GestureCancellation.shouldCancel(from: start, to: new, at: noon, calendar: utc)
    }

    @Test func snoozeAndReduceMotionCancelAtOnce() {
        #expect(cancels { $0.snoozeUntil = noon.addingTimeInterval(3600) })
        #expect(cancels { $0.reducedMotion = true })
    }

    @Test func quietHoursCancelOnlyWhenTheyCoverNow() {
        #expect(cancels { $0.quietHours = QuietHours(enabled: true, startMinute: 11 * 60, endMinute: 13 * 60) })
        #expect(!cancels { $0.quietHours = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60) })
        // Moving an enabled window over now cancels too.
        let evening = { () -> PetSettings in
            var s = PetSettings(); s.quietHours = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60); return s
        }()
        #expect(cancels({ $0.quietHours.startMinute = 11 * 60; $0.quietHours.endMinute = 13 * 60 }, from: evening))
    }

    @Test func liftingSnoozeOrMotionDoesNotCancelOrReplay() {
        var snoozed = PetSettings()
        snoozed.snoozeUntil = noon.addingTimeInterval(3600)
        #expect(!cancels({ $0.snoozeUntil = nil }, from: snoozed))
        var reduced = PetSettings()
        reduced.reducedMotion = true
        #expect(!cancels({ $0.reducedMotion = false }, from: reduced))
        #expect(!cancels { $0.privacyMode.toggle() }, "unrelated changes leave a gesture alone")

        // Cancelling clears the gesture; nothing comes back when alerts are allowed again.
        var queue = EventClipQueue()
        queue.enqueue([InboxEvent(item: InboxItem(id: "a", kind: .entitlement, repository: "example/repo", title: "a",
                                                  url: nil, updatedAt: noon))], now: noon, playable: true)
        queue.clear()
        #expect(queue.tick(now: noon.addingTimeInterval(1)) == nil)
        #expect(queue.tick(now: noon.addingTimeInterval(3601)) == nil)
    }
}

@Suite struct SystemNotificationObserverTests {
    private let name = Notification.Name("GitHubPetTests.displayOptions")

    @Test @MainActor func firesWhileAliveAndStopsAfterwards() async {
        let center = NotificationCenter()
        var calls = 0
        var observer: SystemNotificationObserver? = SystemNotificationObserver(center: center, name: name) { calls += 1 }
        #expect(observer?.isObserving == true)
        center.post(name: name, object: nil)
        await Task.yield()
        #expect(calls == 1)
        observer?.stop()
        #expect(observer?.isObserving == false)
        center.post(name: name, object: nil)
        await Task.yield()
        #expect(calls == 1, "stopped observers don't fire")
        observer = nil
        _ = observer
    }

    @Test @MainActor func deinitRemovesTheObservation() async {
        let center = NotificationCenter()
        var calls = 0
        do {
            let observer = SystemNotificationObserver(center: center, name: name) { calls += 1 }
            center.post(name: name, object: nil)
            await Task.yield()
            #expect(calls == 1 && observer.isObserving)
        }
        center.post(name: name, object: nil)
        await Task.yield()
        #expect(calls == 1, "a deallocated observer no longer fires")
    }
}
