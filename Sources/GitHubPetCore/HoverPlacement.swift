import CoreGraphics
import Foundation
import ImageIO

/// Where the character is visibly drawn: for each canvas row (top row first), the horizontal
/// extent of pixels with alpha above about 6%, or nil for an empty row.
public struct ArtProfile: Equatable, Sendable {
    public var canvas: Int
    public var rows: [ClosedRange<Int>?]

    public init(canvas: Int, rows: [ClosedRange<Int>?]) {
        self.canvas = canvas
        self.rows = rows
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

    /// Earliest canvas row the art's bounding rectangle reaches when rotated up to ±`degrees`
    /// about `pivot`, sampled every 0.1° (design's conservative sway bound, rounded down).
    public func rotatedBoundsTop(degrees: Double, pivot: CGPoint) -> Int? {
        guard let top = top, let bottom = bottom else { return nil }
        let left = rows.compactMap { $0?.lowerBound }.min()!, right = rows.compactMap { $0?.upperBound }.max()! + 1
        let corners = [(Double(left), Double(top)), (Double(right), Double(top)),
                       (Double(left), Double(bottom + 1)), (Double(right), Double(bottom + 1))]
        let px = Double(pivot.x), py = Double(pivot.y)
        var highest = Double(top)
        for step in stride(from: -degrees, through: degrees + 0.0001, by: 0.1) {
            let angle = step * .pi / 180
            for (x, y) in corners { highest = min(highest, py + (x - px) * sin(angle) + (y - py) * cos(angle)) }
        }
        return Int(highest.rounded(.down))
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

/// Mascot panel geometry for an art size: compact badge spacing (design #28 revision,
/// docs/design/notifications/compact-badge-spacing.md at 05ea2cd). The S×S art sits at the
/// bottom, centred in a panel at least 96 pt wide. The count capsule's top is the panel's top
/// edge and DEMO is centred vertically on it; both may enter the art canvas's transparent
/// margin but stay at least `labelClearance` above the earliest visible pixel any frame or pose
/// can reach (`artTopFloor`, canvas pixels, pack-specific). Metrics between 64, 128 and 256 pt
/// are interpolated linearly over 64–128 and 128–256 and rounded up.
public struct MascotLayout: Equatable, Sendable {
    public struct Capsule: Equatable, Sendable {
        public var height: CGFloat
        public var fontSize: CGFloat
        /// Horizontal text inset per side; width is `max(height, ceil(text) + 2 × padding)`.
        public var padding: CGFloat
    }

    public var artSide: CGFloat
    /// Earliest canvas row (of 256) any frame or pose can draw a visible pixel in; 0 when
    /// unknown, which keeps the labels entirely above the art canvas.
    public var artTopFloor: Int
    public var count: Capsule
    public var demo: Capsule
    /// Horizontal inset of the capsules from the panel's sides.
    public var inset: CGFloat
    public var minimumGap: CGFloat
    /// Native SF widths measured by design for "DEMO" and the widest count, "99+".
    public var demoWidth: CGFloat
    public var widestCountWidth: CGFloat

    /// Minimum vertical clearance between the labels and the visible art.
    public static let labelClearance: CGFloat = 3

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

    public init(artSide: CGFloat, artTopFloor: Int) {
        let side = min(max(artSide, 64), 256)
        let (a, b) = side <= 128 ? (Self.stops[0], Self.stops[1]) : (Self.stops[1], Self.stops[2])
        let t = (side - a.side) / (b.side - a.side)
        func mix(_ path: KeyPath<Stop, CGFloat>) -> CGFloat {
            let value = a[keyPath: path] + (b[keyPath: path] - a[keyPath: path]) * t
            return (value - 0.0001).rounded(.up)
        }
        self.artSide = artSide
        self.artTopFloor = max(artTopFloor, 0)
        count = Capsule(height: mix(\.countHeight), fontSize: mix(\.countFont), padding: mix(\.countPadding))
        demo = Capsule(height: mix(\.demoHeight), fontSize: mix(\.demoFont), padding: mix(\.demoPadding))
        inset = mix(\.inset)
        minimumGap = mix(\.gap)
        demoWidth = mix(\.demoWidth)
        widestCountWidth = mix(\.countWidth)
    }

    /// Art top below the panel's top edge: `L = max(0, ceil(countHeight + 3 − floor × S/256))`.
    public var laneHeight: CGFloat {
        max(0, (count.height + Self.labelClearance - CGFloat(artTopFloor) * artSide / 256 - 0.0001).rounded(.up))
    }
    /// Wide enough for DEMO, the widest count and the minimum gap, so the panel never changes
    /// with the count, Demo, privacy or mood.
    public var panelWidth: CGFloat {
        max(artSide, 96, 2 * inset + demoWidth + widestCountWidth + minimumGap)
    }
    public var panelSize: CGSize { CGSize(width: panelWidth, height: artSide + laneHeight) }
    /// The art square inside the panel (origin at the panel's bottom-left).
    public var artFrame: CGRect { CGRect(x: (panelWidth - artSide) / 2, y: 0, width: artSide, height: artSide) }
    /// The ground point (the pack's anchor [128, 232]) in panel coordinates.
    public var ground: CGPoint { CGPoint(x: panelWidth / 2, y: 24 * artSide / 256) }
    /// Where the capsules can be: from the panel's top edge down one count height, inside the
    /// panel insets (panel coordinates, origin bottom-left).
    public var tagBand: CGRect {
        CGRect(x: inset, y: panelSize.height - count.height, width: panelWidth - 2 * inset, height: count.height)
    }
    /// Vertical distance from the labels' bottom to the earliest visible art (≥ 3 pt).
    public var labelToArtClearance: CGFloat {
        laneHeight + CGFloat(artTopFloor) * artSide / 256 - count.height
    }

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
    /// False only when the screen is too short to keep the popover both on screen and below
    /// the tags (a small mascot near the bottom of the screen with a tall summary).
    public var laneClear: Bool

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
        // Vertical range for the popover's centre: below the tags, and on screen.
        let onScreenLow = screen.minY - panelOrigin.y + half
        let onScreenHigh = screen.maxY - panelOrigin.y - half
        let belowTags = layout.tagBand.minY - half
        var high = min(belowTags, onScreenHigh)
        let laneClear = high >= onScreenLow
        if !laneClear { high = onScreenLow }   // staying on screen wins, as AppKit would force
        let low = min(onScreenLow, high)
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
        func best(right: Bool) -> CGPoint {
            typealias Candidate = (y: CGFloat, x: CGFloat, worst: CGFloat, tip: CGFloat)
            var candidates: [Candidate] = []
            var y = high
            while y >= low - 0.001 {
                if let range = rows(centerY: y), let outer = edge(art, range, right: right) {
                    let x = right ? outer + clearance : outer - clearance
                    let worst = poses.map { pose in
                        edge(pose, range, right: right).map { right ? x - $0 : $0 - x } ?? .infinity
                    }.max()!
                    candidates.append((y, x, worst, tipDistance(CGPoint(x: x, y: y), poses[0])))
                }
                y -= 1
            }
            // Minimise the larger of the two distances (arrow to static art, window to any pose).
            let choice = candidates.min {
                let (a, b) = (max($0.tip, $0.worst), max($1.tip, $1.worst))
                return a < b - 0.001 || (abs(a - b) < 0.001 && $0.worst < $1.worst)
            }
            return choice.map { CGPoint(x: $0.x, y: $0.y) }
                ?? CGPoint(x: right ? frame.maxX + clearance : frame.minX - clearance, y: min(high, max(low, middle)))
        }

        let rightTip = best(right: true), leftTip = best(right: false)
        let needed = popover.width + chrome.width
        let roomRight = screen.maxX - (panelOrigin.x + rightTip.x)
        let roomLeft = panelOrigin.x + leftTip.x - screen.minX
        return roomRight >= needed || roomRight >= roomLeft
            ? HoverPlacement(side: .right, tip: rightTip, laneClear: laneClear)
            : HoverPlacement(side: .left, tip: leftTip, laneClear: laneClear)
    }
}
