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
        enum Kind { case capsule, ellipse, rounded, eyes(Eyes), mouth(open: Bool), envelope, helmet }
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
        // Worn on the head by default (its rest placement is the hat accessory); held by the hand mount.
        Shape(name: "helmet", bone: "head", box: CGRect(x: 86, y: 17, width: 84, height: 40), kind: .helmet,
              color: (0.84, 0.18, 0.14)),
    ]

    /// Face presets (design section 3), as swaps of the eyes and mouth parts.
    static let faces: [String: [String: String]] = [
        "neutral": ["eyes": "default", "mouth": "default"],
        "notice": ["eyes": "default", "mouth": "open"],
        "joy": ["eyes": "happy", "mouth": "open"],
        "squeeze": ["eyes": "closed", "mouth": "open"],
        "determined": ["eyes": "half", "mouth": "default"],
        "blink": ["eyes": "closed"],
        "half": ["eyes": "half"],
    ]

    /// The still poses the states are baked from, and clips end on.
    static let poses: [String: RigSpec.Pose] = [
        "idle": .init(face: "neutral"),
        // Alert by waving and tilting, not by standing taller: the worn hat already uses the headroom.
        "attention": .init(channels: ["arm-r.rot": -35, "head.rot": -3, "body.rot": -2], face: "joy"),
        "urgent": .init(channels: ["arm-l.rot": -15, "arm-r.rot": 15], face: "determined"),
    ]

    /// The rig, with the `new-item` clip keyed from design section 5.4, adapted to these bones.
    public static var rig: RigSpec {
        let parts = shapes.map { shape -> RigSpec.Part in
            var variants: [String: String]?
            if shape.name == "eyes" { variants = ["half": "rig/eyes-half.png", "closed": "rig/eyes-closed.png", "happy": "rig/eyes-happy.png"] }
            if shape.name == "mouth" { variants = ["open": "rig/mouth-open.png"] }
            let mounts: [String: RigSpec.Mount]? = shape.name == "helmet" ? ["hand": .init(bone: "hand-l", origin: [56, 176])] : nil
            return RigSpec.Part(name: shape.name, image: "rig/\(shape.name).png", bone: shape.bone,
                                origin: [shape.box.minX, shape.box.minY], variants: variants,
                                hidden: ["envelope", "helmet"].contains(shape.name) ? true : nil, mounts: mounts)
        }
        return RigSpec(unitScale: unitScale, restScale: 0.96, bones: bones, parts: parts,
                       clips: [MascotClipID.newItem.rawValue: newItem, MascotClipID.incidentStart.rawValue: incidentStart],
                       reserve: [48, 20, 208], faces: faces, poses: poses)
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
        swaps: [.init(at: 240, part: "envelope", variant: "default"), .init(at: 1780, part: "envelope", variant: "hide")],
        faces: [.init(at: 0, preset: "notice"), .init(at: 460, preset: "joy"), .init(at: 1300, preset: "neutral"),
                .init(at: 1700, preset: "blink"), .init(at: 1780, preset: "joy")],
        endsOn: "attention",
        // With the helmet on (an incident is showing) the headroom is the helmet's: perk up by
        // squashing and leaning, not by rising.
        worn: [
            "root.sy": [K(0, 1), K(120, 0.98, .out), K(300, 0.9), K(460, 1.0, .out), K(620, 0.95, .in), K(900, 1, .out)],
            "root.y": [K(0, 0)],
            "head.sy": [K(0, 1), K(300, 0.98), K(460, 1.0, .out), K(620, 0.98), K(900, 1, .out)],
        ])

    /// Notice, bring the helmet up in the left hand, hand it over to the head (an eased mount change),
    /// pull it down with a squash, a determined nod, settle. Ends on rest with the helmet worn exactly
    /// where the hat accessory draws it, so the hand-off to the held overlay is seamless.
    public static let incidentStart = RigSpec.Clip(
        durationMs: 1900,
        tracks: [
            "head.rot": [K(0, 0), K(250, -5, .out), K(550, -2), K(850, 4), K(1150, 0, .spring)],
            "head.y": [K(0, 0), K(1150, 0), K(1300, 4), K(1450, 0, .out)],
            // The helmet comes up to the chest with the arm turned in, then the mount blend lifts it onto
            // the head while the hand follows up and lets go.
            "arm-l.rot": [K(0, 0), K(250, 8), K(550, -32, .back), K(820, -38), K(1050, -20), K(1500, 0)],
            "arm-r.rot": [K(0, 0), K(550, 6), K(850, 25), K(1150, -10, .back), K(1500, 0)],
            "root.sy": [K(0, 1), K(250, 0.97), K(850, 1.0), K(1000, 0.92, .in), K(1300, 1, .out)],
            "body.rot": [K(0, 0), K(550, -2), K(1000, 2), K(1300, 0, .spring)],
        ],
        follow: [.init(bone: "hand-l", of: "arm-l", delayMs: 60, gain: 0.4)],
        swaps: [.init(at: 200, part: "helmet", variant: "default")],
        faces: [.init(at: 0, preset: "notice"), .init(at: 900, preset: "squeeze"), .init(at: 1150, preset: "determined"),
                .init(at: 1600, preset: "neutral")],
        mounts: [.init(at: 200, part: "helmet", mount: "hand"), .init(at: 820, part: "helmet", mount: "default", blendMs: 260)],
        accessories: .hide)

    /// Writes the pack (manifest, part images, baked state frames) into `directory`.
    public static func write(to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent("rig"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("accessories"), withIntermediateDirectories: true)
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
        // The builder's bake: each state frame is a still pose of the rig, so a clip that blends into
        // that pose hands over to the frame without a jump.
        func bake(_ path: String, _ still: String, face: String? = nil, only: String? = nil) throws {
            var pose = RigEvaluator.pose(rig, still: still, sizes: sizes, swaps: rig.faceSwaps(face)
                                         + (only.map { [RigSpec.Swap(at: 0, part: $0, variant: "default")] } ?? []))
            if let only { pose.parts = pose.parts.filter { $0.part == only } }
            guard let image = RigRaster.render(pose, images: images, side: MascotPack.canvasSize) else { throw CocoaError(.fileWriteUnknown) }
            files[path] = try png(image)
        }
        try bake("frames/idle-00.png", "idle")
        try bake("frames/idle-01.png", "idle", face: "half")
        try bake("frames/idle-02.png", "idle", face: "blink")
        try bake("frames/attention-00.png", "attention")
        try bake("frames/urgent-00.png", "urgent")
        // The incident hat: the helmet part alone, worn on the rest head.
        try bake("accessories/firefighter-hat.png", "idle", only: "helmet")
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
            accessories: [AccessoryPolicy.firefighterHat.rawValue: .init(image: "accessories/firefighter-hat.png")],
            points: .init(head: [128, 34]),
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
        // Strokes stay 2 px clear of the image edge, like cut parts' margin.
        let inset = rect.insetBy(dx: 4, dy: 4)
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
        case .helmet:
            // A dome over a brim, with a cream shield; CoreGraphics y is up.
            context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 4, width: CGFloat(width) - 8, height: 18), cornerWidth: 9,
                                   cornerHeight: 9, transform: nil))
            context.drawPath(using: .fillStroke)
            context.addEllipse(in: CGRect(x: 22, y: 10, width: CGFloat(width) - 44, height: CGFloat(height) - 14))
            context.drawPath(using: .fillStroke)
            context.setFillColor(CGColor(red: 0.98, green: 0.93, blue: 0.8, alpha: 1))
            context.fillEllipse(in: CGRect(x: rect.midX - 12, y: 22, width: 24, height: 28))
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
