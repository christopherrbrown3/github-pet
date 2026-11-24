// Review-only previews of the #138 v2 packs (never bundled).
// swift docs/design/review_v2.swift <output-dir>
// Per skin and per clip or held state: a contact sheet (light row, dark row, and a hat row where the
// hat can show) with the bounds-rule guides and the manifest points; plus every packed frame with the hat.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/design/review-v2")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let unions: [String: (left: Int, right: Int, top: Int)] = ["mona-pet-v1": (47, 217, 20), "little-chris-v1": (62, 205, 20)]
let light = CGColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1), dark = CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
let cell = 256, labelHeight = 22

func image(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("unreadable \(url.path)")
    }
    return image
}

func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func label(_ text: String, in ctx: CGContext, x: Int, y: Int, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    (text as NSString).draw(at: NSPoint(x: x + 4, y: y + 4),
                            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color])
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws one frame into a 256 cell whose top-left is (x, top) in y-down canvas terms.
func draw(_ frame: CGImage, hat: (CGImage, CGPoint)?, in ctx: CGContext, x: Int, top: Int, height: Int, background: CGColor) {
    let y = height - top - cell
    ctx.setFillColor(background); ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
    ctx.draw(frame, in: CGRect(x: x, y: y, width: cell, height: cell))
    if let (hat, offset) = hat { ctx.draw(hat, in: CGRect(x: x + Int(offset.x), y: y - Int(offset.y), width: cell, height: cell)) }
}

func guides(_ union: (left: Int, right: Int, top: Int), points: [String: [Int]], in ctx: CGContext, x: Int, top: Int, height: Int) {
    let y0 = height - top
    ctx.setLineWidth(1)
    ctx.setStrokeColor(CGColor(red: 0.1, green: 0.6, blue: 1, alpha: 0.7))
    for gx in [union.left, union.right + 1] { ctx.stroke(CGRect(x: x + gx, y: y0 - cell, width: 0, height: cell)) }
    ctx.stroke(CGRect(x: x, y: y0 - union.top, width: cell, height: 0))
    ctx.setStrokeColor(CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 0.7))
    ctx.stroke(CGRect(x: x, y: y0 - 232, width: cell, height: 0))
    let colors: [String: CGColor] = ["head": CGColor(red: 1, green: 0, blue: 1, alpha: 1), "nozzle": CGColor(red: 0, green: 0.9, blue: 0.9, alpha: 1),
                                     "hand": CGColor(red: 1, green: 0.8, blue: 0, alpha: 1)]
    for (name, point) in points {
        ctx.setStrokeColor(colors[name] ?? CGColor(gray: 0.5, alpha: 1)); ctx.setLineWidth(2)
        let px = CGFloat(x + point[0]), py = CGFloat(y0 - point[1])
        ctx.strokeLineSegments(between: [CGPoint(x: px - 5, y: py), CGPoint(x: px + 5, y: py), CGPoint(x: px, y: py - 5), CGPoint(x: px, y: py + 5)])
    }
}

func write(_ image: CGImage, _ url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
}

for pack in ["mona-pet-v1", "little-chris-v1"] {
    let directory = root.appendingPathComponent("assets/mascots/\(pack)")
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as! [String: Any]
    let states = manifest["states"] as! [String: [String: Any]], clips = manifest["clips"] as? [String: [String: Any]] ?? [:]
    let framePoints = manifest["framePoints"] as? [String: [String: [Int]]] ?? [:]
    let base = (manifest["points"] as? [String: [Int]])?["head"] ?? [128, 30]
    let hat = (manifest["accessories"] as? [String: [String: String]])?["firefighter-hat"].map { image(directory.appendingPathComponent($0["image"]!)) }
    var sequences: [(String, [String], [Int], Bool)] = []
    for name in ["drag", "doze"] { if let spec = states[name] { sequences.append((name, spec["frames"] as! [String], spec["durationMs"] as! [Int], true)) } }
    for (name, spec) in clips.sorted(by: { $0.key < $1.key }) {
        sequences.append((name, spec["frames"] as! [String], spec["durationMs"] as! [Int], (spec["accessories"] as? String) != "hide"))
    }
    for (name, frames, durations, wearsHat) in sequences {
        let rows = wearsHat && hat != nil ? 3 : 2
        let width = cell * frames.count, rowHeight = cell + labelHeight, height = rowHeight * rows
        let ctx = context(width, height)
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, path) in frames.enumerated() {
            let frame = image(directory.appendingPathComponent(path))
            var points = framePoints[path] ?? [:]
            if points["head"] == nil { points["head"] = base }
            let head = points["head"]!
            let offset = CGPoint(x: head[0] - base[0], y: head[1] - base[1])
            for row in 0..<rows {
                let top = row * rowHeight + labelHeight, x = index * cell
                draw(frame, hat: row == 2 ? (hat!, offset) : nil, in: ctx, x: x, top: top, height: height, background: row == 1 ? dark : light)
                guides(unions[pack]!, points: points, in: ctx, x: x, top: top, height: height)
                let caption = "\((path as NSString).lastPathComponent) \(durations[index])ms" + (row == 2 ? " +hat" : row == 1 ? " dark" : "")
                label(caption, in: ctx, x: x, y: height - top, color: .white)
            }
        }
        write(ctx.makeImage()!, output.appendingPathComponent("\(pack)-\(name).png"))

    }
    // Every packed v2 frame (including ones a left-out clip would use), with the hat composited at its head point.
    let packing = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("packing.json"))) as! [String: Any]
    let records = (packing["v2"] as! [String: Any])["frames"] as! [String: [String: Any]]
    let packed = records.filter { $0.value["canvasOverflow"] == nil }.keys.sorted()
    let columns = 8, rowHeight = cell + labelHeight
    let width = columns * cell, height = ((packed.count + columns - 1) / columns) * rowHeight * 2
    let ctx = context(width, height)
    ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (index, name) in packed.enumerated() {
        let record = records[name]!, frame = image(directory.appendingPathComponent("frames/\(name).png"))
        var points: [String: [Int]] = ["head": record["head"] as? [Int] ?? base]
        for key in ["nozzle", "hand"] { if let point = record[key] as? [Int] { points[key] = point } }
        let offset = CGPoint(x: points["head"]![0] - base[0], y: points["head"]![1] - base[1])
        for row in 0..<2 {
            let top = ((index / columns) * 2 + row) * rowHeight + labelHeight, x = (index % columns) * cell
            draw(frame, hat: row == 1 ? (hat!, offset) : nil, in: ctx, x: x, top: top, height: height, background: light)
            guides(unions[pack]!, points: points, in: ctx, x: x, top: top, height: height)
            label(name + (row == 1 ? " +hat" : ""), in: ctx, x: x, y: height - top, color: .white)
        }
    }
    write(ctx.makeImage()!, output.appendingPathComponent("\(pack)-all-frames.png"))
    print("\(pack): \(sequences.count) contact sheets, \(packed.count) frames")
}
