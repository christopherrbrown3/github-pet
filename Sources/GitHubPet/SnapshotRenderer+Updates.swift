import AppKit
import GitHubPetCore
import SwiftUI

/// #149 renders: the Inbox with the "Update available" banner and the menu-bar item without and with
/// the update dot, light and dark. A stand-in updater that never starts Sparkle or reaches the network;
/// the Inbox is Demo fixtures. Files: `update-inbox[-dark].png`, `update-menubar[-dark].png`.
extension SnapshotRenderer {
    static let updateRenderVersion = "0.1.0-beta.7"

    /// Reports an idle updater and does nothing when asked to check.
    @MainActor private final class InertUpdaterBackend: UpdaterBackend {
        var canCheckForUpdates: Bool { true }
        var automaticallyChecksForUpdates = true
        var automaticallyDownloadsUpdates = false
        var lastUpdateCheckDate: Date? { nil }
        var updateCheckInterval: TimeInterval { 21_600 }
        func checkForUpdates() {}
        func checkForUpdatesInBackground() {}
    }

    static func updateIndicatorRenders(model: AppModel, directory: URL) async -> [String] {
        var report = ["## update indicator (#149)"]
        let saved = model.settings
        model.settings.dataSource = .fixtures
        model.showFixtureItemsForSnapshot(inbox87Items(4))
        // A render-only configuration: a well-formed but unused key, so the stand-in counts as configured.
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                                   "GitHubPetReleaseVersion": "0.1.0-beta.6", "SUAllowsAutomaticUpdates": true,
                                   "SUFeedURL": "https://example.invalid/appcast.xml",
                                   "SUPublicEDKey": Data(repeating: 0, count: 32).base64EncodedString()]
        let updates = UpdateController(installed: InstalledBuild(infoDictionary: info), configuration: UpdateConfiguration(infoDictionary: info),
                                       defaults: EphemeralDefaults(name: "dev.github-pet.snapshot.updates"), backend: InertUpdaterBackend())
        updates.announce = { _ in }
        let badgeBefore = model.badge ?? "none", mascotBadgeBefore = model.mascotBadge ?? "none"
        let plain = MenuBarLabel.accessibilityLabel(model: model, updates: updates)
        updates.found(updateRenderVersion)
        report.append("update-indicator: version=\(updates.indicatorVersion ?? "none") badge=\(badgeBefore)->\(model.badge ?? "none") "
                      + "mascot-badge=\(mascotBadgeBefore)->\(model.mascotBadge ?? "none") alert-icon=\(model.showsAlertIcon)")
        report.append("update menu-bar AX: \(MenuBarLabel.accessibilityLabel(model: model, updates: updates))")
        let strip = HStack(spacing: 18) {
            MenuBarLabel(model: model, updates: UpdateController(installed: updates.installed, configuration: updates.configuration,
                                                                 defaults: EphemeralDefaults(name: "dev.github-pet.snapshot.updates-none"),
                                                                 backend: nil))
            MenuBarLabel(model: model, updates: updates)
        }
        .padding(.horizontal, 10).frame(height: 24)
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            report += await render(InboxView(model: model, showsWindowButton: false, marksSeenOnClose: false,
                                             showsSimulator: false, updates: updates),
                                   name: "update-inbox\(suffix)", directory: directory, appearance: appearance, asWindow: true)
            report += await render(strip, name: "update-menubar\(suffix)", directory: directory, appearance: appearance)
        }
        updates.dismissIndicator()
        report.append("update-indicator after Later: version=\(updates.indicatorVersion ?? "none") "
                      + "menu-line=\(updates.pendingVersion ?? "none") ax-restored=\(MenuBarLabel.accessibilityLabel(model: model, updates: updates) == plain)")
        model.settings = saved
        return report
    }
}
