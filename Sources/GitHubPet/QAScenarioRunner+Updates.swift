import Foundation
import GitHubPetCore
import SwiftUI

/// #90 runner steps. Update checks read an offline fixture transport (`UpdateFixture`), never the
/// network, and the Download button records the URL it would open instead of opening a browser.
/// The fixture installed build is 0.1.0-beta.3.
extension QAScenarioRunner {
    private static let fixtureNames = UpdateFixture.allCases.map(\.rawValue)
    private static let channelNames = UpdateChannel.allCases.map(\.rawValue)

    private static func fixture(_ c: Context) throws -> UpdateFixture {
        UpdateFixture(rawValue: try c.string("fixture", fixtureNames))!
    }

    static let updateActions: [String: Action] = [
        // Select a fixture and channel, run one check, wait for it, record the resulting state.
        "update-check": Action(keys: ["fixture", "channel"], validate: { c in
            _ = try fixture(c)
            if c.step.params["channel"] != nil { _ = try c.string("channel", channelNames) }
        }) { c in
            let updates = c.model.updates
            if c.step.params["channel"] != nil { updates.channel = UpdateChannel(rawValue: try c.string("channel", channelNames))! }
            updates.useFixture(try fixture(c))
            await updates.checkNow().value
        },
        "update-auto-check": Action(keys: ["on"], validate: { _ = try $0.bool("on") }) { c in
            c.model.updates.autoCheck = try c.bool("on")
        },
        "update-download": Action { c in
            guard c.model.updates.openDownloadPage() else {
                throw HarnessError(description: "update-download: no update is available to download")
            }
        },
        // The Software updates section as the user sees it, in the grouped Settings form.
        "open-updates": Action { c in
            guard c.plan!.rendersPNGs, let out = c.output else { return }
            try await renderPNG(Form { UpdateStatusSection(updates: c.model.updates) }.formStyle(.grouped).frame(width: 520, height: 460),
                                name: stem(c) + "-updates", out: out, asWindow: true, into: c)
        },
    ]

    static func updateSnapshot(_ model: AppModel) -> [String: Any] {
        let updates = model.updates
        func iso(_ date: Date?) -> Any { date.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull() }
        var state: [String: Any] = [
            "status": updates.status.name, "summary": updates.summary, "channel": updates.channel.rawValue,
            "autoCheck": updates.autoCheck, "installed": updates.installed.displayVersion,
            "lastCheck": iso(updates.lastCheck), "isChecking": updates.isChecking,
            "downloadOpened": updates.lastOpenedURL?.absoluteString ?? NSNull(),
            "version": NSNull(), "publishedAt": NSNull(), "notes": NSNull(), "releaseURL": NSNull(),
            "error": NSNull(), "rateLimitResetAt": NSNull(),
        ]
        switch updates.status {
        case .available(let update):
            state["version"] = update.version.description
            state["publishedAt"] = iso(update.publishedAt)
            state["notes"] = update.notes
            state["releaseURL"] = update.url.absoluteString
        case .failed(let error):
            state["error"] = String(describing: error)
            state["errorMessage"] = error.message
            if case .rateLimited(let reset) = error { state["rateLimitResetAt"] = iso(reset) }
        default: break
        }
        return state
    }

    /// One scenario per class of result, plus one that walks every fixture.
    static let updateScenarios: [String: String] = {
        func steps(_ list: [(String, String?)]) -> String {
            list.map { fixture, channel in
                #"{"action": "update-check", "fixture": "\#(fixture)"\#(channel.map { #", "channel": "\#($0)""# } ?? ""), "label": "\#(fixture)\#(channel.map { "-\($0)" } ?? "")"}"#
            }.joined(separator: ",\n          ")
        }
        func scenario(_ name: String, _ list: [(String, String?)], extra: String = "") -> String {
            #"{"name": "\#(name)", "steps": [\#n          \#(steps(list))\#(extra)\#n        ]}"#
        }
        return [
            "updates-no-update": scenario("updates-no-update", [("no-update", "beta")]),
            "updates-available-beta": scenario("updates-available-beta", [("beta-available", "beta")],
                extra: #",{"action": "open-updates", "label": "section"},{"action": "update-download", "label": "download"}"#),
            "updates-available-stable": scenario("updates-available-stable", [("stable-available", "stable")],
                extra: #",{"action": "update-download", "label": "download"}"#),
            // Stable never offers a beta; the same fixture offered to Beta does.
            "updates-channel-switch": scenario("updates-channel-switch", [("beta-available", "stable"), ("beta-available", "beta")]),
            "updates-drafts-only": scenario("updates-drafts-only", [("drafts-only", "beta")]),
            "updates-errors": scenario("updates-errors", [("offline", "beta"), ("forbidden-403", nil), ("rate-limited-403", nil),
                ("rate-limited-429", nil), ("malformed", nil), ("untrusted-metadata", nil), ("server-error-500", nil)],
                extra: #",{"action": "open-updates", "label": "section"}"#),
            "updates-all-states": scenario("updates-all-states", UpdateFixture.allCases.map { ($0.rawValue, "beta") }),
        ]
    }()
}
