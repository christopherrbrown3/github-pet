import AppKit
import GitHubPetCore
import SwiftUI

/// Per-skin placement probes (#116). The main scenario runs with the default skin (Mona); these
/// repeat near-touch, hover placement and the incident marker with Little Chris selected, and
/// measure where the count sits against each skin's head.
extension SnapshotRenderer {
    /// Runs `body` with `skin` selected, then restores the previous skin.
    static func withSkin<T>(_ skin: MascotSkin, model: AppModel, _ body: () async -> T) async -> T {
        let saved = model.settings.mascotSkin
        model.settings.mascotSkin = skin
        defer { model.settings.mascotSkin = saved }
        return await body()
    }

    static func littleChrisPlacementProbes(model: AppModel, directory: URL) async -> [String] {
        var report = ["## little chris placement (#116)"]
        report += await withSkin(.littleChris, model: model) {
            var lines = ["little chris placement: pack=\(model.pack?.manifest.displayID ?? "placeholder")"]
            lines += await nearTouchMeasurements(model: model, directory: directory, skin: .littleChris)
            for placementCase in HoverCase.all {
                lines.append(await hoverPlacement(model: model, placementCase, directory: directory, skin: .littleChris))
            }
            return lines
        }
        return report
    }

    /// Where the rasterised count sits against the rasterised head (the art's pixels within
    /// `MascotLayout.headDepth` canvas units of the pose's top), from the near-touch probe's own
    /// renders of every upright pose, at one size and scale. centre-past-head: how far a one-digit
    /// count's centre lies right of the head's right edge (negative: over the head), against the
    /// layout's limit of a quarter of the count's height. lead-inside-head: how far the leading
    /// edge of any count ("2", "99+") lies left of that edge. gap: nearest count-to-art distance.
    @MainActor struct BadgeFit {
        let layout: MascotLayout
        let scale: CGFloat
        private var centres: [CGFloat] = [], leads: [CGFloat] = [], gaps: [CGFloat] = []
        private var empty = 0, farthest = ""

        init(layout: MascotLayout, scale: CGFloat) {
            self.layout = layout
            self.scale = scale
        }

        static let badges: Set<String> = ["2", "99+"]

        mutating func add(_ pose: MascotPose, badge: String, art: [UInt8], labels: [UInt8]) {
            guard pose.angle == 0, Self.badges.contains(badge) else { return }
            let width = Int((layout.panelSize.width * scale).rounded(.up))
            // DEMO sits at the leading inset; only pixels right of it belong to the count.
            let countMinX = Int(((layout.demoFrame.maxX + 1) * scale).rounded(.up))
            let depth = Int((layout.artSide * CGFloat(MascotLayout.headDepth) / 256 * scale).rounded(.up))
            guard let first = art.firstIndex(where: { $0 > 0 }) else { empty += 1; return }
            let top = first / width
            let rows = top..<min(art.count / width, top + depth)
            let rights: [Int] = rows.compactMap { row in (0..<width).last { art[row * width + $0] > 0 } }
            guard let right = rights.max() else { empty += 1; return }
            let headRight = CGFloat(right + 1) / scale
            var count = labels
            for index in count.indices where index % width < countMinX { count[index] = 0 }
            let columns = count.indices.filter { count[$0] > 0 }.map { $0 % width }
            guard let minX = columns.min(), let maxX = columns.max() else { empty += 1; return }
            if badge == "2" {
                let past = CGFloat(minX + maxX + 1) / 2 / scale - headRight
                if past > (centres.max() ?? -.infinity) {
                    farthest = "\(pose.state.rawValue)/\(pose.frame.map(String.init) ?? "static")"
                }
                centres.append(past)
            }
            leads.append(headRight - CGFloat(minX) / scale)
            gaps.append(nearestGap(art, count, size: layout.panelSize, scale: scale).0)
        }

        func line(skin: MascotSkin) -> String {
            "badge fit \(skin.rawValue) @\(Int(layout.artSide)) \(Int(scale))x: "
                + "centre-past-head=\(format(centres.min()))..\(format(centres.max())) (farthest \(farthest)) "
                + "limit=\(format(layout.count.height / 4)) lead-inside-head-min=\(format(leads.min())) "
                + "gap=\(format(gaps.min()))-\(format(gaps.max())) cases=\(gaps.count) empty-renders=\(empty) "
                + "count-slot-x=\(format(layout.countSlotX)) lane=\(format(layout.laneHeight))"
        }
    }
}
