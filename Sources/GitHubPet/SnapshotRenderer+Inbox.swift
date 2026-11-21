import AppKit
import GitHubPetCore
import SwiftUI

/// #87 Inbox renders: every source state QA reviews, for both built-in skins, light and dark,
/// through the real InboxView and window sizing. Demo fixture rows only; never gh or the network.
/// Files: `inbox87-<skin>-<case>[-dark].png`; the report records each case's state and sizes.
extension SnapshotRenderer {
    static let inbox87Cases = ["empty", "four", "long", "partial", "stale", "error", "privacy", "dismissed"]

    static func inboxRedesignRenders(model: AppModel, directory: URL) async -> [String] {
        var report = ["## inbox redesign (#87)"]
        let saved = model.settings
        // Earlier steps may have selected the snapshot CLI source: return to Demo fixtures.
        model.settings.dataSource = .fixtures
        model.settings.reducedMotion = true
        for skin in MascotSkin.allCases {
            model.settings.mascotSkin = skin
            for name in inbox87Cases {
                var selection = InboxViewSelection()
                // Fixture polls apply synchronously; each render below waits for SwiftUI to settle.
                await prepare(name, model: model, selection: &selection)
                let overview = InboxOverview(dataState: model.dataState, items: model.items,
                                             allDismissed: model.allCurrentInboxItemsDismissed,
                                             authoredWaiting: model.authoredWaitingCount,
                                             deploymentsWaiting: model.deploymentsWaitingCount,
                                             deploymentsComplete: model.actionsQuality == nil,
                                             serviceState: model.serviceState, incidents: model.serviceIncidents)
                let sections = InboxPresentation.sections(model.items)
                report.append("inbox87 \(skin.rawValue) \(name): state=\(model.dataState.statusText) "
                              + "health=\(SourceHealth(model.dataState).rawValue) badge=\(model.badge ?? "none") "
                              + "mascot-badge=\(model.mascotBadge ?? "none") rows=\(model.items.count) "
                              + "groups=\(sections.map(\.group.rawValue).joined(separator: ",")) "
                              + "scrolls=\(InboxView.scrolls(rows: model.items.count, sections: sections.count)) "
                              + "empty=\(model.items.isEmpty ? "\(InboxEmptyState(dataState: model.dataState, allDismissed: model.allCurrentInboxItemsDismissed))" : "none") "
                              + "inbox-privacy=\(model.inboxPrivacy) dismissed=\(model.dismissedInboxRows.count) "
                              + "pack=\(model.pack?.manifest.displayID ?? "placeholder")")
                report.append("inbox87 \(skin.rawValue) \(name) tiles: "
                              + overview.tiles.map { "\($0.title)=\($0.value) (\($0.detail), \($0.tone.rawValue))" }
                                .joined(separator: " | "))
                for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                    report += await render(InboxView(model: model, showsWindowButton: false, marksSeenOnClose: false,
                                                     showsSimulator: false, initialSelection: selection),
                                           name: "inbox87-\(skin.rawValue)-\(name)\(suffix)", directory: directory,
                                           appearance: appearance, asWindow: true)
                        .prefix(1)   // size line only; the full AX dump is in the main scenario
                }
                await cleanUp(name, model: model)
            }
        }
        report += await inboxLegibilityRenders(model: model, directory: directory)
        model.settings = saved
        return report
    }

    /// #104: last-known (stale) rows, light and dark, plus the dimmed contrast ratios. Large text is
    /// not rendered here (an offscreen render ignores the Dynamic Type environment); it is covered
    /// only by the InboxRowMetrics unit tests.
    private static func inboxLegibilityRenders(model: AppModel, directory: URL) async -> [String] {
        var report = ["## inbox legibility (#104)"]
        model.settings.mascotSkin = MascotSkin.allCases[0]
        var selection = InboxViewSelection()
        await prepare("stale", model: model, selection: &selection)
        for name in ["default"] {
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                let lines = await render(InboxView(model: model, showsWindowButton: false, marksSeenOnClose: false,
                                                   showsSimulator: false, initialSelection: selection),
                                         name: "inbox104-stale-\(name)\(suffix)", directory: directory,
                                         appearance: appearance, asWindow: true)
                if let first = lines.first { report.append("inbox104 \(name)\(suffix): \(first)") }
            }
        }
        for (mode, labelGray, backgrounds) in [("light", 0.0, [236.0, 255]), ("dark", 255.0, [30.0, 50])] {
            for role in [InboxDimming.Role.title, .context] {
                let worst = backgrounds.map { InboxDimming.textRatio(role, labelGray: labelGray, backgroundGray: $0) }.min() ?? 0
                report.append("inbox104 dimmed-\(role) \(mode): ratio>=\(String(format: "%.2f", worst)) (AA \(WCAGContrast.normalTextAA))")
            }
        }
        await cleanUp("stale", model: model)
        return report
    }

    private static func prepare(_ name: String, model: AppModel, selection: inout InboxViewSelection) async {
        model.detailsRevealed = true
        model.resolveServiceIncidents()
        switch name {
        case "empty":
            model.showFixtureItemsForSnapshot([])
        case "four", "privacy", "partial", "stale", "error":
            model.showFixtureItemsForSnapshot(inbox87Items(4))
            if name == "privacy" { model.detailsRevealed = false }
            if name == "partial" { model.setPartialPolls(true) }
            if name == "stale" { model.markStale() }
            if name == "error" { model.simulateDisconnect() }
        case "long":
            model.showFixtureItemsForSnapshot(inbox87Items(14))
            model.injectServiceIncident(.minor)
        case "dismissed":
            model.showFixtureItemsForSnapshot(inbox87Items(4))
            // An open incident must not appear inside View dismissed (QA #92).
            model.injectServiceIncident(.minor)
            if let context = model.inboxDismissalContext {
                for item in model.items.prefix(2) { model.dismissInboxItem(item.id, in: context) }
                selection.showDismissed(true, in: context)
            }
        default:
            break
        }
        model.markAllSeen()
    }

    private static func cleanUp(_ name: String, model: AppModel) async {
        switch name {
        case "partial": model.setPartialPolls(false)
        case "error": model.simulateReconnect()
        case "dismissed":
            if let context = model.inboxDismissalContext {
                for row in model.dismissedInboxRows { model.restoreInboxItem(row.id, in: context) }
            }
        default: break
        }
    }

    /// Invented Demo rows covering every group, newest first; the first four are a typical queue.
    static func inbox87Items(_ count: Int, reference: Date = Date(timeIntervalSince1970: 1_793_000_000)) -> [InboxItem] {
        let rows: [(ItemKind, String, Int, String, String?)] = [
            (.reviewRequest, "example/pet-demo", 42, "Add hover summary to mascot", nil),
            (.authoredPullRequest, "example/pet-demo", 51, "Remember the Inbox window size", "Changes requested"),
            (.reviewRequest, "example/pet-tools", 7, "Tighten link validation", nil),
            (.assignedIssue, "example/pet-demo", 18, "Mascot position resets after a display change", nil),
            (.workflowFailure, "example/pet-demo", 88, "CI · main · build-and-test", nil),
            (.deploymentApproval, "example/pet-site", 12, "Deploy to production", nil),
            (.entitlement, "example/pet-access", 3, "Request write access for a release branch", nil),
            (.assignedIssue, "example/pet-tools", 21, "Document the fixture simulator", nil),
            (.reviewRequest, "example/pet-site", 30, "Refresh the landing page screenshots", nil),
            (.assignedIssue, "example/pet-demo", 64, "Badge should never count twice", nil),
            (.authoredPullRequest, "example/pet-tools", 9, "Bounded command budget for gh calls", "Checks failing"),
            (.reviewRequest, "example/pet-demo", 70, "Respect reduced motion in the empty state", nil),
            (.assignedIssue, "example/pet-site", 5, "Dark mode contrast on the status tile", nil),
            (.reviewRequest, "example/pet-tools", 11, "Retry once after a transient gh failure", nil),
        ]
        return rows.prefix(count).enumerated().map { index, row in
            let (kind, repo, number, title, attention) = row
            let path = kind == .assignedIssue ? "issues" : "pull"
            return InboxItem(id: "\(kind.rawValue):\(repo)#\(number)", kind: kind, repository: repo, title: title,
                             url: URL(string: "https://github.com/\(repo)/\(path)/\(number)"),
                             updatedAt: reference.addingTimeInterval(-Double(index) * 3600), isDemo: true,
                             attention: attention, attentionKeys: attention.map { ["\(kind.rawValue):\(repo)#\(number)#\($0)"] } ?? [])
        }
    }
}
