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
        report.append("## badge fit (#116: count vs each skin's head)")
        for skin in MascotSkin.allCases {
            report += await withSkin(skin, model: model) { await badgeFit(model: model, skin: skin) }
        }
        return report
    }

    /// Where the rasterised count sits against the rasterised head (the art's pixels within
    /// `MascotLayout.headDepth` canvas units of the pose's top) for every upright pose, at
    /// 64/128/256 and 1×/2×. centre-past-head: how far a one-digit count's centre lies right of
    /// the head's right edge (negative: over the head), against the layout's limit of a quarter
    /// of the count's height. lead-inside-head: how far the leading edge of any count ("2",
    /// "99+") lies left of that edge. gap: nearest count-to-art distance.
    static func badgeFit(model: AppModel, skin: MascotSkin) async -> [String] {
        guard let pack = model.pack else { return ["badge fit \(skin.rawValue): no pack"] }
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 300, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let saved = model.settings.mascotSize
        defer { model.settings.mascotSize = saved }
        let poses = MascotState.allCases.flatMap { state in
            (pack.frameURLs(for: state).indices.map { Optional($0) } + [nil])
                .map { MascotPose(state: state, frame: $0, clipElapsed: nil) }
        }
        var lines: [String] = []
        for side in [64.0, 128, 256] {
            model.settings.mascotSize = side
            let layout = model.layout(side)
            for scale in [CGFloat(1), 2] {
                let width = Int((layout.panelSize.width * scale).rounded(.up))
                // DEMO sits at the leading inset; only pixels right of it belong to the count.
                let countMinX = Int(((layout.demoFrame.maxX + 1) * scale).rounded(.up))
                var centres: [CGFloat] = [], leads: [CGFloat] = [], gaps: [CGFloat] = []
                var empty = 0, farthest = ""
                for pose in poses {
                    func image(art: Bool, badge: String) async -> [UInt8]? {
                        let view = MascotView(model: model, poseOverride: pose, badgeOverride: badge,
                                              drawsArt: art, drawsLabels: !art, drawsMarker: false)
                            .environment(\.displayScale, scale)
                        return await alphaBitmap(view, in: host, size: layout.panelSize, scale: scale)
                    }
                    guard let art = await image(art: true, badge: "2"),
                          let top = art.indices.first(where: { art[$0] > 0 }).map({ $0 / width }) else { empty += 1; continue }
                    let headRows = top..<min(art.count / width, top + Int((layout.artSide * CGFloat(MascotLayout.headDepth) / 256 * scale).rounded(.up)))
                    let headRight = headRows.compactMap { row in (0..<width).last { art[row * width + $0] > 0 } }.max().map { CGFloat($0 + 1) / scale }
                    for badge in ["2", "99+"] {
                        guard let headRight, var labels = await image(art: false, badge: badge) else { empty += 1; continue }
                        for index in labels.indices where index % width < countMinX { labels[index] = 0 }
                        let columns = labels.indices.filter { labels[$0] > 0 }.map { $0 % width }
                        guard let minX = columns.min(), let maxX = columns.max() else { empty += 1; continue }
                        if badge == "2" {
                            let past = CGFloat(minX + maxX + 1) / 2 / scale - headRight
                            if past > (centres.max() ?? -.infinity) {
                                farthest = "\(pose.state.rawValue)/\(pose.frame.map(String.init) ?? "static")"
                            }
                            centres.append(past)
                        }
                        leads.append(headRight - CGFloat(minX) / scale)
                        gaps.append(nearestGap(art, labels, size: layout.panelSize, scale: scale).0)
                    }
                }
                lines.append("badge fit \(skin.rawValue) @\(Int(side)) \(Int(scale))x: "
                             + "centre-past-head=\(format(centres.min()))..\(format(centres.max())) (farthest \(farthest)) "
                             + "limit=\(format(layout.count.height / 4)) lead-inside-head-min=\(format(leads.min())) "
                             + "gap=\(format(gaps.min()))-\(format(gaps.max())) cases=\(gaps.count) empty-renders=\(empty) "
                             + "count-slot-x=\(format(layout.countSlotX)) lane=\(format(layout.laneHeight))")
            }
        }
        return lines
    }
}
