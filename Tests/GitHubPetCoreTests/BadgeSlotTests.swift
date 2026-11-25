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
            ($0, BuiltInPackCache.load(from: root.appendingPathComponent("assets/mascots/\($0.rawValue)"), expectedID: $0.rawValue))
        })
    }()
    private static func pack(_ skin: MascotSkin) throws -> MascotPack { try packs[skin]!.get() }
    /// A representative sample: the design stops (64/128/256), the 96 pt panel-width floor, sizes
    /// either side of it and of 128 (where interpolation changes segment), and 192.
    private static let sizes: [CGFloat] = [64, 80, 96, 100, 112, 128, 160, 192, 224, 256]

    /// #138: the animated packs keep `main`'s layout at every size Settings offers. Pinned from the v1
    /// packs on `main` (88b466d): [size, lane, slot x, count range, panel width, panel height].
    private static let mainLayouts: [MascotSkin: (artTopInset: Int, rows: [[Double]])] = [
        .mona: (20, [[64, 18, 56, 3.4999999459832907, 96, 82], [80, 20, 53, 6.019770074635744, 97, 100],
                     [96, 21, 55, 7.807317280210555, 102, 117], [112, 21, 61, 8.192308455705643, 112, 133],
                     [128, 22, 75, 8.064722875133157, 128, 150], [144, 23, 88, 8.160995589569211, 144, 167],
                     [160, 22, 102, 7.477204928174615, 160, 182], [176, 22, 116, 7.1874999068677425, 176, 198],
                     [192, 21, 130, 6.999999803490937, 192, 213], [208, 21, 143, 8.506837556138635, 208, 229],
                     [224, 19, 157, 10.69273952767253, 224, 243], [240, 19, 171, 16.355234139598906, 240, 259],
                     [256, 17, 186, 25.33762408979237, 256, 273]]),
        .littleChris: (19, [[64, 15, 50, 2.6323079159483314, 96, 79], [80, 15, 53, 3.9319970831274986, 97, 95],
                            [96, 16, 55, 3.782350316643715, 102, 112], [112, 15, 61, 2.859467785805464, 112, 127],
                            [128, 14, 72, 3.650360928848386, 128, 142], [144, 14, 81, 3.8058049604296684, 144, 158],
                            [160, 13, 91, 4.294486901722848, 160, 173], [176, 12, 101, 4.0183339305222034, 176, 188],
                            [192, 11, 110, 3.940493395552039, 192, 203], [208, 10, 120, 3.6708336658775806, 208, 218],
                            [224, 10, 129, 4.5879854913800955, 224, 234], [240, 9, 139, 4.323896647430956, 240, 249],
                            [256, 7, 149, 3.8599200192838907, 256, 263]]),
    ]

    @Test func bundledPacksKeepMainsLayoutAtEverySettingsSize() throws {
        for skin in MascotSkin.allCases {
            let pack = try Self.pack(skin), pinned = try #require(Self.mainLayouts[skin])
            #expect(pack.artTopInset == pinned.artTopInset, "\(skin) art top")
            #expect(pinned.rows.map { $0[0] } == Array(stride(from: 64.0, through: 256, by: 16)), "every Settings size")
            for row in pinned.rows {
                let layout = MascotLayout(artSide: row[0], pack: pack)
                let now = [Double(layout.laneHeight), Double(layout.countSlotX), Double(layout.maxCountOffset),
                           Double(layout.panelWidth), Double(layout.panelSize.height)]
                #expect(zip(now, row.dropFirst()).allSatisfy { abs($0 - $1) < 0.001 }, "\(skin) at \(row[0]): \(now)")
            }
        }
    }

    /// Panel x of the head's right edge.
    private func headEdge(_ layout: MascotLayout, _ pack: MascotPack) throws -> CGFloat {
        // The slot follows the states' head (#138: clip poses never move it).
        let head = try #require(MascotLayout.headRight(MascotState.allCases.flatMap(pack.poseContours)))
        return layout.artFrame.minX + CGFloat(head + 1) * layout.artSide / CGFloat(MascotPack.canvasSize)
    }

    @Test func monaKeepsHerPlacementAtTheSampledSizes() throws {
        let pack = try Self.pack(.mona)
        for side in Self.sizes {
            let layout = MascotLayout(artSide: side, pack: pack)
            // Before #116 and #138: her states and the attention lean only.
            let states = MascotState.allCases.flatMap(pack.poseContours)
            let before = MascotLayout(artSide: side, contours: states + pack.leaningContours)
            #expect(layout.laneHeight == before.laneHeight && layout.countSlotX == before.countSlotX
                    && abs(layout.maxCountOffset - before.maxCountOffset) < 0.001,
                    "Mona's slot, lane and count range unchanged at \(side)")
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
                        // Near-touching, or at the bottom of its range over a clip pose that ducks lower (#138).
                        #expect(clear >= target - 0.001 && (clear <= target + 2 || offset == 0 || abs(offset - layout.maxCountOffset) < 0.001),
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
