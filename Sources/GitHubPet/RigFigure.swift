import AppKit
import GitHubPetCore
import SwiftUI

/// Draws one instant of a cutout rig clip (#138): every placed part under its bone transform, in one
/// Canvas, then any accessory (the hat) carried by the head bone. Canvas units are the 256 canvas,
/// scaled to the art square, so it lines up exactly with the baked state frames around it.
struct RigFigure: View {
    let pack: MascotPack
    let pose: RigPose
    let accessories: [MascotAccessoryID]

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / CGFloat(MascotPack.canvasSize)
            context.scaleBy(x: scale, y: scale)
            for part in pose.parts {
                guard let image = PackImageCache.shared.image(part.image, in: pack) else { continue }
                var layer = context
                layer.concatenate(part.transform)
                layer.opacity = part.opacity
                layer.draw(Image(nsImage: image).interpolation(.high).antialiased(true), in: part.rect)
            }
            guard !accessories.isEmpty, let rig = pack.manifest.rig,
                  let motion = RigEvaluator.headMotion(rig, pose: pose) else { return }
            var worn = context
            worn.concatenate(motion)
            for id in accessories {
                guard let path = pack.manifest.accessorySpec(id)?.image,
                      let image = PackImageCache.shared.image(path, in: pack) else { continue }
                worn.draw(Image(nsImage: image).interpolation(.high).antialiased(true),
                          in: CGRect(x: 0, y: 0, width: MascotPack.canvasSize, height: MascotPack.canvasSize))
            }
        }
        // Composite through Metal: CPU rasterizing the Canvas in each Core Animation commit was most
        // of a 60 fps frame's cost (#138 measurements).
        .drawingGroup()
    }
}

/// The live window's rig (#138): one Core Animation layer per part, so a frame only updates layer
/// transforms and the GPU composites them; the Canvas above rasterized every part on the CPU in each
/// commit. Snapshots and render-check keep `RigFigure`, which `ImageRenderer` can draw.
struct RigLayerFigure: NSViewRepresentable {
    let pack: MascotPack
    let pose: RigPose
    let accessories: [MascotAccessoryID]

    func makeNSView(context: Context) -> RigLayerView { RigLayerView() }

    func updateNSView(_ view: RigLayerView, context: Context) {
        view.apply(pack: pack, pose: pose, accessories: accessories)
    }
}

final class RigLayerView: NSView {
    private var parts: [String: CALayer] = [:]
    private var worn: [MascotAccessoryID: CALayer] = [:]
    private var images: [String: CGImage] = [:]
    private var packDirectory: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func apply(pack: MascotPack, pose: RigPose, accessories: [MascotAccessoryID]) {
        guard let root = layer else { return }
        if packDirectory != pack.directory {
            (Array(parts.values) + Array(worn.values)).forEach { $0.removeFromSuperlayer() }
            parts = [:]
            worn = [:]
            images = [:]
            packDirectory = pack.directory
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = CGAffineTransform(scaleX: bounds.width / CGFloat(MascotPack.canvasSize),
                                      y: bounds.height / CGFloat(MascotPack.canvasSize))
        let contentsScale = window?.backingScaleFactor ?? 2
        var shown: Set<String> = []
        for (index, part) in pose.parts.enumerated() {
            let sublayer = parts[part.part] ?? {
                let created = CALayer()
                created.anchorPoint = .zero
                created.position = .zero
                root.addSublayer(created)
                parts[part.part] = created
                return created
            }()
            sublayer.contents = image(part.image, in: pack)
            sublayer.contentsScale = contentsScale
            sublayer.bounds = CGRect(origin: .zero, size: part.rect.size)
            sublayer.setAffineTransform(CGAffineTransform(translationX: part.rect.minX, y: part.rect.minY)
                .concatenating(part.transform).concatenating(scale))
            sublayer.opacity = Float(part.opacity)
            sublayer.zPosition = CGFloat(index)
            sublayer.isHidden = false
            shown.insert(part.part)
        }
        for (name, sublayer) in parts where !shown.contains(name) { sublayer.isHidden = true }
        let motion = pack.manifest.rig.flatMap { RigEvaluator.headMotion($0, pose: pose) }
        for (id, sublayer) in worn where !accessories.contains(id) || motion == nil { sublayer.isHidden = true }
        if let motion {
            for id in accessories {
                guard let path = pack.manifest.accessorySpec(id)?.image else { continue }
                let sublayer = worn[id] ?? {
                    let created = CALayer()
                    created.anchorPoint = .zero
                    created.position = .zero
                    root.addSublayer(created)
                    worn[id] = created
                    return created
                }()
                sublayer.contents = image(path, in: pack)
                sublayer.contentsScale = contentsScale
                sublayer.bounds = CGRect(x: 0, y: 0, width: MascotPack.canvasSize, height: MascotPack.canvasSize)
                sublayer.setAffineTransform(motion.concatenating(scale))
                sublayer.zPosition = CGFloat(pose.parts.count)
                sublayer.isHidden = false
            }
        }
        CATransaction.commit()
    }

    private func image(_ path: String, in pack: MascotPack) -> CGImage? {
        if let known = images[path] { return known }
        let decoded = PackImageCache.shared.image(path, in: pack)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        images[path] = decoded
        return decoded
    }
}
