import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// A schema v3 pack made of simple shapes (#138): the rig engine's test fixture and the debug replay
/// build's stand-in until the painted parts land. Never bundled, never a normal launch's art.
///
/// The states are baked from the rig's rest pose (idle blinks by swapping the eyes part), the way the
/// real skins will be baked, so idle draws one image per frame exactly like a frame pack.
public enum RigPlaceholder {
    public static let id = "rig-placeholder"

    /// Parts in canvas units: name, bone, box, colour and shape. Drawn at `unitScale` px per unit.
    struct Shape {
        enum Kind { case capsule, ellipse, rounded, eyes(Eyes), mouth(open: Bool), envelope }
        enum Eyes { case open, half, closed, happy }
        var name: String
        var bone: String
        var box: CGRect
        var kind: Kind
        var color: (Double, Double, Double)
    }

    static let unitScale = 2.0
    static let purple = (0.47, 0.36, 0.78), dark = (0.18, 0.13, 0.32), face = (0.98, 0.93, 0.86)

    static let bones: [String: RigSpec.Bone] = [
        "root": .init(pivot: [128, 232]),
        "body": .init(parent: "root", pivot: [128, 200], rot: [-8, 8]),
        "head": .init(parent: "body", pivot: [128, 138], rot: [-14, 14]),
        "arm-l": .init(parent: "body", pivot: [88, 146], rot: [-40, 175]),
        "arm-r": .init(parent: "body", pivot: [168, 146], rot: [-175, 40]),
        "hand-l": .init(parent: "arm-l", pivot: [86, 190], rot: [-60, 60]),
        "leg-l": .init(parent: "root", pivot: [114, 200], rot: [-20, 20]),
        "leg-r": .init(parent: "root", pivot: [142, 200], rot: [-20, 20]),
    ]

    static let shapes: [Shape] = [
        Shape(name: "leg-l", bone: "leg-l", box: CGRect(x: 104, y: 190, width: 20, height: 42), kind: .capsule, color: dark),
        Shape(name: "leg-r", bone: "leg-r", box: CGRect(x: 132, y: 190, width: 20, height: 42), kind: .capsule, color: dark),
        Shape(name: "body", bone: "body", box: CGRect(x: 84, y: 122, width: 88, height: 84), kind: .rounded, color: purple),
        Shape(name: "arm-l", bone: "arm-l", box: CGRect(x: 78, y: 136, width: 20, height: 58), kind: .capsule, color: dark),
        Shape(name: "arm-r", bone: "arm-r", box: CGRect(x: 158, y: 136, width: 20, height: 58), kind: .capsule, color: dark),
        Shape(name: "head", bone: "head", box: CGRect(x: 66, y: 22, width: 124, height: 124), kind: .ellipse, color: purple),
        Shape(name: "eyes", bone: "head", box: CGRect(x: 96, y: 66, width: 64, height: 26), kind: .eyes(.open), color: dark),
        Shape(name: "mouth", bone: "head", box: CGRect(x: 112, y: 100, width: 32, height: 18), kind: .mouth(open: false), color: dark),
        Shape(name: "envelope", bone: "hand-l", box: CGRect(x: 74, y: 178, width: 34, height: 24), kind: .envelope, color: face),
    ]

    /// The rig, with the `new-item` clip keyed from design section 5.4, adapted to these bones.
    public static var rig: RigSpec {
        let parts = shapes.map { shape -> RigSpec.Part in
            var variants: [String: String]?
            if shape.name == "eyes" { variants = ["half": "rig/eyes-half.png", "closed": "rig/eyes-closed.png", "happy": "rig/eyes-happy.png"] }
            if shape.name == "mouth" { variants = ["open": "rig/mouth-open.png"] }
            return RigSpec.Part(name: shape.name, image: "rig/\(shape.name).png", bone: shape.bone,
                                origin: [shape.box.minX, shape.box.minY], variants: variants,
                                hidden: shape.name == "envelope" ? true : nil)
        }
        return RigSpec(unitScale: unitScale, restScale: 0.96, bones: bones, parts: parts,
                       clips: [MascotClipID.newItem.rawValue: newItem], reserve: [48, 20, 208])
    }

    typealias K = RigSpec.Key

    /// Perk up, crouch, spring up with the envelope raised beside the head, waggle it, settle.
    public static let newItem = RigSpec.Clip(
        durationMs: 1900,
        tracks: [
            // 0.96 rest scale leaves ~10 units under the reserve's top: stretch 3–4% plus a 3-unit hop,
            // with the head counter-squashing at the peak.
            "root.sy": [K(0, 1), K(120, 1.03, .out), K(300, 0.9), K(460, 1.04, .out), K(620, 0.95, .in), K(900, 1, .spring)],
            "root.y": [K(0, 0), K(300, 0), K(460, -3, .out), K(620, 0, .in)],
            "head.rot": [K(0, 0), K(120, -4, .out), K(460, 3), K(900, 0, .spring), K(1030, 3), K(1160, -3), K(1300, 0)],
            "head.sy": [K(0, 1), K(300, 1.04), K(460, 0.96, .out), K(620, 1.03, .in), K(900, 1, .spring)],
            "arm-l.rot": [K(0, 0), K(300, -12), K(560, 165, .back), K(1300, 165), K(1600, 40), K(1900, 0)],
            // Foreshortened while it swings past horizontal, as if it comes forward: the sweep stays
            // inside the skin's width instead of sticking straight out.
            "arm-l.sy": [K(0, 1), K(300, 1), K(340, 0.45, .out), K(480, 0.45), K(600, 1, .out), K(1300, 1), K(1420, 0.45), K(1640, 0.45), K(1760, 1, .out)],
            "arm-l.sx": [K(0, 1)],
            "hand-l.rot": [K(0, 0), K(560, 0), K(690, 22), K(820, -22), K(950, 22), K(1080, -22), K(1210, 0)],
            "arm-r.rot": [K(0, 0), K(300, 8), K(560, -35, .back), K(1300, -30), K(1650, -10), K(1900, 0)],
            "body.rot": [K(0, 0), K(460, 2, .out), K(900, 0, .spring)],
            "leg-l.rot": [K(0, 0), K(300, 6), K(460, -4, .out), K(620, 0, .spring)],
            "leg-r.rot": [K(0, 0), K(300, -6), K(460, 4, .out), K(620, 0, .spring)],
        ],
        follow: [.init(bone: "hand-l", of: "arm-l", delayMs: 70, gain: 0.3)],
        sway: [.init(bones: ["arm-r"], amp: 5, periodMs: 1000)],
        swaps: [.init(at: 0, part: "eyes", variant: "default"), .init(at: 0, part: "mouth", variant: "open"),
                .init(at: 240, part: "envelope", variant: "default"), .init(at: 460, part: "eyes", variant: "happy"),
                .init(at: 1300, part: "eyes", variant: "default"), .init(at: 1300, part: "mouth", variant: "default"),
                .init(at: 1700, part: "eyes", variant: "closed"), .init(at: 1780, part: "eyes", variant: "default"),
                .init(at: 1780, part: "envelope", variant: "hide")])

    /// Writes the pack (manifest, part images, baked state frames) into `directory`.
    public static func write(to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent("rig"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
        var files: [String: Data] = [:]
        for shape in shapes {
            files["rig/\(shape.name).png"] = try png(draw(shape))
            if case .eyes = shape.kind {
                for (name, eyes) in [("half", Shape.Eyes.half), ("closed", .closed), ("happy", .happy)] {
                    var variant = shape
                    variant.kind = .eyes(eyes)
                    files["rig/eyes-\(name).png"] = try png(draw(variant))
                }
            }
            if case .mouth = shape.kind {
                var variant = shape
                variant.kind = .mouth(open: true)
                files["rig/mouth-open.png"] = try png(draw(variant))
            }
        }
        let rig = self.rig
        let images = files.compactMapValues(RigRaster.image)
        let sizes = images.mapValues { CGSize(width: $0.width, height: $0.height) }
        func bake(_ name: String, channels: [String: Double] = [:], swaps: [RigSpec.Swap] = []) throws {
            var pose = RigEvaluator.pose(rig, channels: channels, swaps: swaps, at: 0)
            let origins = Dictionary(uniqueKeysWithValues: rig.parts.map { ($0.name, $0.origin) })
            for index in pose.parts.indices {
                let origin = origins[pose.parts[index].part]!, size = sizes[pose.parts[index].image] ?? .zero
                pose.parts[index].rect = CGRect(x: origin[0], y: origin[1], width: size.width / unitScale, height: size.height / unitScale)
            }
            guard let image = RigRaster.render(pose, images: images, side: MascotPack.canvasSize) else { throw CocoaError(.fileWriteUnknown) }
            files["frames/\(name).png"] = try png(image)
        }
        func eyes(_ variant: String) -> [RigSpec.Swap] { [.init(at: 0, part: "eyes", variant: variant)] }
        try bake("idle-00")
        try bake("idle-01", swaps: eyes("half"))
        try bake("idle-02", swaps: eyes("closed"))
        try bake("attention-00", channels: ["arm-r.rot": -35, "root.sy": 1.02, "head.rot": -3],
                 swaps: eyes("happy") + [.init(at: 0, part: "mouth", variant: "open")])
        try bake("urgent-00", channels: ["arm-l.rot": -15, "arm-r.rot": 15])
        for (path, data) in files { try data.write(to: directory.appendingPathComponent(path)) }
        let manifest = MascotPackManifest(
            schemaVersion: 3, id: id, name: "Rig placeholder", canvas: .init(width: 256, height: 256), anchor: MascotPack.anchor,
            states: [
                "idle": .init(frames: ["frames/idle-00.png", "frames/idle-01.png", "frames/idle-02.png", "frames/idle-01.png"],
                              durationMs: [2000, 125, 125, 125], loop: true, staticFallback: "frames/idle-00.png"),
                "attention": .init(frames: ["frames/attention-00.png"], durationMs: [1900], loop: false,
                                   staticFallback: "frames/attention-00.png"),
                "urgent": .init(frames: ["frames/urgent-00.png"], durationMs: [1900], loop: false, staticFallback: "frames/urgent-00.png"),
            ],
            frameSha256: files.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
            rig: rig)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    }

    static func draw(_ shape: Shape) -> CGImage? {
        let width = Int(shape.box.width * unitScale), height = Int(shape.box.height * unitScale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let (r, g, b) = shape.color
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        context.setStrokeColor(CGColor(red: 0.1, green: 0.07, blue: 0.18, alpha: 1))
        context.setLineWidth(3)
        context.setLineCap(.round)
        let inset = rect.insetBy(dx: 2, dy: 2)
        switch shape.kind {
        case .capsule:
            let path = CGPath(roundedRect: inset, cornerWidth: inset.width / 2, cornerHeight: inset.width / 2, transform: nil)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        case .ellipse:
            context.addEllipse(in: inset)
            context.drawPath(using: .fillStroke)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
            context.fillEllipse(in: CGRect(x: inset.minX + inset.width * 0.18, y: inset.midY, width: inset.width * 0.3, height: inset.height * 0.3))
        case .rounded:
            context.addPath(CGPath(roundedRect: inset, cornerWidth: 40, cornerHeight: 40, transform: nil))
            context.drawPath(using: .fillStroke)
        case .eyes(let eyes):
            // Two eyes, each a quarter of the image wide; CoreGraphics y is up.
            context.setLineWidth(6)
            for centre in [CGFloat(width) * 0.22, CGFloat(width) * 0.78] {
                let eye = CGRect(x: centre - 14, y: CGFloat(height) / 2 - 20, width: 28, height: 40)
                switch eyes {
                case .open:
                    context.fillEllipse(in: eye)
                    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    context.fillEllipse(in: CGRect(x: eye.minX + 6, y: eye.maxY - 16, width: 9, height: 9))
                    context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
                case .half:
                    context.fillEllipse(in: eye.insetBy(dx: 0, dy: 10).offsetBy(dx: 0, dy: -6))
                case .closed:
                    context.move(to: CGPoint(x: eye.minX, y: eye.midY + 2))
                    context.addQuadCurve(to: CGPoint(x: eye.maxX, y: eye.midY + 2), control: CGPoint(x: eye.midX, y: eye.midY - 10))
                    context.strokePath()
                case .happy:
                    context.move(to: CGPoint(x: eye.minX, y: eye.midY - 4))
                    context.addQuadCurve(to: CGPoint(x: eye.maxX, y: eye.midY - 4), control: CGPoint(x: eye.midX, y: eye.midY + 14))
                    context.strokePath()
                }
            }
        case .mouth(let open):
            context.setLineWidth(5)
            if open {
                context.fillEllipse(in: CGRect(x: rect.midX - 12, y: 4, width: 24, height: CGFloat(height) - 10))
            } else {
                context.move(to: CGPoint(x: 8, y: CGFloat(height) - 10))
                context.addQuadCurve(to: CGPoint(x: CGFloat(width) - 8, y: CGFloat(height) - 10), control: CGPoint(x: rect.midX, y: 0))
                context.strokePath()
            }
        case .envelope:
            context.addPath(CGPath(roundedRect: inset, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.drawPath(using: .fillStroke)
            context.move(to: CGPoint(x: inset.minX, y: inset.maxY))
            context.addLine(to: CGPoint(x: inset.midX, y: inset.midY))
            context.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
            context.strokePath()
            context.setFillColor(CGColor(red: 0.55, green: 0.72, blue: 0.95, alpha: 1))
            context.fillEllipse(in: CGRect(x: inset.midX - 6, y: inset.midY - 6, width: 12, height: 12))
        }
        return context.makeImage()
    }

    static func png(_ image: CGImage?) throws -> Data {
        let data = NSMutableData()
        guard let image, let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
