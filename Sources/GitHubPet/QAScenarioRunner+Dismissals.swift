import Foundation
import GitHubPetCore

extension QAScenarioRunner {
    private static func dismissalID(_ context: Context) throws -> String {
        guard let id = context.step.params["id"] as? String, (1...160).contains(id.utf8.count),
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || "#-:./_".utf8.contains($0) }) else {
            throw HarnessError(description: "\(context.step.action): \"id\" must be a synthetic row ID")
        }
        return id
    }

    private static func dismissalContext(_ context: Context) throws -> InboxDismissalContext {
        guard context.model.simulatesScope, let identity = context.model.inboxDismissalContext else {
            throw HarnessError(description: "\(context.step.action): dismissal requires an active simulated Inbox identity")
        }
        return identity
    }

    static let dismissalActions: [String: Action] = [
        "dismiss": Action(keys: ["id"], validate: { _ = try dismissalID($0) }) { c in
            let context = try dismissalContext(c)
            let id = try dismissalID(c)
            guard !c.inboxSelection.showsDismissed(in: context),
                  let item = c.model.items.first(where: { $0.id == id }), c.model.canDismissInboxItem(item) else {
                throw HarnessError(description: "dismiss requires a visible, dismissible Inbox row")
            }
            c.model.dismissInboxItem(id, in: context)
        },
        "view-dismissed": Action(keys: ["on"], validate: { c in
            if c.step.params["on"] != nil { _ = try c.bool("on") }
        }) { c in
            let context = try dismissalContext(c)
            let show = c.step.params["on"] == nil ? true : try c.bool("on")
            c.inboxSelection.showDismissed(show, in: context)
        },
        "restore": Action(keys: ["id"], validate: { _ = try dismissalID($0) }) { c in
            let context = try dismissalContext(c)
            let digest = EventBaseline.digest(try dismissalID(c))
            guard c.inboxSelection.showsDismissed(in: context),
                  c.model.dismissedInboxRows.contains(where: { $0.id == digest }) else {
                throw HarnessError(description: "restore requires a row in the open dismissed list")
            }
            c.model.restoreInboxItem(digest, in: context)
        },
    ]

    static func dismissalSnapshot(_ context: Context) -> [String: Any] {
        let model = context.model!
        let showingDismissed = context.inboxSelection.showsDismissed(in: model.inboxDismissalContext)
        let rows: [[String: Any]] = showingDismissed ? model.dismissedInboxRows.map { row in
            ["id": row.id, "available": row.item != nil,
             "visibleTitle": row.title(privacy: model.inboxPrivacy),
             "visibleSubtitle": row.subtitle(privacy: model.inboxPrivacy)]
        } : []
        return [
            "view": showingDismissed ? "dismissed" : "inbox",
            "savedCount": model.dismissedInboxRows.count,
            "allCurrentDismissed": model.allCurrentInboxItemsDismissed,
            "message": model.dismissedInboxMessage as Any? ?? NSNull(),
            "notice": model.inboxDismissalNotice as Any? ?? NSNull(),
            "visibleRows": rows,
        ]
    }

    static let dismissalScenarios: [String: String] = [
        "inbox-dismissal": #"""
        {"name": "inbox-dismissal", "steps": [
          {"action": "dismiss", "id": "reviewRequest:PR_U_scope_demo_A_0", "label": "dismiss-last-current"},
          {"action": "view-dismissed", "label": "available-private"},
          {"action": "show-details", "on": true, "label": "available-revealed"},
          {"action": "show-details", "on": false},
          {"action": "partial", "on": true, "label": "dismissed-with-partial"},
          {"action": "partial", "on": false, "label": "dismissed-complete-again"},
          {"action": "restore", "id": "reviewRequest:PR_U_scope_demo_A_0", "label": "restore-current"},
          {"action": "view-dismissed", "on": false, "label": "current-restored-quietly"},
          {"action": "apply", "scope": "everything", "label": "expand-to-everything"},
          {"action": "dismiss", "id": "reviewRequest:PR_U_scope_demo_A_1000", "label": "dismiss-outside-review"},
          {"action": "apply", "scope": "selected", "label": "filter-to-selected"},
          {"action": "view-dismissed", "label": "unavailable-private"},
          {"action": "show-details", "on": true, "label": "unavailable-revealed"},
          {"action": "restore", "id": "reviewRequest:PR_U_scope_demo_A_1000", "label": "restore-unavailable"},
          {"action": "apply", "scope": "everything", "label": "outside-restored-quietly"},
          {"action": "refresh", "label": "unchanged-after-restore"},
          {"action": "quit"}]}
        """#,
    ]
}
