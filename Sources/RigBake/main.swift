import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import GitHubPetCore
import ImageIO

// Designer tool (#138, docs/design/animation-v2-rig.md section 6.4): builds a schema v3 pack from a rig
// source file. It cuts each part from its generated sheet (the island inside a box, as rig_cut.py
// --check lists them), scales, rotates and flips it, pads every variant of a part to one shared centre,
// writes the part images at the rig's unit scale, bakes the states from the rig's still poses with the
// same evaluator the app uses, and writes the manifest with checksums. It never draws character art.
//
//   swift run RigBake <pack>/rig/source.json [--out <dir>] [--preview <png>]     (default out: <pack>/rig/pack)
//
// --preview writes a contact sheet for the designer: the rest pose next to the pack's idle-00 (when it
// has one), every bone at both ends of its range with pivots marked, and each clip at 12 instants.

struct Source: Decodable {
    struct Island: Decodable {
        /// A sheet name from `sheets`, or a pack-relative image (for a feature cut from an old frame).
        var sheet: String
        /// [x0, y0, x1, y1) in sheet pixels; the largest connected island inside it is kept.
        var box: [Int]
        /// Keep only pixels darker than this luminance (0–1): features lifted off an old frame's face.
        var darkerThan: Double?
        /// Instead of the largest island, keep everything in the box (several strokes, e.g. eyes and mouth).
        var all: Bool?
        /// Clear pixels below this alpha (0–255) before cutting: a generated glow or fringe around the
        /// contour, not the art.
        var alphaFloor: Int?
    }
    struct Placement: Decodable {
        var island: Island
        var scale: Double?
        var stretch: [Double]?
        var rot: Double?
        var flip: Bool?
        /// Place this variant where its silhouette best overlaps the part's own image (an expression
        /// painted as an edit of the same head), instead of at `center`.
        var alignToBase: Bool?
        /// Keep only a feathered ellipse [cx, cy, rx, ry] (canvas units, rest pose): the face region of
        /// a whole-head expression, so swapping it never changes the hair, ears or outline.
        var faceMask: [Double]?
        /// Where the image's centre sits in the rest pose, canvas units (before `restScale`).
        var center: [Double]?
    }
    struct Part: Decodable {
        var name: String
        var bone: String
        var island: Island
        var scale: Double
        /// Extra [x, y] scale in the piece's own axes before rotation (slimming a limb by resampling).
        var stretch: [Double]?
        var rot: Double?
        var flip: Bool?
        var center: [Double]
        var variants: [String: Placement]?
        var hidden: Bool?
        var mounts: [String: RigSpec.Mount]?
    }
    struct StateFrame: Decodable {
        var pose: String
        var face: String?
    }
    struct State: Decodable {
        var frames: [StateFrame]
        var durationMs: [Int]
        var loop: Bool
    }
    struct Accessory: Decodable {
        /// Bake this part alone, worn in the idle pose.
        var part: String?
        /// Or redraw an existing canvas-size image, scaled by `restScale` about the anchor.
        var image: String?
    }

    var id: String
    var name: String
    var unitScale: Double
    var restScale: Double?
    var reserve: [Int]?
    var sheets: [String: String]
    var parts: [Part]
    var bones: [String: RigSpec.Bone]
    var faces: [String: [String: String]]?
    var poses: [String: RigSpec.Pose]?
    var clips: [String: RigSpec.Clip]?
    var states: [String: State]
    var accessories: [String: Accessory]?
    var points: MascotPackManifest.Points?
}

struct Failure: Error, CustomStringConvertible { var description: String }

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

func context(_ width: Int, _ height: Int) throws -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure(description: "context \(width)x\(height)") }
    return context
}

/// The island inside `box`: its largest 8-connected group of alpha > 8 pixels (or all of them),
/// optionally only the dark pixels, cropped to its bounds.
func cut(_ sheet: CGImage, _ island: Source.Island) throws -> CGImage {
    guard island.box.count == 4 else { throw Failure(description: "box must be [x0, y0, x1, y1]") }
    let x0 = max(0, island.box[0]), y0 = max(0, island.box[1])
    let x1 = min(sheet.width, island.box[2]), y1 = min(sheet.height, island.box[3])
    let width = x1 - x0, height = y1 - y0
    guard width > 0, height > 0, let pixels = RigRaster.pixels(of: sheet) else { throw Failure(description: "empty box") }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let source = ((y0 + y) * pixels.width + x0 + x) * 4, target = (y * width + x) * 4
            for channel in 0..<4 { bytes[target + channel] = pixels.bytes[source + channel] }
            if let floor = island.alphaFloor, Int(bytes[target + 3]) < floor {
                for channel in 0..<4 { bytes[target + channel] = 0 }
            }
            if let limit = island.darkerThan {
                let a = Double(bytes[target + 3])
                let luminance = a > 0 ? (0.3 * Double(bytes[target]) + 0.59 * Double(bytes[target + 1]) + 0.11 * Double(bytes[target + 2])) / a : 1
                // Fade out the plate: fully kept below the limit, gone 0.15 above it.
                let keep = min(1, max(0, (limit + 0.15 - luminance) / 0.15))
                for channel in 0..<4 { bytes[target + channel] = UInt8(Double(bytes[target + channel]) * keep) }
            }
        }
    }
    var label = [Int](repeating: 0, count: width * height)
    var sizes: [Int] = [0]
    if island.all != true {
        for start in 0..<(width * height) where bytes[start * 4 + 3] > 8 && label[start] == 0 {
            let number = sizes.count
            var stack = [start], count = 0
            label[start] = number
            while let i = stack.popLast() {
                count += 1
                let x = i % width, y = i / width
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let j = ny * width + nx
                    if bytes[j * 4 + 3] > 8, label[j] == 0 { label[j] = number; stack.append(j) }
                } }
            }
            sizes.append(count)
        }
        let keep = sizes.indices.dropFirst().max { sizes[$0] < sizes[$1] } ?? 0
        // Keep the island and the faint edge pixels next to it; drop everything else.
        for i in 0..<(width * height) where label[i] != keep {
            let x = i % width, y = i / width
            var nearKeep = false
            if bytes[i * 4 + 3] <= 8 {
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, ny >= 0, nx < width, ny < height, label[ny * width + nx] == keep { nearKeep = true }
                } }
            }
            if !nearKeep { for channel in 0..<4 { bytes[i * 4 + channel] = 0 } }
        }
    }
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height { for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 0 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX >= minX else { throw Failure(description: "nothing in box \(island.box) of \(island.sheet)") }
    let cropped = try context(maxX - minX + 1, maxY - minY + 1)
    let full = try context(width, height)
    bytes.withUnsafeBytes { buffer in
        full.data!.copyMemory(from: buffer.baseAddress!, byteCount: buffer.count)
    }
    guard let image = full.makeImage()?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    else { throw Failure(description: "crop") }
    cropped.draw(image, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
    return cropped.makeImage()!
}

/// The translation (pixels, y down) of `image`'s top-left relative to `base`'s that best overlaps their
/// opaque silhouettes, searched ±16 px: coarse every 4 px, then every pixel around the best.
func align(_ image: CGImage, to base: CGImage) -> (x: Double, y: Double, score: Double) {
    guard let a = RigRaster.pixels(of: base), let b = RigRaster.pixels(of: image) else { return (0, 0, 0) }
    func solid(_ p: RigRaster.Pixels, _ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < p.width && y < p.height && p.bytes[(y * p.width + x) * 4 + 3] > 128
    }
    func score(_ dx: Int, _ dy: Int) -> Double {
        var both = 0, either = 0
        for y in stride(from: 0, to: a.height, by: 2) {
            for x in stride(from: 0, to: a.width, by: 2) {
                let p = solid(a, x, y), q = solid(b, x - dx, y - dy)
                if p && q { both += 1 }
                if p || q { either += 1 }
            }
        }
        return either == 0 ? 0 : Double(both) / Double(either)
    }
    var best = (x: 0, y: 0, score: score(0, 0))
    for dy in stride(from: -16, through: 16, by: 4) { for dx in stride(from: -16, through: 16, by: 4) {
        let s = score(dx, dy); if s > best.score { best = (dx, dy, s) }
    } }
    let coarse = best
    for dy in (coarse.y - 3)...(coarse.y + 3) { for dx in (coarse.x - 3)...(coarse.x + 3) {
        let s = score(dx, dy); if s > best.score { best = (dx, dy, s) }
    } }
    return (Double(best.x), Double(best.y), best.score)
}

/// Keeps only a feathered ellipse of `image` (pixels, y down from the top).
func feather(_ image: CGImage, center: CGPoint, radii: CGSize, edge: Double) throws -> CGImage {
    guard var pixels = RigRaster.pixels(of: image) else { return image }
    for y in 0..<pixels.height {
        for x in 0..<pixels.width {
            let dx = (Double(x) + 0.5 - center.x) / radii.width, dy = (Double(y) + 0.5 - center.y) / radii.height
            let distance = (dx * dx + dy * dy).squareRoot()
            let edgeInUnits = edge / Double(min(radii.width, radii.height))
            let keep = min(1, max(0, (1 - distance) / edgeInUnits))
            for channel in 0..<4 {
                let i = (y * pixels.width + x) * 4 + channel
                pixels.bytes[i] = UInt8(Double(pixels.bytes[i]) * keep)
            }
        }
    }
    let output = try context(pixels.width, pixels.height)
    pixels.bytes.withUnsafeBytes { output.data!.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    return output.makeImage()!
}

/// The cut, scaled, rotated (degrees, clockwise on screen) and flipped, on a canvas of `size` pixels
/// (or its own bounds plus a 4 px margin) with its centre in the middle.
struct Transform {
    var scale: Double
    var stretch: [Double]
    var rot: Double
    var flip: Bool
    /// Pixel offset of this image's centre from the part's centre (screen axes, y down).
    var offset: CGPoint
}

func place(_ image: CGImage, _ t: Transform, size: CGSize?) throws -> CGImage {
    let w = Double(image.width) * t.scale * (t.stretch.first ?? 1), h = Double(image.height) * t.scale * (t.stretch.last ?? 1)
    let angle = t.rot * .pi / 180
    let boundsW = abs(w * cos(angle)) + abs(h * sin(angle)), boundsH = abs(w * sin(angle)) + abs(h * cos(angle))
    let dx = Double(abs(t.offset.x)), dy = Double(abs(t.offset.y))
    let natural = CGSize(width: (boundsW + 2 * dx + 8).rounded(.up), height: (boundsH + 2 * dy + 8).rounded(.up))
    let canvas: CGSize = size ?? natural
    let output = try context(Int(canvas.width), Int(canvas.height))
    output.interpolationQuality = .high
    output.translateBy(x: canvas.width / 2 + t.offset.x, y: canvas.height / 2 - t.offset.y)
    let (rot, flip) = (t.rot, t.flip)
    // CoreGraphics is y-up, so a clockwise screen rotation is a negative angle here.
    output.rotate(by: -rot * .pi / 180)
    if flip { output.scaleBy(x: -1, y: 1) }
    output.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    return output.makeImage()!
}

func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let sourcePath = arguments.first else { throw Failure(description: "usage: RigBake <pack>/rig/source.json [--out <dir>]") }
    arguments.removeFirst()
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let packURL = sourceURL.deletingLastPathComponent().deletingLastPathComponent()
    var outURL = packURL.appendingPathComponent("rig/pack", isDirectory: true)
    if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count { outURL = URL(fileURLWithPath: arguments[index + 1]) }
    let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: sourceURL))
    var sheets: [String: CGImage] = [:]
    func sheet(_ name: String) throws -> CGImage {
        if let known = sheets[name] { return known }
        let path = source.sheets[name] ?? name
        let image = try load(packURL.appendingPathComponent(path))
        sheets[name] = image
        return image
    }
    var files: [String: Data] = [:]
    var parts: [RigSpec.Part] = []
    for part in source.parts {
        // Every image of the part shares one canvas size and centre, so swaps never shift it.
        var placements: [(name: String?, image: CGImage)] = []
        let base = try cut(sheet(part.island.sheet), part.island)
        let stretch = part.stretch ?? [1, 1]
        var cuts: [(String?, CGImage, Transform)] = [(nil, base, Transform(scale: part.scale, stretch: stretch, rot: part.rot ?? 0,
                                                                          flip: part.flip ?? false, offset: .zero))]
        var masks: [String: [Double]] = [:]
        for (name, variant) in (part.variants ?? [:]).sorted(by: { $0.key < $1.key }) {
            let center = variant.center ?? part.center
            var offset = CGPoint(x: (center[0] - part.center[0]) * source.unitScale, y: (center[1] - part.center[1]) * source.unitScale)
            let image = try cut(sheet(variant.island.sheet), variant.island)
            if variant.alignToBase == true {
                // Sheet pixels: where the variant's crop sits relative to the base's, then to output pixels.
                let o = align(image, to: base)
                let scale = variant.scale ?? part.scale
                offset = CGPoint(x: (o.x + Double(image.width - base.width) / 2) * scale,
                                 y: (o.y + Double(image.height - base.height) / 2) * scale)
                print("RigBake: \(part.name)-\(name) aligned by (\(Int(o.x)), \(Int(o.y))) px, overlap \(String(format: "%.3f", o.score))")
            }
            if let mask = variant.faceMask { masks[name] = mask }
            cuts.append((name, image,
                         Transform(scale: variant.scale ?? part.scale, stretch: variant.stretch ?? stretch, rot: variant.rot ?? part.rot ?? 0,
                                   flip: variant.flip ?? part.flip ?? false, offset: offset)))
        }
        // One canvas for all of them, centred on the part's centre.
        let natural = try cuts.map { try place($0.1, $0.2, size: nil) }
        let size = CGSize(width: natural.map(\.width).max()!, height: natural.map(\.height).max()!)
        for item in cuts {
            var placed = try place(item.1, item.2, size: size)
            if let name = item.0, let mask = masks[name] {
                // Ellipse in output pixels, relative to the part's centre (the canvas centre).
                placed = try feather(placed, center: CGPoint(x: size.width / 2 + (mask[0] - part.center[0]) * source.unitScale,
                                                             y: size.height / 2 + (mask[1] - part.center[1]) * source.unitScale),
                                     radii: CGSize(width: mask[2] * source.unitScale, height: mask[3] * source.unitScale),
                                     edge: 3 * source.unitScale)
            }
            placements.append((item.0, placed))
        }
        var variants: [String: String] = [:]
        for placement in placements {
            let path = "rig/\(part.name)" + (placement.name.map { "-\($0)" } ?? "") + ".png"
            files[path] = try png(placement.image)
            if let name = placement.name { variants[name] = path }
        }
        let units = CGSize(width: size.width / source.unitScale, height: size.height / source.unitScale)
        parts.append(RigSpec.Part(name: part.name, image: "rig/\(part.name).png", bone: part.bone,
                                  origin: [part.center[0] - units.width / 2, part.center[1] - units.height / 2],
                                  variants: variants.isEmpty ? nil : variants, hidden: part.hidden, mounts: part.mounts))
    }
    let rig = RigSpec(unitScale: source.unitScale, restScale: source.restScale, bones: source.bones, parts: parts,
                      clips: source.clips, reserve: source.reserve, faces: source.faces, poses: source.poses)
    let errors = RigLimits.validate(rig)
    guard errors.isEmpty else { throw Failure(description: "rig: " + errors.joined(separator: "; ")) }
    let images = files.compactMapValues(RigRaster.image)
    let sizes = images.mapValues { CGSize(width: $0.width, height: $0.height) }
    func bake(_ path: String, pose: String, face: String?, only: String? = nil) throws {
        var placed = RigEvaluator.pose(rig, still: pose, sizes: sizes,
                                       swaps: rig.faceSwaps(face) + (only.map { [RigSpec.Swap(at: 0, part: $0, variant: "default")] } ?? []))
        if let only { placed.parts = placed.parts.filter { $0.part == only } }
        guard let image = RigRaster.render(placed, images: images, side: MascotPack.canvasSize) else { throw Failure(description: "bake") }
        files[path] = try png(image)
    }
    var states: [String: MascotPackManifest.StateSpec] = [:]
    var baked: [String: String] = [:]
    for (name, state) in source.states.sorted(by: { $0.key < $1.key }) {
        var paths: [String] = []
        for frame in state.frames {
            let key = frame.pose + "|" + (frame.face ?? "")
            if let known = baked[key] { paths.append(known); continue }
            let path = "frames/rig-\(name)-\(String(format: "%02d", paths.count)).png"
            try bake(path, pose: frame.pose, face: frame.face)
            baked[key] = path
            paths.append(path)
        }
        states[name] = .init(frames: paths, durationMs: state.durationMs, loop: state.loop, staticFallback: paths[0])
    }
    var accessories: [String: MascotPackManifest.AccessorySpec] = [:]
    for (name, accessory) in (source.accessories ?? [:]).sorted(by: { $0.key < $1.key }) {
        let path = "accessories/rig-\(name).png"
        if let part = accessory.part {
            try bake(path, pose: "idle", face: nil, only: part)
        } else if let image = accessory.image {
            let original = try load(packURL.appendingPathComponent(image))
            let output = try context(MascotPack.canvasSize, MascotPack.canvasSize)
            output.interpolationQuality = .high
            let rest = source.restScale ?? 1, anchor = CGPoint(x: 128, y: Double(MascotPack.canvasSize) - 232)
            output.translateBy(x: anchor.x, y: anchor.y)
            output.scaleBy(x: rest, y: rest)
            output.translateBy(x: -anchor.x, y: -anchor.y)
            output.draw(original, in: CGRect(x: 0, y: 0, width: MascotPack.canvasSize, height: MascotPack.canvasSize))
            files[path] = try png(output.makeImage()!)
        }
        accessories[name] = .init(image: path)
    }
    let manifest = MascotPackManifest(
        schemaVersion: 3, id: source.id, name: source.name, canvas: .init(width: 256, height: 256), anchor: MascotPack.anchor,
        states: states, frameSha256: files.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
        accessories: accessories.isEmpty ? nil : accessories, points: source.points, rig: rig)
    for directory in ["rig", "frames", "accessories"] {
        try FileManager.default.createDirectory(at: outURL.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    for (path, data) in files.sorted(by: { $0.key < $1.key }) { try data.write(to: outURL.appendingPathComponent(path)) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: outURL.appendingPathComponent("manifest.json"))
    print("RigBake: \(source.id): \(parts.count) parts, \(files.count) images, \(states.count) states -> \(outURL.path)")
    // Load it exactly as the app loads a bundled pack, and name any clip sample that leaves the reserve.
    switch MascotPack.load(from: outURL, expectedID: source.id, budget: .bundled) {
    case .success(let pack):
        print("RigBake: loads under the bundled budget and reserve")
        _ = pack
    case .failure(let failure):
        print("RigBake: FAILS to load as bundled: " + failure.errors.map(\.description).joined(separator: "; "))
        if let loaded = try? MascotPack.load(from: outURL, expectedID: source.id).get(), let reserve = rig.reserve {
            let hats = (loaded.manifest.accessories ?? [:]).keys.map { MascotAccessoryID($0) }
            for (name, clip) in (rig.clips ?? [:]).sorted(by: { $0.key < $1.key }) {
                for worn in clip.accessories == .hide ? [false] : [false, true] {
                    let played = RigSpec.wearing(clip, worn)
                    var reported = 0
                    for ms in stride(from: 0.0, through: Double(played.durationMs), by: 1000 / 60) where reported < 4 {
                        let pose = RigEvaluator.pose(rig, clip: played, at: ms, sizes: loaded.rigImageSizes)
                        let p = MascotPose(state: .idle, frame: nil, clipElapsed: ms / 1000, clip: ClipFrame(id: MascotClipID(name), frame: 0, elapsed: ms / 1000),
                                           accessories: worn ? hats : [])
                        let extra = worn ? (loaded.rigPose(for: p).map { RigEvaluator.headMotion(rig, pose: $0) } ?? nil).map { motion in
                            hats.compactMap { loaded.manifest.accessorySpec($0).flatMap { loaded.extraOutlines[$0.image] } }
                                .flatMap { $0.outlinePoints.map { $0.applying(motion) } }
                        } ?? [] : []
                        let box = pose.bounds(outlines: loaded.rigOutlines, unitScale: rig.unitScale, extra: extra)
                        if box.minX < Double(reserve[0]) || box.minY < Double(reserve[1]) || box.maxX > Double(reserve[2] + 1) {
                            // Name the part at each edge that is out.
                            func edge(_ value: (CGRect) -> Double, _ lowest: Bool) -> String {
                                let boxes = pose.parts.map { part -> (String, Double) in
                                    var single = pose
                                    single.parts = [part]
                                    let b = single.bounds(outlines: loaded.rigOutlines, unitScale: rig.unitScale)
                                    return (part.part, b.isNull ? (lowest ? .infinity : -.infinity) : value(b))
                                }
                                return (lowest ? boxes.min { $0.1 < $1.1 } : boxes.max { $0.1 < $1.1 })?.0 ?? "?"
                            }
                            print("  \(name)\(worn ? " (hat)" : "") @\(Int(ms)) ms: x \(Int(box.minX))–\(Int(box.maxX)), top \(Int(box.minY))"
                                  + " [left \(edge({ $0.minX }, true)), right \(edge({ $0.maxX }, false)), top \(edge({ $0.minY }, true))]")
                            reported += 1
                        }
                    }
                }
            }
        }
    }
    if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count {
        try preview(rig: rig, images: images, sizes: sizes, reference: try? load(packURL.appendingPathComponent("frames/idle-00.png")),
                    to: URL(fileURLWithPath: arguments[index + 1]))
    }
}

/// Designer contact sheet: rows of 256 pt cells at 2x.
func preview(rig: RigSpec, images: [String: CGImage], sizes: [String: CGSize], reference: CGImage?, to url: URL) throws {
    var cells: [[(label: String, pose: RigPose?, image: CGImage?, pivots: [CGPoint])]] = []
    let rest = RigEvaluator.pose(rig, still: "idle", sizes: sizes)
    cells.append([("rest", rest, nil, []), ("idle-00", nil, reference, [])]
                 + (rig.poses ?? [:]).keys.sorted().filter { $0 != "idle" }.map { ($0, RigEvaluator.pose(rig, still: $0, sizes: sizes), nil, []) })
    var row: [(String, RigPose?, CGImage?, [CGPoint])] = []
    for (name, bone) in rig.bones.sorted(by: { $0.key < $1.key }) where bone.parent != nil {
        let range = bone.rot ?? [-20, 20]
        for value in [range[0], range[1]] {
            let pose = RigEvaluator.place(rig, RigEvaluator.pose(rig, channels: ["\(name).rot": value],
                                                                swaps: rig.faceSwaps(rig.poses?["idle"]?.face)), sizes: sizes)
            let pivot = CGPoint(x: bone.pivot[0], y: bone.pivot[1]).applying(pose.bones[name] ?? .identity)
            row.append(("\(name) \(Int(value))°", pose, nil, [pivot]))
            if row.count == 8 { cells.append(row); row = [] }
        }
    }
    if !row.isEmpty { cells.append(row) }
    for (name, clip) in (rig.clips ?? [:]).sorted(by: { $0.key < $1.key }) {
        cells.append((0..<12).map { index in
            let ms = Double(clip.durationMs) * Double(index) / 11
            return ("\(name) \(Int(ms))", RigEvaluator.pose(rig, clip: clip, at: ms, sizes: sizes), nil, [])
        })
    }
    let cell = 256, label = 18, columns = cells.map(\.count).max() ?? 1
    let output = try context(columns * cell, cells.count * (cell + label))
    output.setFillColor(CGColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1))
    output.fill(CGRect(x: 0, y: 0, width: output.width, height: output.height))
    for (r, items) in cells.enumerated() {
        for (c, item) in items.enumerated() {
            let originY = output.height - (r + 1) * (cell + label)
            output.saveGState()
            output.translateBy(x: CGFloat(c * cell), y: CGFloat(originY))
            output.setStrokeColor(CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 0.5))
            for y in [20.0, 232.0] { output.move(to: CGPoint(x: 0, y: Double(cell) - y)); output.addLine(to: CGPoint(x: Double(cell), y: Double(cell) - y)) }
            if let reserve = rig.reserve {
                for x in [reserve[0], reserve[2]] { output.move(to: CGPoint(x: x, y: 0)); output.addLine(to: CGPoint(x: x, y: cell)) }
            }
            output.strokePath()
            if let image = item.image { output.draw(image, in: CGRect(x: 0, y: 0, width: cell, height: cell)) }
            if let pose = item.pose {
                output.saveGState()
                output.translateBy(x: 0, y: CGFloat(cell))
                output.scaleBy(x: 1, y: -1)
                RigRaster.draw(pose, images: images, in: output)
                output.setFillColor(CGColor(red: 0, green: 0.7, blue: 1, alpha: 1))
                for pivot in item.pivots { output.fillEllipse(in: CGRect(x: pivot.x - 3, y: pivot.y - 3, width: 6, height: 6)) }
                output.restoreGState()
            }
            output.restoreGState()
            let text = NSAttributedString(string: item.label, attributes: [.font: CTFontCreateWithName("Menlo" as CFString, 11, nil)])
            let line = CTLineCreateWithAttributedString(text)
            output.textPosition = CGPoint(x: c * cell + 4, y: originY + cell + 4)
            CTLineDraw(line, output)
        }
    }
    try png(output.makeImage()!).write(to: url)
    print("RigBake: preview -> \(url.path)")
}

do { try run() } catch {
    FileHandle.standardError.write(Data("RigBake: \(error)\n".utf8))
    exit(1)
}
