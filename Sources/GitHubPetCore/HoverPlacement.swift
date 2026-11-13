import CoreGraphics
import Foundation
import ImageIO

/// Where the character is visibly drawn: for each canvas row (top row first), the horizontal
/// extent of pixels with alpha above about 6%, or nil for an empty row.
public struct ArtProfile: Equatable, Sendable {
    public var canvas: Int
    public var rows: [ClosedRange<Int>?]
    /// First visible row in each column (nil: empty column): the art's actual top contour.
    public var columnTops: [Int?]

    public init(canvas: Int, rows: [ClosedRange<Int>?], columnTops: [Int?]? = nil) {
        self.canvas = canvas
        self.rows = rows
        // Without a measured contour, assume each row's whole span is filled (conservative).
        self.columnTops = columnTops ?? (0..<canvas).map { column in
            rows.firstIndex { $0?.contains(column) == true }
        }
    }

    /// First visible row, i.e. the transparent margin above the character.
    public var top: Int? { rows.firstIndex { $0 != nil } }
    public var bottom: Int? { rows.lastIndex { $0 != nil } }

    /// Decodes a PNG and measures pixels with alpha above `alphaThreshold` (of 255), or nil if
    /// it is undecodable. The default counts visibly drawn pixels; 0 counts any coverage.
    public init?(png data: Data, alphaThreshold: UInt8 = 16) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Bitmap rows are stored top row first.
        rows = (0..<height).map { row in
            let visible = (0..<width).filter { pixels[(row * width + $0) * 4 + 3] > alphaThreshold }
            return visible.first.map { $0...visible.last! }
        }
        columnTops = (0..<width).map { column in
            (0..<height).first { pixels[($0 * width + column) * 4 + 3] > alphaThreshold }
        }
        canvas = height
    }

    /// Union of several profiles of the same canvas: the outline no pose ever crosses.
    public static func union(_ profiles: [ArtProfile]) -> ArtProfile? {
        guard let first = profiles.first, profiles.allSatisfy({ $0.canvas == first.canvas }) else { return nil }
        let rows = (0..<first.rows.count).map { index -> ClosedRange<Int>? in
            let spans = profiles.compactMap { $0.rows[index] }
            guard let low = spans.map(\.lowerBound).min(), let high = spans.map(\.upperBound).max() else { return nil }
            return low...high
        }
        return ArtProfile(canvas: first.canvas, rows: rows)
    }

    /// The outline swept by rotating this art's pixels up to ±`degrees` about `pivot` (canvas
    /// pixels, y down), sampled every 0.1° and grown by 1 px: everything a tilting pose can
    /// cover (#29 attention lean about the ground anchor [128, 232]). Pixel-exact, so tighter
    /// than design's rotated bounding rectangles (top ~17.94 px) while still covering every pixel.
    public func swept(degrees: Double, pivot: CGPoint) -> ArtProfile {
        var low = [Int](repeating: .max, count: canvas), high = [Int](repeating: .min, count: canvas)
        func mark(_ x: Double, _ y: Double) {
            let column = Int(x.rounded(.down))
            for row in (Int(y.rounded(.down)) - 1)...(Int(y.rounded(.down)) + 1) where (0..<canvas).contains(row) {
                low[row] = max(0, min(low[row], column - 1))
                high[row] = min(canvas - 1, max(high[row], column + 1))
            }
        }
        let px = Double(pivot.x), py = Double(pivot.y)
        for step in stride(from: -degrees, through: degrees + 0.0001, by: 0.1) {
            let angle = step * .pi / 180, c = cos(angle), s = sin(angle)
            func rotate(_ x: Double, _ y: Double) -> (Double, Double) {
                (px + (x - px) * c - (y - py) * s, py + (x - px) * s + (y - py) * c)
            }
            for (row, span) in rows.enumerated() {
                guard let span else { continue }
                // Both long edges of the row's pixel strip become rotated segments; mark each one
                // at its ends and wherever it crosses a row boundary.
                for edgeY in [Double(row), Double(row + 1)] {
                    let a = rotate(Double(span.lowerBound), edgeY), b = rotate(Double(span.upperBound + 1), edgeY)
                    mark(a.0, a.1)
                    mark(b.0, b.1)
                    let (top, bottom) = (min(a.1, b.1), max(a.1, b.1))
                    guard bottom - top > 0.0001 else { continue }
                    var y = top.rounded(.up)
                    while y <= bottom {
                        let t = (y - a.1) / (b.1 - a.1)
                        mark(a.0 + (b.0 - a.0) * t, y)
                        y += 1
                    }
                }
            }
        }
        return ArtProfile(canvas: canvas, rows: (0..<canvas).map { low[$0] <= high[$0] ? low[$0]...high[$0] : nil })
    }

    /// Points on this art's outline that bound it from above and the sides (canvas pixels, y
    /// down): each column's top edge, the steps between columns and each row's outer ends, every
    /// half pixel. Rotating these finds the top contour of the rotated art.
    public var outlinePoints: [CGPoint] {
        var points: [CGPoint] = []
        for (column, top) in columnTops.enumerated() {
            guard let top else { continue }
            for dx in [0.0, 0.5, 1.0] { points.append(CGPoint(x: Double(column) + dx, y: Double(top))) }
            let next = column + 1 < canvas ? columnTops[column + 1] : nil
            let lower = max(top, next ?? (rows.lastIndex { $0 != nil } ?? top) + 1)
            var y = Double(min(top, next ?? top))
            while y <= Double(lower) { points.append(CGPoint(x: Double(column + 1), y: y)); y += 0.5 }
        }
        for (row, span) in rows.enumerated() {
            guard let span else { continue }
            for y in [Double(row), Double(row) + 0.5, Double(row + 1)] {
                points.append(CGPoint(x: Double(span.lowerBound), y: y))
                points.append(CGPoint(x: Double(span.upperBound + 1), y: y))
            }
        }
        return points
    }

    /// Top contour of art with these outline points rotated by every angle in `from...to` degrees
    /// (sampled every `step`°) about `pivot`, grown by `margin` pixels. Plain point math: cheap
    /// enough to run for each drawn pose.
    public static func rotatedContour(_ points: [CGPoint], canvas: Int, from: Double, to: Double, pivot: CGPoint,
                                      margin: Int = 1, step: Double = 0.1) -> [Int?] {
        var tops = [Int](repeating: .max, count: canvas)
        let px = Double(pivot.x), py = Double(pivot.y)
        var angles = Array(stride(from: from, through: to, by: step))
        if angles.last != to { angles.append(to) }
        for degrees in angles {
            let angle = degrees * .pi / 180, c = cos(angle), s = sin(angle)
            for point in points {
                let x = Double(point.x), y = Double(point.y)
                let rx = px + (x - px) * c - (y - py) * s, ry = py + (x - px) * s + (y - py) * c
                let column = Int(rx.rounded(.down)), row = Int(ry.rounded(.down)) - margin
                for col in (column - margin)...(column + margin) where (0..<canvas).contains(col) {
                    tops[col] = min(tops[col], max(row, 0))
                }
            }
        }
        return tops.map { $0 == .max ? nil : $0 }
    }

    public func rotatedContour(from: Double, to: Double, pivot: CGPoint, margin: Int = 1, step: Double = 0.1) -> [Int?] {
        Self.rotatedContour(outlinePoints, canvas: canvas, from: from, to: to, pivot: pivot, margin: margin, step: step)
    }

    /// The native placeholder figure's outline, as fractions of its square.
    public static let placeholder: ArtProfile = {
        let canvas = 256
        let rows = (0..<canvas).map { row -> ClosedRange<Int>? in
            let y = Double(row) / Double(canvas)
            return (0.08...0.95).contains(y) ? Int(0.12 * Double(canvas))...Int(0.88 * Double(canvas)) : nil
        }
        return ArtProfile(canvas: canvas, rows: rows)
    }()
}

/// Mascot panel geometry for an art size: near-touch badge spacing (design #28,
/// docs/design/notifications/compact-badge-spacing.md at ef98a48). The S×S art sits at the bottom,
/// centred in a panel at least 96 pt wide, its top L below the panel's top edge. DEMO is fixed at
/// the leading inset; the count is left-aligned in a slot reserved for "99+" and, for each pose,
/// moves down within the lane so its rounded capsule sits `nearTouchGap` above the art's actual
/// top contour under it. L is the smallest quarter point at which the widest count (at the top)
/// and DEMO clear every pose. Metrics between 64, 128 and 256 pt are interpolated linearly over
/// 64–128 and 128–256 and rounded up.
public struct MascotLayout: Equatable, Sendable {
    public struct Capsule: Equatable, Sendable {
        public var height: CGFloat
        public var fontSize: CGFloat
        /// Horizontal text inset per side; width is `max(height, ceil(text) + 2 × padding)`.
        public var padding: CGFloat

        public func width(text: CGFloat) -> CGFloat { max(height, text.rounded(.up) + 2 * padding) }
    }

    public var artSide: CGFloat
    public var count: Capsule
    public var demo: Capsule
    /// Horizontal inset of the capsules from the panel's sides.
    public var inset: CGFloat
    public var minimumGap: CGFloat
    /// Native SF widths measured by design for "DEMO" and the widest count, "99+".
    public var demoWidth: CGFloat
    public var widestCountWidth: CGFloat
    /// Art top below the panel's top edge (top-left coordinates).
    public private(set) var laneHeight: CGFloat = 0
    /// Furthest the count moves down for any pose (any count width).
    public private(set) var maxCountOffset: CGFloat = 0

    /// Design's capsule-to-art target clearance.
    public static let nearTouchTarget: CGFloat = 1
    /// Extra room for antialiased edges at 1× and 2× backing. Design asked for 0.25 pt, enlarged
    /// as little as native measurement needs: at 0.25 and 0.5 the rasterised count touched the
    /// art at 64 pt 1× (0.0 pt); at 0.75 every pose/count/scale measured 0.6–2.0 pt, no overlap.
    public static let rasterReserve: CGFloat = 0.75
    /// Clearance the layout keeps between each capsule and the art's contour.
    public static var nearTouchGap: CGFloat { nearTouchTarget + rasterReserve }
    /// Extra clearance while the art leans: a rotated image is resampled, which widens its
    /// antialiased edge by about a backing pixel (measured: 0.5 pt is enough at 2×; at 1× the
    /// fringe consumed ~1.9 pt at 64 pt, so 1.5 pt there).
    public static func leanReserve(displayScale: CGFloat) -> CGFloat { displayScale >= 2 ? 0.5 : 1.5 }
    /// The larger lean reserve, used for the fixed lane so the panel never depends on the screen.
    public static var maxLeanReserve: CGFloat { leanReserve(displayScale: 1) }

    private struct Stop {
        var side, countHeight, countFont, countPadding, demoHeight, demoFont, demoPadding, inset, gap, demoWidth,
            countWidth: CGFloat
    }
    private static let stops = [
        Stop(side: 64, countHeight: 20, countFont: 12, countPadding: 6, demoHeight: 16, demoFont: 9, demoPadding: 5,
             inset: 4, gap: 6, demoWidth: 39, countWidth: 36),
        Stop(side: 128, countHeight: 28, countFont: 16, countPadding: 8, demoHeight: 20, demoFont: 11, demoPadding: 6,
             inset: 6, gap: 8, demoWidth: 46, countWidth: 47),
        Stop(side: 256, countHeight: 40, countFont: 22, countPadding: 10, demoHeight: 24, demoFont: 13, demoPadding: 7,
             inset: 8, gap: 12, demoWidth: 54, countWidth: 62),
    ]

    /// - Parameter contours: top contours (`ArtProfile.columnTops`, 256-px canvas) of every pose
    ///   the art can show. Empty means unknown: the labels then stay above the art square.
    public init(artSide: CGFloat, contours: [[Int?]] = []) {
        let side = min(max(artSide, 64), 256)
        let (a, b) = side <= 128 ? (Self.stops[0], Self.stops[1]) : (Self.stops[1], Self.stops[2])
        let t = (side - a.side) / (b.side - a.side)
        func mix(_ path: KeyPath<Stop, CGFloat>) -> CGFloat {
            let value = a[keyPath: path] + (b[keyPath: path] - a[keyPath: path]) * t
            return (value - 0.0001).rounded(.up)
        }
        self.artSide = artSide
        count = Capsule(height: mix(\.countHeight), fontSize: mix(\.countFont), padding: mix(\.countPadding))
        demo = Capsule(height: mix(\.demoHeight), fontSize: mix(\.demoFont), padding: mix(\.demoPadding))
        inset = mix(\.inset)
        minimumGap = mix(\.gap)
        demoWidth = mix(\.demoWidth)
        widestCountWidth = mix(\.countWidth)

        let poses = contours.isEmpty ? [[Int?](repeating: 0, count: 256)] : contours
        // The smallest whole-point L (no fractional panel heights; the count's tracking takes up
        // the rest) at which the widest count, at the top, and DEMO clear every pose, leaning ones
        // included with their extra reserve (upright poses then track back down to the normal gap).
        let widest = countFrame(width: widestCountWidth, offset: 0), demo = demoFrame
        let needed = Self.nearTouchGap + Self.maxLeanReserve
        var lane: CGFloat = 0
        while lane < count.height + needed + 1, poses.contains(where: { contour in
            clearance(contour, widest, lane: lane) < needed || clearance(contour, demo, lane: lane) < needed
        }) {
            lane += 1
        }
        laneHeight = lane
        maxCountOffset = poses.map { countOffset(contour: $0, width: count.height) }.max() ?? 0
    }

    /// W = max(S, 96, labels): stable across the count's value, Demo, privacy and mood.
    public var panelWidth: CGFloat {
        max(artSide, 96, 2 * inset + demoWidth + widestCountWidth + minimumGap)
    }
    public var panelSize: CGSize { CGSize(width: panelWidth, height: artSide + laneHeight) }
    /// The art square inside the panel (origin at the panel's bottom-left).
    public var artFrame: CGRect { CGRect(x: (panelWidth - artSide) / 2, y: 0, width: artSide, height: artSide) }
    /// The ground point (the pack's anchor [128, 232]) in panel coordinates.
    public var ground: CGPoint { CGPoint(x: panelWidth / 2, y: 24 * artSide / 256) }
    /// Leading edge of the reserved "99+" slot (top-left x).
    public var countSlotX: CGFloat { panelWidth - inset - widestCountWidth }

    /// Count capsule in top-left coordinates, moved down by `offset`.
    public func countFrame(width: CGFloat, offset: CGFloat) -> CGRect {
        CGRect(x: countSlotX, y: offset, width: width, height: count.height)
    }
    /// DEMO capsule in top-left coordinates: centred on the count's highest position.
    public var demoFrame: CGRect {
        CGRect(x: inset, y: (count.height - demo.height) / 2, width: demoWidth, height: demo.height)
    }

    /// How far the count of `width` moves down for a pose with this contour, so its capsule sits
    /// `nearTouchGap` from the art (nearest distance, not just vertically).
    public func countOffset(contour: [Int?], width: CGFloat, leaning: Bool = false, displayScale: CGFloat = 2) -> CGFloat {
        let gap = Self.nearTouchGap + (leaning ? Self.leanReserve(displayScale: displayScale) : 0)
        func clear(_ offset: CGFloat) -> CGFloat { clearance(contour, countFrame(width: width, offset: offset), lane: laneHeight) }
        guard clear(0) > gap else { return 0 }
        // Clearance shrinks as the capsule moves down; find the offset where it reaches the gap.
        var low: CGFloat = 0, high = laneHeight + artSide
        if clear(high) >= gap { return high }
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if clear(mid) >= gap { low = mid } else { high = mid }
        }
        return low
    }

    /// Nearest distance from a capsule (top-left rect, fully rounded ends) to the art below its
    /// top contour, with the art's top at `lane`; negative if they overlap. Each contour column
    /// is treated as a solid rectangle from its top edge downward (conservative).
    public func clearance(_ contour: [Int?], _ capsule: CGRect, lane: CGFloat) -> CGFloat {
        let scale = artSide / CGFloat(contour.count)
        let artLeft = (panelWidth - artSide) / 2
        let radius = capsule.height / 2
        // The capsule is every point within `radius` of this horizontal segment.
        let segmentLeft = capsule.minX + radius, segmentRight = max(capsule.maxX - radius, segmentLeft)
        let segmentY = capsule.midY
        var nearest = CGFloat.infinity
        for (column, top) in contour.enumerated() {
            guard let top else { continue }
            let left = artLeft + CGFloat(column) * scale, right = left + scale
            let artTop = lane + CGFloat(top) * scale
            let dx = max(left - segmentRight, segmentLeft - right, 0)
            let dy = max(artTop - segmentY, 0)
            nearest = min(nearest, hypot(dx, dy) - radius)
        }
        return nearest
    }

    /// Where the labels can be (panel coordinates, origin bottom-left): DEMO, and the count's
    /// reserved slot from the top edge down to the lowest the count can track.
    public var labelRects: [CGRect] {
        let height = panelSize.height
        let demo = demoFrame
        // Half a point of slack for lean angles between the sampled ones.
        let depth = maxCountOffset + 0.5 + count.height
        return [CGRect(x: demo.minX, y: height - demo.maxY, width: demo.width, height: demo.height),
                CGRect(x: countSlotX, y: height - depth, width: widestCountWidth, height: depth)]
    }

    /// The band spanning both labels (panel coordinates).
    public var tagBand: CGRect { labelRects.reduce(CGRect.null) { $0.union($1) } }

    /// Panel origin after resizing to this layout from `previous` at `origin`, keeping the
    /// ground point where it is on screen.
    public func origin(resizedFrom previous: MascotLayout, at origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + previous.ground.x - ground.x, y: origin.y + previous.ground.y - ground.y)
    }
}

/// Places the hover summary beside the visible character: right of it when the screen has
/// room, otherwise left. The popover window never overlaps any visible pixel of any frame of
/// the current state, stays below the lane's tags (DEMO, count), and stays on screen; within
/// that, its height is chosen to keep it closest to every pose. The arrow tip may point just
/// beside or below the art when the popover is much taller than the character.
public struct HoverPlacement: Equatable, Sendable {
    public enum Side: Equatable, Sendable { case right, left }

    public var side: Side
    /// Arrow tip in panel coordinates (origin at the panel's bottom-left). May lie outside the
    /// panel, so the popover is anchored to its own helper window, not to the panel.
    public var tip: CGPoint
    /// False only when the screen is too short to keep the popover both on screen and clear of
    /// the labels (a small mascot near the bottom of the screen with a tall summary).
    public var laneClear: Bool
    /// Distance from the arrow tip to the static pose's nearest visible pixel.
    public var arrowGap: CGFloat = 0

    /// Whether this placement meets #27: labels clear and the arrow within `maxGap` of the art.
    /// If not, show the compact summary instead.
    public var meetsTarget: Bool { laneClear && arrowGap <= Self.maxGap }

    /// Clearance between the popover window and the nearest visible pixel.
    public static let clearance: CGFloat = 2
    /// Largest allowed distance from the arrow tip to the character (design: 0–12 pt).
    public static let maxGap: CGFloat = 12
    /// Size the popover window adds around its content for the arrow, edges and margins
    /// (measured: 144×51 content gives a 170×77 window, whichever edge the arrow is on).
    public static let chrome = CGSize(width: 26, height: 26)

    /// - Parameters:
    ///   - art: outline no frame of the current state crosses.
    ///   - poses: the state's static pose and frames; the height minimises the largest gap to any.
    public static func place(art: ArtProfile, poses: [ArtProfile] = [], layout: MascotLayout, popover: CGSize,
                             panelOrigin: CGPoint, screen: CGRect) -> HoverPlacement {
        let poses = poses.filter { $0.canvas == art.canvas }.isEmpty ? [art] : poses.filter { $0.canvas == art.canvas }
        let frame = layout.artFrame
        let scale = frame.width / CGFloat(art.canvas)
        let half = (popover.height + chrome.height) / 2
        let windowWidth = popover.width + chrome.width
        // Vertical range for the popover's centre: on screen, and no higher than the panel.
        let low = screen.minY - panelOrigin.y + half
        let high = max(min(screen.maxY - panelOrigin.y - half, layout.panelSize.height), low)
        let labels = layout.labelRects
        let top = CGFloat(art.top ?? 0), bottom = CGFloat(art.bottom ?? (art.canvas - 1))
        let middle = frame.maxY - (top + bottom + 1) / 2 * scale

        func rows(centerY: CGFloat) -> ClosedRange<Int>? {
            let first = max(0, Int(((frame.maxY - (centerY + half)) / scale).rounded(.down)))
            let last = min(art.canvas - 1, Int(((frame.maxY - (centerY - half)) / scale).rounded(.up)))
            return first <= last ? first...last : nil
        }
        func edge(_ profile: ArtProfile, _ range: ClosedRange<Int>, right: Bool) -> CGFloat? {
            let spans = profile.rows[range].compactMap { $0 }
            guard !spans.isEmpty else { return nil }
            return right ? frame.minX + CGFloat(spans.map(\.upperBound).max()! + 1) * scale
                         : frame.minX + CGFloat(spans.map(\.lowerBound).min()!) * scale
        }
        /// Distance from an arrow tip (panel coordinates) to the nearest visible pixel of `pose`.
        func tipDistance(_ tip: CGPoint, _ pose: ArtProfile) -> CGFloat {
            var nearest = CGFloat.infinity
            for (index, span) in pose.rows.enumerated() {
                guard let span else { continue }
                let minX = frame.minX + CGFloat(span.lowerBound) * scale, maxX = frame.minX + CGFloat(span.upperBound + 1) * scale
                let maxY = frame.maxY - CGFloat(index) * scale, minY = maxY - scale
                nearest = min(nearest, hypot(max(minX - tip.x, 0, tip.x - maxX), max(minY - tip.y, 0, tip.y - maxY)))
            }
            return nearest
        }
        /// Best centre and tip x for one side: the height whose larger distance (arrow tip to the
        /// static pose, or popover window to any pose) is smallest.
        func best(right: Bool) -> (CGPoint, Bool, CGFloat) {
            typealias Candidate = (y: CGFloat, x: CGFloat, worst: CGFloat, tip: CGFloat, clear: Bool)
            var candidates: [Candidate] = []
            var y = high
            while y >= low - 0.001 {
                if let range = rows(centerY: y), let outer = edge(art, range, right: right) {
                    let x = right ? outer + clearance : outer - clearance
                    let worst = poses.map { pose in
                        edge(pose, range, right: right).map { right ? x - $0 : $0 - x } ?? .infinity
                    }.max()!
                    let window = CGRect(x: right ? x : x - windowWidth, y: y - half, width: windowWidth, height: 2 * half)
                    let clear = !labels.contains { $0.intersects(window) }
                    candidates.append((y, x, worst, tipDistance(CGPoint(x: x, y: y), poses[0]), clear))
                }
                y -= 1
            }
            // Labels clear if possible (otherwise staying on screen wins, as AppKit would force);
            // then minimise the larger of the two distances (arrow to static art, window to any pose).
            let pool = candidates.contains { $0.clear } ? candidates.filter { $0.clear } : candidates
            let choice = pool.min {
                let (a, b) = (max($0.tip, $0.worst), max($1.tip, $1.worst))
                return a < b - 0.001 || (abs(a - b) < 0.001 && $0.worst < $1.worst)
            }
            return choice.map { (CGPoint(x: $0.x, y: $0.y), $0.clear, $0.tip) }
                ?? (CGPoint(x: right ? frame.maxX + clearance : frame.minX - clearance, y: min(high, max(low, middle))),
                    false, .infinity)
        }

        let (rightTip, rightClear, rightGap) = best(right: true), (leftTip, leftClear, leftGap) = best(right: false)
        let needed = popover.width + chrome.width
        let roomRight = screen.maxX - (panelOrigin.x + rightTip.x)
        let roomLeft = panelOrigin.x + leftTip.x - screen.minX
        return roomRight >= needed || roomRight >= roomLeft
            ? HoverPlacement(side: .right, tip: rightTip, laneClear: rightClear, arrowGap: rightGap)
            : HoverPlacement(side: .left, tip: leftTip, laneClear: leftClear, arrowGap: leftGap)
    }
}

/// What a hover placement was computed for. The open summary is re-placed when any of it
/// changes (content grew or shrank, the panel moved or resized, mood or gesture changed), never
/// per animation frame.
public struct HoverPlacementInputs: Equatable, Sendable {
    public var contentSize: CGSize
    public var panelFrame: CGRect
    public var state: MascotState
    public var gesture: Bool

    public init(contentSize: CGSize, panelFrame: CGRect, state: MascotState, gesture: Bool) {
        self.contentSize = contentSize
        self.panelFrame = panelFrame
        self.state = state
        self.gesture = gesture
    }

    /// Whether `other` needs a new placement (sizes compared to half a point).
    public func needsReplacement(for other: HoverPlacementInputs) -> Bool {
        abs(contentSize.width - other.contentSize.width) > 0.5 || abs(contentSize.height - other.contentSize.height) > 0.5
            || panelFrame != other.panelFrame || state != other.state || gesture != other.gesture
    }
}
