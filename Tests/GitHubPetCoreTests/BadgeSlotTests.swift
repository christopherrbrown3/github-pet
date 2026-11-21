import CoreGraphics
import Foundation
import Testing
@testable import GitHubPetCore

/// #116: the count stays on each skin's silhouette. Mona keeps the slot at the trailing inset;
/// a narrower skin (Little Chris) moves it left so it sits over the head's upper-right region.
@Suite struct BadgeSlotTests {
    /// Loaded once: pack loading sweeps the leaning contours, the slowest part of these tests.
    private static let packs: [MascotSkin: Result<MascotPack, MascotPackErrors>] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Dictionary(uniqueKeysWithValues: MascotSkin.allCases.map {
            ($0, MascotPack.load(from: root.appendingPathComponent("assets/mascots/\($0.rawValue)")))
        })
    }()
    private static func pack(_ skin: MascotSkin) throws -> MascotPack { try packs[skin]!.get() }
    /// A representative sample: the design stops (64/128/256), the 96 pt panel-width floor, sizes
    /// either side of it and of 128 (where interpolation changes segment), and 192.
    private static let sizes: [CGFloat] = [64, 80, 96, 100, 112, 128, 160, 192, 224, 256]

    /// Panel x of the head's right edge.
    private func headEdge(_ layout: MascotLayout, _ pack: MascotPack) throws -> CGFloat {
        let head = try #require(MascotLayout.headRight(pack.uprightContours))
        return layout.artFrame.minX + CGFloat(head + 1) * layout.artSide / CGFloat(MascotPack.canvasSize)
    }

    @Test func monaKeepsHerPlacementAtTheSampledSizes() throws {
        let pack = try Self.pack(.mona)
        for side in Self.sizes {
            let layout = MascotLayout(artSide: side, pack: pack)
            let before = MascotLayout(artSide: side, contours: pack.allContours)
            #expect(layout == before, "Mona's slot, lane and count range unchanged at \(side)")
            #expect(layout.countSlotX == layout.panelWidth - layout.inset - layout.widestCountWidth)
        }
    }

    @Test(arguments: MascotSkin.allCases)
    func countSitsOverTheHeadAtTheSampledSizes(skin: MascotSkin) throws {
        let pack = try Self.pack(skin)
        for side in Self.sizes {
            let layout = MascotLayout(artSide: side, pack: pack)
            let edge = try headEdge(layout, pack)
            let one = layout.countFrame(width: layout.count.height, offset: 0)
            // DEMO's lane wins where the head is too close to it (Little Chris below about 100 pt).
            let demoFloor = layout.inset + layout.demoWidth + layout.minimumGap
            #expect(one.midX <= edge + layout.count.height / 4 + 0.001 || layout.countSlotX == demoFloor,
                    "\(skin) one-digit centre at \(side)")
            #expect(layout.countSlotX < edge, "\(skin) leading edge over the head at \(side)")
            #expect(layout.countSlotX >= demoFloor, "\(skin) clear of DEMO at \(side)")
            #expect(layout.countFrame(width: layout.widestCountWidth, offset: 0).maxX <= layout.panelWidth - layout.inset)
        }
    }

    /// Every upright pose, every count width: the count rests near-touching the art inside the
    /// panel. Before #116, Little Chris's count at 256 pt had nothing under it and dropped below
    /// the panel.
    @Test(arguments: MascotSkin.allCases)
    func countRestsOnTheArtInsideThePanel(skin: MascotSkin) throws {
        let pack = try Self.pack(skin)
        let gap = MascotLayout.nearTouchGap
        for side in Self.sizes {
            let layout = MascotLayout(artSide: side, pack: pack)
            for contour in pack.uprightContours {
                #expect(layout.clearance(contour, layout.demoFrame, lane: layout.laneHeight) >= gap - 0.001)
                for width in [layout.count.height, layout.widestCountWidth] {
                    for scale in [CGFloat(1), 2] {
                        let offset = layout.countOffset(contour: contour, width: width, displayScale: scale)
                        let frame = layout.countFrame(width: width, offset: offset)
                        let clear = layout.clearance(contour, frame, lane: layout.laneHeight)
                        let target = gap + MascotLayout.uprightReserve(displayScale: scale)
                        #expect(frame.maxY <= layout.panelSize.height, "\(skin) count inside the panel at \(side)")
                        #expect(clear >= target - 0.001 && clear <= target + 2,
                                "\(skin) count near-touching at \(side) \(scale)x: \(clear)")
                    }
                }
            }
        }
    }

    @Test func headRightIsTheNarrowestPosesHeadEdge() {
        var wide = [Int?](repeating: nil, count: 256), narrow = wide
        for column in 50...210 { wide[column] = 20 }
        wide[220] = 20 + MascotLayout.headDepth + 1   // a lower arm: not head
        for column in 70...160 { narrow[column] = 30 }
        narrow[165] = 30 + MascotLayout.headDepth      // still within the head band
        #expect(MascotLayout.headRight([wide]) == 210)
        #expect(MascotLayout.headRight([wide, narrow]) == 165)
        #expect(MascotLayout.headRight([]) == nil)
        #expect(MascotLayout.headRight([[Int?](repeating: nil, count: 256)]) == nil)
    }

    @Test func narrowHeadMovesTheSlotButNeverIntoDemo() {
        var head = [Int?](repeating: nil, count: 256)
        for column in 100...140 { head[column] = 20 }
        let standard = MascotLayout(artSide: 128, contours: [head])
        let moved = MascotLayout(artSide: 128, contours: [head], headContours: [head])
        #expect(moved.countSlotX < standard.countSlotX)
        // Edge 141 canvas px = 70.5 pt; a 28 pt count's centre at most 7 pt past it: 70.5 + 7 - 14,
        // rounded down to a whole point.
        #expect(moved.countSlotX == 63)
        var tiny = [Int?](repeating: nil, count: 256)
        tiny[30] = 20
        let floor = MascotLayout(artSide: 128, contours: [tiny], headContours: [tiny])
        #expect(floor.countSlotX == floor.inset + floor.demoWidth + floor.minimumGap)
    }

    @Test func nothingUnderTheCountKeepsItAtTheTop() {
        var left = [Int?](repeating: nil, count: 256)
        for column in 0...40 { left[column] = 60 }
        let layout = MascotLayout(artSide: 128, contours: [left])
        #expect(layout.countOffset(contour: left, width: layout.count.height) == 0)
    }
}
