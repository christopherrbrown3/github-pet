import AppKit
import GitHubPetCore
import SwiftUI

/// #138 clip renders (Demo only): every design-v1 clip and held pose of both skins, drawn from the
/// pack with placeholder clips ("PH"), at its first, middle and last frame, plus the Reduce Motion
/// substitutions. One contact sheet per skin; the report states each clip's frames and that the
/// layout is unchanged.
extension SnapshotRenderer {
    static func clipRenders(model: AppModel, directory: URL) async -> [String] {
        var report = ["## animation clips (#138, placeholder frames)"]
        for skin in MascotSkin.allCases {
            report += await withSkin(skin, model: model) {
                guard let original = model.pack else { return ["FAIL clips \(skin.rawValue): no pack"] }
                let pack = original.withPlaceholderClips()
                return await clipSheet(model: model, pack: pack, original: original, skin: skin, directory: directory)
            }
        }
        return report
    }

    private struct SheetRow: Identifiable {
        let id: String
        let poses: [MascotPose]
    }

    private static func clipSheet(model: AppModel, pack: MascotPack, original: MascotPack, skin: MascotSkin,
                                  directory: URL) async -> [String] {
        var lines: [String] = []
        let library = ClipLibrary(pack: pack)
        let hat = [AccessoryPolicy.firefighterHat]
        var rows: [SheetRow] = []
        let ids = ClipCatalog.v1.ordered.map(\.id) + MascotClipID.heldStates
        for id in ids {
            guard let durations = library.durationsMs[id] else { lines.append("FAIL clip \(skin.rawValue) \(id): missing"); continue }
            let count = durations.count
            let keys = Array(Set([0, count / 2, count - 1])).sorted()
            let keeps = !library.hidesAccessories.contains(id)
            let poses = keys.map { index -> MascotPose in
                let elapsed = Double(durations.prefix(index).reduce(0, +)) / 1000
                // incident-end keeps no hat (baked in); show the hat on the keep clips to check its placement.
                return MascotPose(state: .idle, frame: nil, clipElapsed: elapsed,
                                  clip: ClipFrame(id: id, frame: index, elapsed: elapsed + 0.25),
                                  accessories: keeps && id != .drop ? hat : [])
            }
            rows.append(SheetRow(id: id.rawValue, poses: poses))
            let total = durations.reduce(0, +)
            let cap = ClipCatalog.v1[id]?.maxDurationMs
            lines.append("clip \(skin.rawValue) \(id): frames=\(count) length=\(total)ms"
                         + (cap.map { " cap=\($0)ms" } ?? " held-loop") + " keyframes=\(keys.map(String.init).joined(separator: ","))"
                         + " accessories=\(keeps ? "keep" : "hide") placeholder=\(pack.placeholderClips.contains(id) ? "PH" : "art")")
            if let cap, total > cap { lines.append("FAIL clip \(skin.rawValue) \(id): \(total)ms over its \(cap)ms cap") }
        }
        // Reduce Motion: static substitutions only.
        rows.append(SheetRow(id: "reduce-motion", poses: [
            MascotPose(state: .idle, frame: nil, clipElapsed: nil, accessories: hat),
            MascotPose(state: .idle, frame: nil, clipElapsed: nil, clip: ClipFrame(id: .drag, frame: nil, elapsed: 0)),
            MascotPose(state: .idle, frame: nil, clipElapsed: nil, clip: ClipFrame(id: .doze, frame: nil, elapsed: 0)),
        ]))
        for side in [64.0, 128, 256] {
            let before = MascotLayout(artSide: side, pack: original), after = MascotLayout(artSide: side, pack: pack)
            let same = before.laneHeight == after.laneHeight && before.panelSize == after.panelSize
                && before.countSlotX == after.countSlotX
            lines.append("\(same ? "ok" : "FAIL") clips \(skin.rawValue) @\(Int(side)): layout unchanged "
                         + "(lane \(format(after.laneHeight)), panel \(Int(after.panelSize.width))x\(Int(after.panelSize.height)), "
                         + "count-slot-x \(format(after.countSlotX)))")
        }
        lines.append("clips \(skin.rawValue): lean-limit=\(format(pack.clipLeanLimit))° (drag/dizzy; ≤ \(format(DragLean.maxDegrees))°)")
        let layout = model.layout(model.settings.mascotSize)
        let sheet = VStack(alignment: .leading, spacing: 4) {
            Text("\(skin.name): clip key frames (PH = placeholder frames)").font(.caption.bold())
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Text(row.id).font(.caption2.monospaced()).frame(width: 96, alignment: .leading)
                    ForEach(Array(row.poses.enumerated()), id: \.offset) { _, pose in
                        MascotView(model: model, poseOverride: pose, badgeOverride: "2", drawsLabels: true,
                                   renderDate: Date(timeIntervalSinceReferenceDate: 0), packOverride: pack)
                            .frame(width: layout.panelWidth, height: layout.panelSize.height)
                            .background(Color.gray.opacity(0.12))
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        lines += await render(sheet, name: "clips-\(skin.rawValue)", directory: directory, appearance: .aqua)
            .filter { !$0.hasPrefix(" ") }
        return lines
    }
}
