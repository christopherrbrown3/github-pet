import CoreGraphics
import Foundation
import Testing
@testable import GitHubPetCore

/// A 256 px canvas whose character fills rows 20...231, columns 52...210.
private let block = ArtProfile(canvas: 256, rows: (0..<256).map { (20...231).contains($0) ? 52...210 : nil })
private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
/// Hover summaries: the shortest (two lines) and the tallest (privacy off, four item lines).
private let short = CGSize(width: 144, height: 51)
private let tall = CGSize(width: 142, height: 115)

/// Window rect for a placement, in panel coordinates.
private func window(_ placement: HoverPlacement, _ popover: CGSize) -> CGRect {
    let size = CGSize(width: popover.width + HoverPlacement.chrome.width, height: popover.height + HoverPlacement.chrome.height)
    let x = placement.side == .right ? placement.tip.x : placement.tip.x - size.width
    return CGRect(x: x, y: placement.tip.y - size.height / 2, width: size.width, height: size.height)
}

/// Visible-pixel rects of a pose, in panel coordinates.
private func pixels(_ pose: ArtProfile, _ layout: MascotLayout) -> [CGRect] {
    let frame = layout.artFrame, scale = frame.width / CGFloat(pose.canvas)
    return pose.rows.enumerated().compactMap { index, span in
        span.map { CGRect(x: frame.minX + CGFloat($0.lowerBound) * scale, y: frame.maxY - CGFloat(index + 1) * scale,
                          width: CGFloat($0.count) * scale, height: scale) }
    }
}

private func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    hypot(max(b.minX - a.maxX, 0, a.minX - b.maxX), max(b.minY - a.maxY, 0, a.minY - b.maxY))
}

@Suite struct MascotLayoutTests {
    @Test func designMetricsAtTheSpecifiedSizes() {
        // badge-metrics.json at a3c799b.
        typealias Capsule = MascotLayout.Capsule
        typealias Row = (side: CGFloat, width: CGFloat, lane: CGFloat, count: Capsule, demo: Capsule, inset: CGFloat, gap: CGFloat)
        let r64: Row = (64, 96, 28, Capsule(height: 20, fontSize: 12, padding: 6), Capsule(height: 16, fontSize: 9, padding: 5), 4, 6)
        let r128: Row = (128, 128, 36, Capsule(height: 28, fontSize: 16, padding: 8), Capsule(height: 20, fontSize: 11, padding: 6), 6, 8)
        let r256: Row = (256, 256, 48, Capsule(height: 40, fontSize: 22, padding: 10), Capsule(height: 24, fontSize: 13, padding: 7), 8, 12)
        let expected = [r64, r128, r256]
        for row in expected {
            let layout = MascotLayout(artSide: row.side)
            #expect(layout.panelWidth == row.width && layout.laneHeight == row.lane, "\(row.side)")
            #expect(layout.count == row.count && layout.demo == row.demo)
            #expect(layout.inset == row.inset && layout.minimumGap == row.gap)
            #expect(layout.panelSize == CGSize(width: row.width, height: row.side + row.lane))
            #expect(layout.artFrame.midX == row.width / 2 && layout.artFrame.minY == 0, "art centred on the ground")
        }
        #expect(MascotLayout(artSide: 64).artFrame.minX == 16, "16 pt inset at 64 pt")
    }

    @Test func fullLabelsFitWithTheMinimumGapAtEverySize() {
        for side in stride(from: CGFloat(64), through: 256, by: 16) {
            let layout = MascotLayout(artSide: side)
            let used = 2 * layout.inset + layout.demoWidth + layout.widestCountWidth + layout.minimumGap
            #expect(used <= layout.panelWidth, "DEMO and 99+ fit at \(side)")
        }
    }

    @Test func intermediateSizesInterpolateAndRoundUp() {
        let layout = MascotLayout(artSide: 80)
        #expect(layout.count == .init(height: 22, fontSize: 13, padding: 7))
        #expect(layout.laneHeight == 30 && layout.inset == 5 && layout.minimumGap == 7)
        let needed: CGFloat = 2 * 5 + 41 + 39 + 7
        #expect(layout.panelWidth == max(96, needed))
    }

    @Test func resizingKeepsTheGroundPointOnScreen() {
        let small = MascotLayout(artSide: 64), large = MascotLayout(artSide: 256)
        let origin = CGPoint(x: 500, y: 300)
        let groundBefore = CGPoint(x: origin.x + small.ground.x, y: origin.y + small.ground.y)
        let resized = large.origin(resizedFrom: small, at: origin)
        #expect(CGPoint(x: resized.x + large.ground.x, y: resized.y + large.ground.y) == groundBefore)
    }
}

@Suite struct HoverPlacementTests {
    @Test func sitsBesideTheCharacterBelowTheTags() {
        for side in [CGFloat(64), 128, 256] {
            for popover in [short, tall] {
                let layout = MascotLayout(artSide: side)
                let placement = HoverPlacement.place(art: block, layout: layout, popover: popover,
                                                     panelOrigin: CGPoint(x: 600, y: 300), screen: screen)
                let rect = window(placement, popover)
                #expect(placement.side == .right)
                #expect(placement.laneClear && !rect.intersects(layout.tagBand), "tags clear at \(side)")
                #expect(pixels(block, layout).allSatisfy { !$0.intersects(rect) }, "no overlap at \(side)")
                let nearest = pixels(block, layout).map { gap($0, rect) }.min()!
                #expect(nearest <= 12 && nearest >= HoverPlacement.clearance - 0.01, "gap \(nearest) at \(side)")
            }
        }
    }

    @Test func flipsLeftAtTheRightScreenEdge() {
        let layout = MascotLayout(artSide: 128)
        let placement = HoverPlacement.place(art: block, layout: layout, popover: short,
                                             panelOrigin: CGPoint(x: screen.maxX - 152, y: 200), screen: screen)
        #expect(placement.side == .left)
        #expect(abs(placement.tip.x - (52 * 0.5 - HoverPlacement.clearance)) < 0.01)
    }

    @Test func screenWinsOverTheLaneOnlyWhenBothCannotHold() {
        let layout = MascotLayout(artSide: 64)
        // Tall summary, mascot 24 pt above the bottom of the screen: no room below the tags.
        let low = HoverPlacement.place(art: block, layout: layout, popover: tall,
                                       panelOrigin: CGPoint(x: 600, y: 24), screen: screen)
        #expect(!low.laneClear)
        #expect(window(low, tall).minY + 24 >= 0, "on screen")
        let roomy = HoverPlacement.place(art: block, layout: layout, popover: tall,
                                         panelOrigin: CGPoint(x: 600, y: 120), screen: screen)
        #expect(roomy.laneClear)
    }

    @Test func shippedPackEveryFrameIsClearAndWithinTwelvePoints() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pack = try MascotPack.load(from: root.appendingPathComponent("assets/mascots/\(MascotPack.defaultPackID)")).get()
        for state in MascotState.allCases {
            let art = try #require(pack.artProfiles[state])
            let poses = try #require(pack.poseProfiles[state])
            for side in [CGFloat(64), 128, 256] {
                for popover in [short, tall] {
                    let layout = MascotLayout(artSide: side)
                    let placement = HoverPlacement.place(art: art, poses: poses, layout: layout, popover: popover,
                                                         panelOrigin: CGPoint(x: 600, y: 300), screen: screen)
                    let rect = window(placement, popover)
                    #expect(placement.laneClear && !rect.intersects(layout.tagBand))
                    for pose in poses {
                        let visible = pixels(pose, layout)
                        #expect(visible.allSatisfy { !$0.intersects(rect) }, "overlap: \(state) \(side)")
                        let nearest = visible.map { gap($0, rect) }.min()!
                        #expect(nearest <= 12, "gap \(nearest) pt: \(state) \(side) \(popover)")
                    }
                }
            }
        }
    }

    @Test func attentionOutlineCoversTheSwayEnvelope() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pack = try MascotPack.load(from: root.appendingPathComponent("assets/mascots/\(MascotPack.defaultPackID)")).get()
        let poses = try #require(pack.poseProfiles[.attention])
        let upright = try #require(ArtProfile.union(poses))
        let swept = try #require(pack.artProfiles[.attention])
        // Upright attention starts at row 25; tilting raises it. Design's rotated bounding
        // rectangles give ~17.94; the pixel-exact sweep is tighter but must still rise well above.
        let sweptTop = swept.top ?? 255
        #expect(upright.top == 25)
        #expect(sweptTop <= 20, "swept top \(sweptTop)")
        for (row, span) in upright.rows.enumerated() {
            guard let span else { continue }
            let outer = try #require(swept.rows[row])
            #expect(outer.lowerBound <= span.lowerBound && outer.upperBound >= span.upperBound, "row \(row)")
        }
    }

    @Test func unionIsTheOutlineNoPoseCrosses() {
        let a = ArtProfile(canvas: 2, rows: [0...0, nil])
        let b = ArtProfile(canvas: 2, rows: [1...1, 0...1])
        #expect(ArtProfile.union([a, b]) == ArtProfile(canvas: 2, rows: [0...1, 0...1]))
        #expect(ArtProfile.union([a, ArtProfile(canvas: 3, rows: [nil, nil, nil])]) == nil)
    }
}
