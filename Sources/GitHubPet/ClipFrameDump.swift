import AppKit
import GitHubPetCore

/// #138 dev builds (`--dump-clip-frames <dir> <skin>`): every rig clip of a built-in skin rendered at
/// 60 Hz offscreen by the live window's own renderer (`RigLayerView`, Core Animation layers), at 128 pt
/// @2x on a light and a dark background, as numbered PNGs plus one contact sheet per clip (every third
/// frame, light rows then dark rows). Clips that keep accessories are also dumped with the incident hat.
/// For an independent visual review; it never touches preferences or data, and quits when done.
@MainActor
enum ClipFrameDump {
    static let points: CGFloat = 128
    static let scale: CGFloat = 2
    static let backgrounds: [(name: String, color: CGColor)] = [
        ("light", CGColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1)),
        ("dark", CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)),
    ]

    static func run(skin: MascotSkin, directory: URL) -> Int32 {
        guard let packDirectory = LaunchOptions.builtInPackDirectory(for: skin) else {
            print("dump-clip-frames: no built-in pack for \(skin.rawValue)"); return 1
        }
        let pack: MascotPack
        switch MascotPack.load(from: packDirectory, expectedID: skin.rawValue, budget: .bundled) {
        case .success(let loaded): pack = loaded
        case .failure(let failure):
            print("dump-clip-frames: \(PackLabel.joined(failure.errors, separator: "; "))"); return 1
        }
        guard pack.manifest.isV3, let rig = pack.manifest.rig, let clips = rig.clips, !clips.isEmpty else {
            print("dump-clip-frames: \(skin.rawValue) has no rig clips"); return 1
        }
        let hats = (pack.manifest.accessories ?? [:]).keys.sorted().map { MascotAccessoryID($0) }
        let view = RigLayerView(frame: NSRect(x: 0, y: 0, width: points, height: points))
        let root = directory.appendingPathComponent(skin.rawValue, isDirectory: true)
        var index: [String] = []
        for (name, clip) in clips.sorted(by: { $0.key < $1.key }) {
            for worn in clip.accessories == .hide || hats.isEmpty ? [false] : [false, true] {
                let label = name + (worn ? "+hat" : "")
                var frames: [String: [CGImage]] = [:]
                let samples = Array(stride(from: 0.0, to: Double(clip.durationMs), by: 1000 / 60)) + [Double(clip.durationMs)]
                for (number, ms) in samples.enumerated() {
                    let pose = MascotPose(state: .attention, frame: nil, clipElapsed: ms / 1000,
                                          clip: ClipFrame(id: MascotClipID(name), frame: 0, elapsed: ms / 1000),
                                          accessories: worn ? hats : [])
                    guard let placed = pack.rigPose(for: pose) else { continue }
                    view.apply(pack: pack, pose: placed, accessories: pose.accessories)
                    for background in backgrounds {
                        guard let image = render(view, background: background.color) else { continue }
                        frames[background.name, default: []].append(image)
                        write(image, to: root.appendingPathComponent("\(label)/\(background.name)/frame-\(String(format: "%03d", number)).png"))
                    }
                }
                if let sheet = contactSheet(frames, title: "\(skin.rawValue) \(label): every 3rd frame of \(samples.count) at 60 Hz") {
                    write(sheet, to: root.appendingPathComponent("\(label)-contact.png"))
                }
                index.append("\(label): \(samples.count) frames, \(clip.durationMs) ms")
            }
        }
        try? (index.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
        print("dump-clip-frames: \(index.count) clips -> \(root.path)")
        return 0
    }

    /// The layer tree exactly as the window composites it, flattened onto an opaque background.
    static func render(_ view: RigLayerView, background: CGColor) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let side = Int(points * scale)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // The view is flipped (y down); its layer renders y-down into a y-up context.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        return context.makeImage()
    }

    static func contactSheet(_ frames: [String: [CGImage]], title: String) -> CGImage? {
        let cell = Int(points * scale), columns = 13, titleHeight = 28
        let rows = backgrounds.map { background in
            stride(from: 0, to: frames[background.name]?.count ?? 0, by: 3).map { frames[background.name]![$0] }
        }
        let rowCounts = rows.map { ($0.count + columns - 1) / columns }
        let height = titleHeight + rowCounts.reduce(0, +) * cell
        guard let context = CGContext(data: nil, width: columns * cell, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: columns * cell, height: height))
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)])
        context.textPosition = CGPoint(x: 8, y: height - 20)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        var row = 0
        for images in rows {
            for (i, image) in images.enumerated() {
                let r = row + i / columns
                context.draw(image, in: CGRect(x: (i % columns) * cell, y: height - titleHeight - (r + 1) * cell, width: cell, height: cell))
            }
            row += (images.count + columns - 1) / columns
        }
        return context.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
