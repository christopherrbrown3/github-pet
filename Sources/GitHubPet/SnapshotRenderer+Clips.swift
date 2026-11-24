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

/// #138 cutout rig: the shape-only placeholder rig (schema v3) loaded under the bundled budget and
/// bounds rule, and its keyframed clips drawn at key instants through the snapshot (Canvas) path:
/// new-item, new-item with the incident hat worn (its `worn` tracks), and incident-start's helmet hand-over.
extension SnapshotRenderer {
    static let rigInstantsMs: [Double] = [0, 120, 300, 400, 460, 560, 760, 1000, 1300, 1700, 1900]

    private struct RigRow: Identifiable {
        let id: String
        let clip: MascotClipID
        let worn: Bool
    }

    static func rigRenders(model: AppModel, directory: URL) async -> [String] {
        var lines = ["## cutout rig (#138, placeholder rig)"]
        let packDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-pet-rig-render-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packDirectory) }
        guard (try? RigPlaceholder.write(to: packDirectory)) != nil else { return lines + ["FAIL rig: placeholder not written"] }
        let pack: MascotPack
        switch MascotPack.load(from: packDirectory, expectedID: RigPlaceholder.id, budget: .bundled) {
        case .success(let loaded): pack = loaded
        case .failure(let failure): return lines + ["FAIL rig: \(PackLabel.joined(failure.errors, separator: "; "))"]
        }
        let library = ClipLibrary(pack: pack)
        lines.append("ok rig loaded: schema \(pack.manifest.schemaVersion), \(pack.manifest.rig?.parts.count ?? 0) parts, "
                     + "\(pack.rigOutlines.count) images, bundled budget and reserve")
        let rows = [RigRow(id: "new-item", clip: .newItem, worn: false), RigRow(id: "new-item + hat", clip: .newItem, worn: true),
                    RigRow(id: "incident-start", clip: .incidentStart, worn: false)]
        func pose(_ row: RigRow, _ ms: Double) -> MascotPose {
            MascotPose(state: .attention, frame: nil, clipElapsed: ms / 1000, clip: ClipFrame(id: row.clip, frame: 0, elapsed: ms / 1000),
                       accessories: row.worn ? [AccessoryPolicy.firefighterHat] : [])
        }
        for row in rows {
            let drawn = rigInstantsMs.filter { pack.rigPose(for: pose(row, $0)) != nil }.count
            lines.append("\(drawn == rigInstantsMs.count ? "ok" : "FAIL") rig \(row.id): length="
                         + "\(Int((library.duration(row.clip) ?? 0) * 1000))ms, \(drawn)/\(rigInstantsMs.count) instants drawn by the rig")
        }
        let layout = model.layout(model.settings.mascotSize)
        let sheet = VStack(alignment: .leading, spacing: 4) {
            Text("Placeholder rig at \(rigInstantsMs.map { String(Int($0)) }.joined(separator: ", ")) ms").font(.caption.bold())
            ForEach(rows) { row in
                HStack(spacing: 4) {
                    Text(row.id).font(.caption2.monospaced()).frame(width: 96, alignment: .leading)
                    ForEach(Array(rigInstantsMs.enumerated()), id: \.offset) { _, ms in
                        MascotView(model: model, poseOverride: pose(row, ms), badgeOverride: "2", drawsLabels: true,
                                   renderDate: Date(timeIntervalSinceReferenceDate: 0), packOverride: pack)
                            .frame(width: layout.panelWidth, height: layout.panelSize.height)
                            .background(Color.gray.opacity(0.12))
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        lines += await render(sheet, name: "rig-clips", directory: directory, appearance: .aqua).filter { !$0.hasPrefix(" ") }
        return lines
    }
}
