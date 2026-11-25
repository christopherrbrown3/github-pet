import CoreGraphics
import CryptoKit
import Foundation
import GitHubPetCore
import ImageIO

// Designer tool (#138 frame sequences): turns generated 4×4 clip sheets into registered v2 clip frames.
// Every frame is cut from its sheet, cleaned (faint fringe and specks dropped), and registered to the
// skin's idle-00: the face (the largest region of the skin's face colour) fixes the scale and the
// horizontal position, and the lowest visible pixel sits on the ground row, so generated wobble in head
// size and position is removed. Frame 0 can be idle-00 itself, so a clip starts exactly on the idle pose.
// It writes frames/<clip>-NN.png, adds the clips to the pack's manifest with checksums, and reports
// every frame that leaves the skin's layout union (today's lane and hover). It never draws art.
//
//   swift run -c release FrameBake <pack>/frames-source.json [--clip <name>] [--preview <png>]

struct Source: Decodable {
    struct Anchor: Decodable {
        /// The face's colour (sRGB 0–255) and how far a pixel may be from it (Euclidean).
        var color: [Double]
        var tolerance: Double
    }
    struct Clip: Decodable {
        var name: String
        /// Pack-relative sheet paths, read in order (a long clip may use two sheets).
        var sheets: [String]
        /// Characters per sheet (16 for a 4 × 4 sheet).
        var cells: Int?
        /// One duration for every frame, or one per frame.
        var durationMs: [Int]
        /// Replace the first frame with the reference itself (the clip starts on the exact idle pose).
        var firstIsReference: Bool?
        /// Replace the last frame with the reference too (the clip hands back to idle).
        var lastIsReference: Bool?
        var accessories: AccessoryVisibility?
        /// Keep the face's vertical position instead of grounding the feet (a clip that hops).
        var keepHeight: Bool?
        /// A held state (drag, doze) or a held incident idle instead of a one-shot clip.
        var loop: Bool?
        /// Drop these frame numbers (0-based, before any reference replacement): duplicates or misfires.
        var skip: [Int]?
        /// Fit the whole clip inside the union: shift it sideways within the slack, then (if that is not
        /// enough) scale it uniformly about the ground anchor. Off by default: violations are reported.
        var fit: Bool?
        /// "face": size the clip by the face instead of the first frame's height, for clips that start
        /// wearing something that adds height (the helmet), so the pet underneath keeps its size.
        var registerBy: String?
        /// Frames (0-based, after skips) that spray: their `nozzle` point is the metal pixel furthest
        /// down-left (the nozzle tip aimed at the ground), for the engine's mist.
        var nozzleFrames: [Int]?
    }
    var id: String
    var reference: String
    var anchor: Anchor
    /// Merge consecutive frames that differ in fewer than this fraction of their visible pixels into
    /// one longer frame (end holds), default 0.004; 0 keeps every frame.
    var dedupe: Double?
    /// Write frames as 256-colour palette PNGs with alpha (much smaller), default false.
    var quantize: Bool?
    /// [minX, top, maxX] of the skin's design union (validate_pack.py's); the stricter of it and the
    /// measured union applies.
    var union: [Int]?
    /// Keep the pack's accessory overlays (the v1 hat). False for sequence packs: the helmet is drawn
    /// into their incident frames, and an overlay on top of them looks wrong.
    var accessories: Bool?
    var clips: [Clip]
}

struct Failure: Error, CustomStringConvertible { var description: String }
typealias Pixels = PixelRaster.Pixels

func load(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw Failure(description: "cannot read \(url.path)") }
    return image
}

func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw Failure(description: "png") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure(description: "png") }
    return data as Data
}

func image(_ pixels: Pixels) -> CGImage {
    let context = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: pixels.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    pixels.bytes.withUnsafeBytes { context.data!.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    return context.makeImage()!
}

/// 8-connected components of pixels passing `test`: label per pixel and (count, box) per label.
func components(_ p: Pixels, _ test: (Int) -> Bool) -> (labels: [Int], parts: [(count: Int, box: (Int, Int, Int, Int))]) {
    var labels = [Int](repeating: 0, count: p.width * p.height)
    var parts: [(Int, (Int, Int, Int, Int))] = [(0, (0, 0, 0, 0))]
    for start in 0..<(p.width * p.height) where labels[start] == 0 && test(start) {
        let number = parts.count
        var stack = [start], count = 0, box = (p.width, p.height, -1, -1)
        labels[start] = number
        while let i = stack.popLast() {
            count += 1
            let x = i % p.width, y = i / p.width
            box = (min(box.0, x), min(box.1, y), max(box.2, x), max(box.3, y))
            for dy in -1...1 { for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < p.width, ny < p.height else { continue }
                let j = ny * p.width + nx
                if labels[j] == 0, test(j) { labels[j] = number; stack.append(j) }
            } }
        }
        parts.append((count, box))
    }
    return (labels, parts.map { (count: $0.0, box: $0.1) })
}

/// The characters on a sheet in reading order, each with the small pieces (props) nearest to it.
func cells(_ sheet: Pixels, count: Int) -> [Pixels] {
    let (labels, parts) = components(sheet) { sheet.bytes[$0 * 4 + 3] > 24 }
    let order = parts.indices.dropFirst().sorted { parts[$0].count > parts[$1].count }
    let main = Array(order.prefix(count))
    let pieces = order.dropFirst(count).filter { parts[$0].count >= 120 }
    func center(_ i: Int) -> (Double, Double) {
        let b = parts[i].box
        return (Double(b.0 + b.2) / 2, Double(b.1 + b.3) / 2)
    }
    var owner: [Int: Int] = [:]
    for i in main { owner[i] = i }
    for i in pieces {
        let c = center(i)
        owner[i] = main.min { a, b in
            let ca = center(a), cb = center(b)
            return hypot(ca.0 - c.0, ca.1 - c.1) < hypot(cb.0 - c.0, cb.1 - c.1)
        }
    }
    // Reading order: rows by centre y (a row is within half a character's height), then x.
    let height = main.map { Double(parts[$0].box.3 - parts[$0].box.1) }.max() ?? 1
    let sorted = main.sorted { a, b in
        let ca = center(a), cb = center(b)
        return abs(ca.1 - cb.1) > height / 2 ? ca.1 < cb.1 : ca.0 < cb.0
    }
    return sorted.map { character in
        let members = owner.filter { $0.value == character }.map(\.key)
        let box = members.map { parts[$0].box }.reduce((Int.max, Int.max, Int.min, Int.min)) {
            (min($0.0, $1.0), min($0.1, $1.1), max($0.2, $1.2), max($0.3, $1.3))
        }
        let width = box.2 - box.0 + 1, height = box.3 - box.1 + 1
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let keep = Set(members)
        for y in 0..<height { for x in 0..<width {
            let i = (box.1 + y) * sheet.width + box.0 + x
            guard keep.contains(labels[i]) else { continue }
            for c in 0..<4 { bytes[(y * width + x) * 4 + c] = sheet.bytes[i * 4 + c] }
        } }
        return Pixels(width: width, height: height, bytes: bytes)
    }
}

/// The face: the largest region near the anchor colour. Returns its centre and width in pixels.
func face(_ p: Pixels, _ anchor: Source.Anchor) -> (x: Double, y: Double, width: Double)? {
    let (_, parts) = components(p) { i in
        let a = Double(p.bytes[i * 4 + 3])
        guard a > 200 else { return false }
        let r = Double(p.bytes[i * 4]) * 255 / a, g = Double(p.bytes[i * 4 + 1]) * 255 / a, b = Double(p.bytes[i * 4 + 2]) * 255 / a
        let d = ((r - anchor.color[0]) * (r - anchor.color[0]) + (g - anchor.color[1]) * (g - anchor.color[1])
                 + (b - anchor.color[2]) * (b - anchor.color[2])).squareRoot()
        return d <= anchor.tolerance
    }
    guard let biggest = parts.dropFirst().max(by: { $0.count < $1.count }), biggest.count > 50 else { return nil }
    let b = biggest.box
    return (Double(b.0 + b.2 + 1) / 2, Double(b.1 + b.3 + 1) / 2, Double(b.2 - b.0 + 1))
}

/// Lowest row with any coverage (the ground rule `validate_pack.py` checks).
func bottom(_ p: Pixels) -> Int {
    for y in stride(from: p.height - 1, through: 0, by: -1) {
        for x in 0..<p.width where p.bytes[(y * p.width + x) * 4 + 3] > 0 { return y }
    }
    return p.height - 1
}

/// The cell scaled by `scale` and placed so `point` (cell pixels) lands on `target` (canvas pixels),
/// then cleaned: alpha ≤ 12 cleared and specks under 40 px dropped.
func register(_ cell: Pixels, scale: Double, point: (Double, Double), target: (Double, Double)) throws -> Pixels {
    let side = MascotPack.canvasSize
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure(description: "context") }
    context.interpolationQuality = .high
    let w = Double(cell.width) * scale, h = Double(cell.height) * scale
    let x = target.0 - point.0 * scale, yTop = target.1 - point.1 * scale
    context.draw(image(cell), in: CGRect(x: x, y: Double(side) - yTop - h, width: w, height: h))
    guard var out = PixelRaster.pixels(of: context.makeImage()!) else { throw Failure(description: "pixels") }
    for i in 0..<(side * side) where out.bytes[i * 4 + 3] <= 12 { for c in 0..<4 { out.bytes[i * 4 + c] = 0 } }
    let (labels, parts) = components(out) { out.bytes[$0 * 4 + 3] > 0 }
    for i in 0..<(side * side) where labels[i] > 0 && parts[labels[i]].count < 40 { for c in 0..<4 { out.bytes[i * 4 + c] = 0 } }
    return out
}

/// The clip moved into the union: the smallest sideways shift, then a uniform scale about the ground
/// anchor if the shift alone can't do it. Nil when it already fits.
func fit(_ frames: [Pixels], union: [Int], reference: Pixels) throws -> (frames: [Pixels], shift: Int, scale: Double)? {
    let boxes = frames.compactMap(box)
    guard let minX = boxes.map(\.0).min(), let maxX = boxes.map(\.2).max(), let top = boxes.map(\.1).min() else { return nil }
    if minX >= union[0], maxX <= union[2], top >= union[1] { return nil }
    var shift = 0
    if minX < union[0] { shift = min(union[0] - minX, union[2] - maxX) } else if maxX > union[2] { shift = max(union[2] - maxX, union[0] - minX) }
    let left = minX + shift, right = maxX + shift
    let anchor = (x: 128.0, y: 232.0)
    var scale = 1.0
    if left < union[0] { scale = min(scale, (anchor.x - Double(union[0])) / (anchor.x - Double(left))) }
    if right > union[2] { scale = min(scale, (Double(union[2]) - anchor.x) / (Double(right) - anchor.x)) }
    if top < union[1] { scale = min(scale, (anchor.y - Double(union[1])) / (anchor.y - Double(top))) }
    let ground = bottom(reference)
    let moved = try frames.map { frame -> Pixels in
        // Translate by `shift`, then scale about the anchor: the frame's own pixels resampled once.
        var out = try register(frame, scale: scale, point: (anchor.x - Double(shift), anchor.y), target: anchor)
        // Resampling can smear a faint row below the ground or lift the feet a row: clear below the
        // ground, then move the frame by whole rows so its lowest pixel is on idle-00's ground row.
        for y in (ground + 1)..<out.height { for x in 0..<out.width { for c in 0..<4 { out.bytes[(y * out.width + x) * 4 + c] = 0 } } }
        return shifted(out, rows: ground - bottom(out))
    }
    return (moved, shift, scale)
}

/// The nozzle tip: among opaque grey-metal pixels (r ≈ g ≈ b, mid grey), the one furthest down-left.
func nozzle(_ p: Pixels) -> (Int, Int)? {
    var best: (Int, Int)?, score = Int.min
    for y in 0..<p.height { for x in 0..<p.width {
        let i = (y * p.width + x) * 4
        guard p.bytes[i + 3] > 220 else { continue }
        let r = Int(p.bytes[i]), g = Int(p.bytes[i + 1]), b = Int(p.bytes[i + 2])
        guard max(r, g, b) - min(r, g, b) < 18, (110...215).contains((r + g + b) / 3) else { continue }
        if y - x > score { score = y - x; best = (x, y) }
    } }
    return best
}

/// Fraction of visible pixels that differ by more than 10 in any channel.
func difference(_ a: Pixels, _ b: Pixels) -> Double {
    var changed = 0, visible = 0
    for i in stride(from: 0, to: a.bytes.count, by: 4) {
        guard a.bytes[i + 3] > 0 || b.bytes[i + 3] > 0 else { continue }
        visible += 1
        for c in 0..<4 where abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c])) > 10 { changed += 1; break }
    }
    return visible == 0 ? 0 : Double(changed) / Double(visible)
}

/// A 256-colour palette PNG with per-entry alpha (colour type 3 with tRNS): median cut over the frame's
/// unpremultiplied RGBA colours, each pixel mapped to its nearest entry, no dithering. Fully transparent
/// pixels share entry 0.
func palettePNG(_ p: Pixels) throws -> Data {
    struct Color: Hashable { var r, g, b, a: UInt8 }
    var counts: [Color: Int] = [:]
    var colors = [Color](repeating: Color(r: 0, g: 0, b: 0, a: 0), count: p.width * p.height)
    for i in 0..<(p.width * p.height) {
        let a = p.bytes[i * 4 + 3]
        guard a > 0 else { continue }
        func un(_ v: UInt8) -> UInt8 { UInt8(min(255, (Int(v) * 255 + Int(a) / 2) / Int(a))) }
        let c = Color(r: un(p.bytes[i * 4]), g: un(p.bytes[i * 4 + 1]), b: un(p.bytes[i * 4 + 2]), a: a)
        colors[i] = c
        counts[c, default: 0] += 1
    }
    // Median cut into 255 boxes (entry 0 is transparent).
    // Deterministic: colours in a total order (a dictionary's order differs per run), and every sort
    // breaks ties by the whole colour, so a rebake writes the same bytes.
    func key(_ c: Color) -> UInt32 { UInt32(c.r) << 24 | UInt32(c.g) << 16 | UInt32(c.b) << 8 | UInt32(c.a) }
    var boxes: [[(Color, Int)]] = [counts.sorted { key($0.key) < key($1.key) }.map { ($0.key, $0.value) }]
    func channel(_ c: Color, _ k: Int) -> Int { k == 0 ? Int(c.r) : k == 1 ? Int(c.g) : k == 2 ? Int(c.b) : Int(c.a) }
    while boxes.count < 255 {
        var best = -1, bestRange = 0, bestChannel = 0
        for (index, box) in boxes.enumerated() where box.count > 1 {
            for k in 0..<4 {
                let values = box.map { channel($0.0, k) }
                let range = (values.max() ?? 0) - (values.min() ?? 0)
                if range > bestRange { bestRange = range; best = index; bestChannel = k }
            }
        }
        guard best >= 0 else { break }
        let sorted = boxes[best].sorted {
            (channel($0.0, bestChannel), key($0.0)) < (channel($1.0, bestChannel), key($1.0))
        }
        let total = sorted.reduce(0) { $0 + $1.1 }
        var running = 0, cut = 1
        for (i, item) in sorted.enumerated() { running += item.1; if running * 2 >= total { cut = max(1, min(sorted.count - 1, i + 1)); break } }
        boxes[best] = Array(sorted[..<cut])
        boxes.append(Array(sorted[cut...]))
    }
    var palette = [Color(r: 0, g: 0, b: 0, a: 0)]
    for box in boxes {
        let total = Double(box.reduce(0) { $0 + $1.1 })
        func mean(_ k: Int) -> UInt8 { UInt8((box.reduce(0.0) { $0 + Double(channel($1.0, k) * $1.1) } / total).rounded()) }
        palette.append(Color(r: mean(0), g: mean(1), b: mean(2), a: mean(3)))
    }
    var nearest: [Color: UInt8] = [:]
    func index(_ c: Color) -> UInt8 {
        if c.a == 0 { return 0 }
        if let known = nearest[c] { return known }
        var best = 1, bestDistance = Int.max
        for (i, e) in palette.enumerated().dropFirst() {
            let d = (Int(c.r) - Int(e.r)) * (Int(c.r) - Int(e.r)) + (Int(c.g) - Int(e.g)) * (Int(c.g) - Int(e.g))
                + (Int(c.b) - Int(e.b)) * (Int(c.b) - Int(e.b)) + 2 * (Int(c.a) - Int(e.a)) * (Int(c.a) - Int(e.a))
            if d < bestDistance { bestDistance = d; best = i }
        }
        nearest[c] = UInt8(best)
        return UInt8(best)
    }
    var raw = Data(capacity: (p.width + 1) * p.height)
    for y in 0..<p.height {
        raw.append(0)
        for x in 0..<p.width { raw.append(index(colors[y * p.width + x])) }
    }
    func chunk(_ type: String, _ body: Data) -> Data {
        var out = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { out.append(contentsOf: $0) }
        let typed = Data(type.utf8) + body
        out.append(typed)
        withUnsafeBytes(of: crc32(typed).bigEndian) { out.append(contentsOf: $0) }
        return out
    }
    var header = Data()
    withUnsafeBytes(of: UInt32(p.width).bigEndian) { header.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(p.height).bigEndian) { header.append(contentsOf: $0) }
    header.append(contentsOf: [8, 3, 0, 0, 0])
    let plte = Data(palette.flatMap { [$0.r, $0.g, $0.b] }), trns = Data(palette.map(\.a))
    guard let deflated = try? (raw as NSData).compressed(using: .zlib) as Data else { throw Failure(description: "deflate") }
    var zlib = Data([0x78, 0xDA])
    zlib.append(deflated)
    withUnsafeBytes(of: adler32(raw).bigEndian) { zlib.append(contentsOf: $0) }
    return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + chunk("IHDR", header) + chunk("PLTE", plte)
        + chunk("tRNS", trns) + chunk("IDAT", zlib) + chunk("IEND", Data())
}

func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return crc ^ 0xFFFF_FFFF
}

func adler32(_ data: Data) -> UInt32 {
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    return b << 16 | a
}

/// First row with any coverage in each column (the art's top contour).
func columnTops(_ p: Pixels) -> [Int?] {
    (0..<p.width).map { x in (0..<p.height).first { p.bytes[($0 * p.width + x) * 4 + 3] > 0 } }
}

func merge(_ a: [Int?], _ b: [Int?]) -> [Int?] {
    zip(a, b).map { x, y in x.flatMap { x in y.map { min(x, $0) } ?? x } ?? y }
}

/// The count's lane height and slot at the sizes the app offers (Settings steps 64 to 256 by 16), as
/// the app computes them (the slot from the states' heads only).
var headContours: [[Int?]] = []
func layouts(_ contours: [[Int?]]) -> [[Double]] {
    stride(from: 64.0, through: 256, by: 16).map { side in
        let layout = MascotLayout(artSide: side, contours: contours, headContours: headContours)
        return [Double(layout.laneHeight), Double(layout.countSlotX)]
    }
}

/// The frame moved down by `rows` whole rows (up when negative), without resampling.
func shifted(_ p: Pixels, rows: Int) -> Pixels {
    guard rows != 0 else { return p }
    var out = Pixels(width: p.width, height: p.height, bytes: [UInt8](repeating: 0, count: p.bytes.count))
    for y in 0..<p.height {
        let target = y + rows
        guard target >= 0, target < p.height else { continue }
        for i in 0..<(p.width * 4) { out.bytes[target * p.width * 4 + i] = p.bytes[y * p.width * 4 + i] }
    }
    return out
}

func box(_ p: Pixels) -> (Int, Int, Int, Int)? {
    var b = (Int.max, Int.max, Int.min, Int.min)
    for y in 0..<p.height { for x in 0..<p.width where p.bytes[(y * p.width + x) * 4 + 3] > 0 {
        b = (min(b.0, x), min(b.1, y), max(b.2, x), max(b.3, y))
    } }
    return b.2 >= 0 ? b : nil
}

func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let sourcePath = arguments.first else { throw Failure(description: "usage: FrameBake <pack>/frames-source.json [--clip <name>] [--preview <png>]") }
    arguments.removeFirst()
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let pack = sourceURL.deletingLastPathComponent()
    let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: sourceURL))
    let only = arguments.firstIndex(of: "--clip").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    let referenceImage = try load(pack.appendingPathComponent(source.reference))
    guard let reference = PixelRaster.pixels(of: referenceImage), let refFace = face(reference, source.anchor) else {
        throw Failure(description: "no face found in \(source.reference): check the anchor colour")
    }
    let ground = Double(bottom(reference))
    print("FrameBake: reference face at (\(Int(refFace.x)), \(Int(refFace.y))) width \(Int(refFace.width)), ground row \(Int(ground))")
    let manifestURL = pack.appendingPathComponent("manifest.json")
    var manifest = try JSONDecoder().decode(MascotPackManifest.self, from: Data(contentsOf: manifestURL))
    // Today's union, exactly as the loader measures it: any coverage of the idle, attention and urgent art.
    var unionBox = (Int.max, Int.max, Int.min, Int.min)
    for state in MascotState.allCases {
        guard let spec = manifest.states[state.rawValue] else { continue }
        for path in Set(spec.frames + [spec.staticFallback]) {
            guard let pixels = PixelRaster.pixels(of: try load(pack.appendingPathComponent(path))), let b = box(pixels) else { continue }
            unionBox = (min(unionBox.0, b.0), min(unionBox.1, b.1), max(unionBox.2, b.2), max(unionBox.3, b.3))
        }
    }
    // The layout today: the count's lane and slot from the states' contours (with the hat where worn).
    var stateContours: [[Int?]] = []
    let hatPixels = source.accessories == false ? nil : (manifest.accessories ?? [:]).values.first.flatMap { try? load(pack.appendingPathComponent($0.image)) }.flatMap(PixelRaster.pixels(of:))
    for state in MascotState.allCases {
        guard let spec = manifest.states[state.rawValue] else { continue }
        for path in Set(spec.frames + [spec.staticFallback]) {
            guard let pixels = PixelRaster.pixels(of: try load(pack.appendingPathComponent(path))) else { continue }
            stateContours.append(columnTops(pixels))
            if let hatPixels { stateContours.append(merge(columnTops(pixels), columnTops(hatPixels))) }
        }
    }
    headContours = stateContours
    let baseLayouts = layouts(stateContours)

    var union = [unionBox.0, unionBox.1, unionBox.2]
    if let design = source.union, design.count == 3 {
        union = [max(union[0], design[0]), max(union[1], design[1]), min(union[2], design[2])]
    }
    print("FrameBake: today's union x \(union[0])–\(union[2]), top \(union[1]) (any coverage of idle, attention, urgent)")
    var checksums = manifest.frameSha256 ?? [:]
    var clips = manifest.clips ?? [:]
    var previews: [(String, [CGImage])] = []
    var problems = 0
    for clip in source.clips where only == nil || clip.name == only {
        var cellImages: [Pixels] = []
        for sheet in clip.sheets {
            guard let pixels = PixelRaster.pixels(of: try load(pack.appendingPathComponent(sheet))) else { continue }
            cellImages += cells(pixels, count: clip.cells ?? 16)
        }
        let skip = Set(clip.skip ?? [])
        cellImages = cellImages.enumerated().filter { !skip.contains($0.offset) }.map(\.element)
        // The clip's size: its first frame (drawn as the idle pose) is as tall as idle-00. Within the clip
        // the face keeps every frame at that frame's size (removing the generator's drift), smoothed over
        // neighbours so an expression can't make it jump.
        let faces = cellImages.map { face($0, source.anchor) }
        let referenceHeight = Double(box(reference).map { $0.3 - $0.1 + 1 } ?? 1)
        let firstHeight = Double(cellImages.first.flatMap(box).map { $0.3 - $0.1 + 1 } ?? 1)
        let firstFaceWidth = faces.compactMap { $0 }.first?.width
        let clipScale = clip.registerBy == "face" ? refFace.width / (firstFaceWidth ?? refFace.width) : referenceHeight / firstHeight
        let firstFace = faces.compactMap { $0 }.first?.width ?? refFace.width
        let raw = faces.map { $0.map { clipScale * firstFace / $0.width } }
        // A prop over the face (a helmet over the forehead) shrinks the face region and would blow that
        // frame up: keep every frame within 6% of the clip's median scale.
        let known = raw.compactMap { $0 }.sorted()
        let median = known.isEmpty ? clipScale : known[known.count / 2]
        let scales = raw.indices.map { i -> Double in
            let window = raw[max(0, i - 1)...min(raw.count - 1, i + 1)].compactMap { $0 }
            let local = window.isEmpty ? median : window.sorted()[window.count / 2]
            return min(max(local, median * 0.94), median * 1.06)
        }
        var frames: [Pixels] = []
        for (i, cell) in cellImages.enumerated() {
            let scale = scales[i]
            guard let f = faces[i] else {
                print("  \(clip.name) frame \(i): no face found, skipped"); problems += 1; continue
            }
            var registered = try register(cell, scale: scale, point: (f.x, f.y), target: (refFace.x, refFace.y))
            if clip.keepHeight != true {
                // Ground: move the lowest visible row onto the reference's.
                let shift = Int(ground) - bottom(registered)
                if shift != 0 {
                    registered = try register(cell, scale: scale, point: (f.x, f.y), target: (refFace.x, refFace.y + Double(shift)))
                }
            }
            frames.append(registered)
        }
        if clip.fit == true {
            // Grounding after a scale can lift a frame back over the top: fit again until it holds.
            var shift = 0, scale = 1.0
            for _ in 0..<4 {
                guard let fitted = try fit(frames, union: union, reference: reference) else { break }
                frames = fitted.frames
                shift += fitted.shift
                scale *= fitted.scale
            }
            if scale < 1 || shift != 0 {
                print("  \(clip.name): fitted by shifting \(shift) px and scaling \(String(format: "%.3f", scale))")
            }
        }
        if clip.firstIsReference == true, !frames.isEmpty { frames[0] = reference }
        if clip.lastIsReference == true, !frames.isEmpty { frames[frames.count - 1] = reference }
        guard !frames.isEmpty else { continue }
        // The count's lane and slot must not move: art higher than any state under the count or DEMO
        // grows the lane even inside the union box. With `fit`, shrink about the anchor until it doesn't.
        func clipContours(_ frames: [Pixels]) -> [[Int?]] {
            frames.flatMap { frame -> [[Int?]] in
                let tops = columnTops(frame)
                return clip.accessories != .hide && hatPixels != nil ? [tops, merge(tops, columnTops(hatPixels!))] : [tops]
            }
        }
        func lanes(_ l: [[Double]]) -> [Double] { l.map { $0[0] } }
        if lanes(layouts(stateContours + clipContours(frames))) != lanes(baseLayouts) {
            if clip.fit == true {
                var low = 0.5, high = 1.0, best: [Pixels]? = nil
                for _ in 0..<10 {
                    let mid = (low + high) / 2
                    let candidate = try frames.map { frame -> Pixels in
                        let isRef = frame.bytes == reference.bytes
                        if isRef { return frame }
                        var out = try register(frame, scale: mid, point: (128, 232), target: (128, 232))
                        out = shifted(out, rows: bottom(reference) - bottom(out))
                        return out
                    }
                    if lanes(layouts(stateContours + clipContours(candidate))) == lanes(baseLayouts) { low = mid; best = candidate } else { high = mid }
                }
                if let best {
                    frames = best
                    print("  \(clip.name): scaled \(String(format: "%.3f", low)) more to keep the count's lane and slot")
                } else {
                    print("  LAYOUT \(clip.name): cannot keep the lane even at half size"); problems += 1
                }
            } else {
                let grown = layouts(stateContours + clipContours(frames))
                print("  LAYOUT \(clip.name): lane \(lanes(baseLayouts)) -> \(lanes(grown))"); problems += 1
            }
        }
        // The count's slot follows the leftmost head edge over all poses: report how far this clip moves it.
        let slots = zip(baseLayouts, layouts(stateContours + clipContours(frames))).map { $1[1] - $0[1] }
        if let worst = slots.min(), worst < 0 {
            print("  SLOT \(clip.name): the count's slot moves left up to \(Int(-worst)) pt (64–256 pt sizes)")
        }
        var durations = clip.durationMs.count == frames.count ? clip.durationMs : Array(repeating: clip.durationMs.first ?? 70, count: frames.count)
        let isReference = frames.map { $0.bytes == reference.bytes }
        // End holds: a frame that barely differs from the one before extends it instead.
        var kept: [(frame: Pixels, duration: Int, reference: Bool, source: Int)] = []
        for (i, frame) in frames.enumerated() {
            if let last = kept.last, difference(last.frame, frame) < (source.dedupe ?? 0.004),
               last.duration + durations[i] <= MascotPack.clipDurationRange.upperBound {
                kept[kept.count - 1].duration += durations[i]
            } else {
                kept.append((frame, durations[i], isReference[i], i))
            }
        }
        if kept.count < frames.count { print("  \(clip.name): \(frames.count - kept.count) held frame(s) merged into longer frames") }
        durations = kept.map(\.duration)
        // Write (idle-00 itself is referenced, not copied), check against the union.
        var paths: [String] = []
        var sources: [Int] = []
        for (i, item) in kept.enumerated() {
            let frame = item.frame
            sources.append(item.source)
            if item.reference { paths.append(source.reference); continue }
            let path = "frames/\(clip.name)-\(String(format: "%02d", i)).png"
            let data = source.quantize == true ? try palettePNG(frame) : try png(image(frame))
            try data.write(to: pack.appendingPathComponent(path))
            checksums[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            paths.append(path)
            if let b = box(frame), b.0 < union[0] || b.2 > union[2] || b.1 < union[1] {
                print("  OUTSIDE \(clip.name)-\(String(format: "%02d", i)): x \(b.0)–\(b.2), top \(b.1) (union x \(union[0])–\(union[2]), top \(union[1]))")
                problems += 1
            }
        }
        // Frames an earlier bake of this clip wrote that this one doesn't use (fewer frames after
        // dedupe, or a first frame that is now idle-00): exactly `<clip>-NN.png`, never another clip's.
        let framesDirectory = pack.appendingPathComponent("frames")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: framesDirectory.path)) ?? [] {
            let suffix = name.dropFirst(clip.name.count + 1)
            guard name.hasPrefix(clip.name + "-"), suffix.count == 6, suffix.hasSuffix(".png"),
                  suffix.prefix(2).allSatisfy(\.isNumber), !paths.contains("frames/" + name) else { continue }
            try FileManager.default.removeItem(at: framesDirectory.appendingPathComponent(name))
        }
        var framePoints = manifest.framePoints ?? [:]
        for path in paths { framePoints[path] = nil }
        for i in clip.nozzleFrames ?? [] {
            guard let k = sources.firstIndex(of: i) ?? sources.lastIndex(where: { $0 < i }) else { continue }
            if let tip = nozzle(kept[k].frame) {
                framePoints[paths[k]] = .init(nozzle: [tip.0, tip.1])
            } else {
                print("  \(clip.name) frame \(i): no nozzle found"); problems += 1
            }
        }
        manifest.framePoints = framePoints.isEmpty ? nil : framePoints
        if clip.loop == true {
            manifest.states[clip.name] = .init(frames: paths, durationMs: durations, loop: true, staticFallback: paths[0])
        } else {
            clips[clip.name] = .init(frames: paths, durationMs: durations, accessories: clip.accessories)
        }
        let scaleList = scales.map { String(format: "%.2f", $0) }.joined(separator: " ")
        print("FrameBake: \(clip.name): \(paths.count) frames, \(durations.reduce(0, +)) ms; scales \(scaleList)")
        previews.append((clip.name, kept.map { image($0.frame) }))
    }
    manifest.schemaVersion = max(manifest.schemaVersion, 2)
    if source.accessories == false {
        manifest.accessories = nil
        manifest.points?.head = nil
    }
    manifest.clips = clips
    // Only the images the manifest uses keep a checksum (earlier bakes' frames drop out).
    let used = Set(manifest.imagePaths)
    manifest.frameSha256 = checksums.filter { used.contains($0.key) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: manifestURL)
    switch MascotPack.load(from: pack, expectedID: source.id, budget: .bundled) {
    case .success: print("FrameBake: \(source.id) loads under the bundled budget")
    case .failure(let failure): print("FrameBake: FAILS to load as bundled: " + failure.errors.map(\.description).joined(separator: "; "))
    }
    if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count {
        try preview(previews, reference: referenceImage, to: URL(fileURLWithPath: arguments[index + 1]), union: union)
    }
    if problems > 0 { print("FrameBake: \(problems) problem(s) above") }
}

/// One row per clip at 128 px per frame, the reference first, union lines drawn.
func preview(_ rows: [(String, [CGImage])], reference: CGImage, to url: URL, union: [Int]) throws {
    let cell = 128, label = 16, columns = (rows.map(\.1.count).max() ?? 0) + 1
    let height = rows.count * (cell + label)
    guard height > 0, let context = CGContext(data: nil, width: columns * cell, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    context.setFillColor(CGColor(gray: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: columns * cell, height: height))
    context.interpolationQuality = .high
    for (r, row) in rows.enumerated() {
        let y = height - (r + 1) * (cell + label)
        for (c, image) in ([reference] + row.1).enumerated() {
            context.draw(image, in: CGRect(x: c * cell, y: y, width: cell, height: cell))
            context.setStrokeColor(CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 0.5))
            let s = Double(cell) / 256
            for x in [union[0], union[2]] { context.move(to: CGPoint(x: Double(c * cell) + Double(x) * s, y: Double(y))); context.addLine(to: CGPoint(x: Double(c * cell) + Double(x) * s, y: Double(y + cell))) }
            for yy in [Double(union[1]), 232] { context.move(to: CGPoint(x: Double(c * cell), y: Double(y) + Double(cell) - yy * s)); context.addLine(to: CGPoint(x: Double(c * cell + cell), y: Double(y) + Double(cell) - yy * s)) }
            context.strokePath()
        }
    }
    try png(context.makeImage()!).write(to: url)
    print("FrameBake: preview -> \(url.path)")
}

do { try run() } catch {
    FileHandle.standardError.write(Data("FrameBake: \(error)\n".utf8))
    exit(1)
}
