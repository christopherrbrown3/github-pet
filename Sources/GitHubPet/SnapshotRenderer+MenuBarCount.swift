import AppKit
import GitHubPetCore
import SwiftUI

/// #159 renders: the menu-bar item while the desktop pet is hidden, with the pet's badge text for
/// 0 / 1 / 9 / 99+ / ?, without and with the #149 update dot, light and dark. Demo data only.
/// Files: `menubar-count[-dark].png` (every count, no dot), `menubar-count-dot[-dark].png`.
extension SnapshotRenderer {
    static func menuBarCountRenders(model: AppModel, directory: URL) async -> [String] {
        var report = ["## menu-bar count (#159)"]
        let saved = model.settings
        model.settings.dataSource = .fixtures
        model.showFixtureItemsForSnapshot(inbox87Items(4))
        model.settings.mascotVisible = true
        report.append("menubar-count pet-visible: count=\(model.menuBarCount ?? "none") slot=\(model.showsMenuBarCount) badge=\(model.mascotBadge ?? "none")")
        model.settings.mascotVisible = false
        report.append("menubar-count pet-hidden: count=\(model.menuBarCount ?? "none") slot=\(model.showsMenuBarCount) badge=\(model.mascotBadge ?? "none") "
                      + "ax=\(MenuBarLabel.accessibilityLabel(model: model, updates: model.updates))")
        model.settings = saved
        model.showFixtureItemsForSnapshot(inbox87Items(4))

        let counts: [(String, String?)] = [("0", nil), ("1", "1"), ("9", "9"), ("99+", MascotPolicy.mascotBadge(dataState: .ready, count: 120)), ("?", "?")]
        let widths = counts.map { MenuBarIcon.image(symbol: "pawprint", dot: false, count: $0.1, showsCount: true).size.width }
        report.append("menubar-count canvas widths=\(widths.map { String(format: "%.1f", $0) }.joined(separator: ",")) stable=\(Set(widths).count == 1)")
        for (suffix, dot) in [("", false), ("-dot", true)] {
            let strip = HStack(spacing: 18) {
                ForEach(counts, id: \.0) { _, count in
                    Image(nsImage: MenuBarIcon.image(symbol: "pawprint", dot: dot, count: count, showsCount: true))
                }
            }
            .padding(.horizontal, 10).frame(height: 24)
            for (theme, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                report += await render(strip, name: "menubar-count\(suffix)\(theme)", directory: directory, appearance: appearance)
            }
        }
        return report
    }
}
