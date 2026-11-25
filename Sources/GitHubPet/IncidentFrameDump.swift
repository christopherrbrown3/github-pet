import AppKit
import GitHubPetCore
import SwiftUI

/// #138 dev builds (`--dump-incident-frames <dir>`): proof of what each skin shows while an incident
/// is active. Every situation (each mood, Reduce Motion, every event and scheduled clip, drag and doze)
/// is posed with the app's own animator (marker on: the hat accessory requested) and drawn with the
/// app's own `PackFigure`, at every frame change. Per frame the report states the overlays drawn (must
/// be 0 for sequence packs) and the helmets visible (red regions in the upper body). One contact sheet
/// per skin, one row per situation.
@MainActor
enum IncidentFrameDump {
    struct Situation {
        var name: String
        var mood: MascotState
        var reduced = false
        var event: EventClipQueue.Kind?
        var scheduled: MascotClipID?
        var drag = false
        var doze = false
    }

    static let situations: [Situation] = [
        .init(name: "idle", mood: .idle), .init(name: "attention", mood: .attention), .init(name: "urgent", mood: .urgent),
        .init(name: "idle-reduced", mood: .idle, reduced: true), .init(name: "attention-reduced", mood: .attention, reduced: true),
        .init(name: "urgent-reduced", mood: .urgent, reduced: true),
        .init(name: "event-new-item", mood: .attention, event: .newItem), .init(name: "event-urgent", mood: .urgent, event: .urgent),
        .init(name: "event-incident-start", mood: .idle, event: .incidentStart),
    ] + ([.itemCleared, .inboxZero, .poke, .dizzy, .drop, .idleLook, .idleStretch, .idleFidget] as [MascotClipID]).map {
        Situation(name: "clip-\($0.rawValue)", mood: .idle, scheduled: $0)
    } + [.init(name: "drag", mood: .idle, drag: true), .init(name: "doze", mood: .idle, doze: true)]

    static func run(directory: URL) -> Int32 {
        var failures = 0
        var report: [String] = []
        for skin in MascotSkin.allCases {
            guard let dir = LaunchOptions.builtInPackDirectory(for: skin),
                  case .success(let pack) = MascotPack.load(from: dir, expectedID: skin.rawValue, budget: .bundled) else {
                report.append("FAIL \(skin.rawValue): pack did not load"); failures += 1; continue
            }
            let library = ClipLibrary(pack: pack)
            let t0 = Date(timeIntervalSinceReferenceDate: 0)
            var rows: [(String, [NSImage])] = []
            for situation in situations {
                let samples = sampleTimes(situation, library: library)
                var images: [NSImage] = []
                var notes: [String] = []
                for t in samples {
                    let pose = pose(situation, at: t0.addingTimeInterval(t), start: t0, library: library, pack: pack)
                    guard let image = render(pack: pack, pose: pose) else { continue }
                    images.append(image)
                    let helmets = helmetCount(image)
                    let art = pack.imagePath(for: pose) ?? "?"
                    notes.append("\(Int(t * 1000))ms \((art as NSString).lastPathComponent) overlays=\(pose.accessories.count) helmets=\(helmets)")
                    if !pose.accessories.isEmpty { failures += 1 }
                }
                let overlays = notes.filter { !$0.contains("overlays=0") }.count
                let helmetless = notes.filter { $0.hasSuffix("helmets=0") }.count
                let extra = notes.filter { $0.contains("helmets=2") || $0.contains("helmets=3") }.count
                report.append("\(skin.rawValue) \(situation.name): \(notes.count) frames, overlay frames \(overlays), "
                              + "helmetless \(helmetless), two-helmet \(extra)")
                report += notes.map { "    " + $0 }
                rows.append((situation.name, images))
            }
            write(sheet(rows, title: "\(skin.rawValue) during an incident"), to: directory.appendingPathComponent("\(skin.rawValue)-incident.png"))
        }
        report.insert("Incident frame proof: overlays must be 0; helmets counts red helmet regions above the waist.", at: 0)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (report.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(report.filter { !$0.hasPrefix("    ") }.joined(separator: "\n"))
        print("dump-incident-frames: \(failures == 0 ? "no overlay drawn" : "\(failures) frame(s) with an overlay") -> \(directory.path)")
        return failures == 0 ? 0 : 1
    }

    /// Every frame change of what the situation plays, plus one sample of each still.
    static func sampleTimes(_ s: Situation, library: ClipLibrary) -> [Double] {
        let id: MascotClipID? = s.scheduled ?? s.event?.clipID ?? (s.drag ? .drag : s.doze ? .doze : nil)
        var durations = (id.flatMap { library.durationsMs[$0] }) ?? library.durationsMs[.incidentIdle] ?? [1000]
        if s.reduced { durations = [1000] }
        var times: [Double] = [], t = 0.0
        for d in durations { times.append(t + 0.005); t += Double(d) / 1000 }
        return times
    }

    static func pose(_ s: Situation, at now: Date, start: Date, library: ClipLibrary, pack: MascotPack) -> MascotPose {
        var stage = ClipStage()
        if let id = s.scheduled, let policy = ClipCatalog.v1[id], let length = library.duration(id) {
            stage.scheduled = .init(id: id, tier: policy.tier, priority: policy.priority, gate: policy.gate, startedAt: start,
                                    endsAt: start.addingTimeInterval(length))
        }
        if s.drag { stage.dragStart = start }
        if s.doze { stage.dozeStart = start }
        let clip = s.event.map { kind -> EventClipQueue.Clip in
            let item = FixtureSimulator().injectEntitlementEvent(now: start)
            let origin: EventClipQueue.Origin = kind == .incidentStart ? .serviceIncident : .repository
            let length = kind.clipID.flatMap { library.duration($0) } ?? 1.9
            return EventClipQueue.Clip(event: InboxEvent(item: item, severity: kind == .urgent ? .critical : .actionable),
                                       startedAt: start, origin: origin, kind: kind, duration: length)
        }
        return MascotAnimator.pose(mood: s.mood, clip: clip, now: now, reducedMotion: s.reduced, idleEpoch: start,
                                   gesture: pack.attentionGesture, stage: stage, library: library,
                                   accessories: [AccessoryPolicy.firefighterHat]) { state in
            pack.manifest.states[state.rawValue]?.durationMs ?? []
        }
    }

    static func render(pack: MascotPack, pose: MascotPose) -> NSImage? {
        let renderer = ImageRenderer(content: PackFigure(pack: pack, pose: pose).frame(width: 256, height: 256))
        renderer.scale = 1
        return renderer.nsImage
    }

    /// Red helmet regions (saturated red, opaque) whose centre is in the upper half of the canvas: the
    /// worn helmet, never the extinguisher low at the side.
    static func helmetCount(_ image: NSImage) -> Int {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let p = RigRaster.pixels(of: cg) else { return 0 }
        var seen = [Bool](repeating: false, count: p.width * p.height), count = 0
        var centres: [(Int, Int)] = []
        func red(_ i: Int) -> Bool {
            let a = Int(p.bytes[i * 4 + 3]); guard a > 200 else { return false }
            let r = Int(p.bytes[i * 4]), g = Int(p.bytes[i * 4 + 1]), b = Int(p.bytes[i * 4 + 2])
            return r > 150 && g < 90 && b < 90
        }
        for start in 0..<(p.width * p.height) where !seen[start] && red(start) {
            var stack = [start], size = 0, sumY = 0, sumX = 0
            seen[start] = true
            while let i = stack.popLast() {
                size += 1; sumY += i / p.width; sumX += i % p.width
                let x = i % p.width, y = i / p.width
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < p.width, ny < p.height else { continue }
                    let j = ny * p.width + nx
                    if !seen[j] && red(j) { seen[j] = true; stack.append(j) }
                }
            }
            if size > 250, sumY / size < p.height / 2 { centres.append((sumX / size, sumY / size)) }
        }
        // One helmet's red can be split by its shield: regions whose centres are close are one helmet.
        var helmets: [(Int, Int)] = []
        for c in centres where !helmets.contains(where: { abs($0.0 - c.0) < 40 && abs($0.1 - c.1) < 40 }) { helmets.append(c) }
        count = helmets.count
        return count
    }

    static func sheet(_ rows: [(String, [NSImage])], title: String) -> NSImage {
        let cell: CGFloat = 128, label: CGFloat = 150, columns = CGFloat(rows.map(\.1.count).max() ?? 1)
        let size = NSSize(width: label + columns * cell, height: CGFloat(rows.count) * cell + 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        (title as NSString).draw(at: NSPoint(x: 6, y: size.height - 18), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        for (r, row) in rows.enumerated() {
            let y = size.height - 24 - CGFloat(r + 1) * cell
            (row.0 as NSString).draw(at: NSPoint(x: 6, y: y + cell / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            for (c, frame) in row.1.enumerated() { frame.draw(in: NSRect(x: label + CGFloat(c) * cell, y: y, width: cell, height: cell)) }
        }
        image.unlockFocus()
        return image
    }

    static func write(_ image: NSImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
