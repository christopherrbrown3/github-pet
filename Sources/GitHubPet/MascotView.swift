import AppKit
import GitHubPetCore
import SwiftUI

/// Draws the mascot: a validated artwork pack when one is loaded, otherwise the
/// native placeholder. Timing comes from `MascotAnimator` on the app clock, so QA clock
/// hooks drive animation too. Reduced motion pins a static pose; text and badge never move.
struct MascotView: View {

    @ObservedObject var model: AppModel
    @Environment(\.displayScale) private var displayScale
    /// Render-check only: draw a fixed pose and badge, and only some layers.
    var poseOverride: MascotPose?
    var badgeOverride: String?
    var drawsArt = true
    var drawsLabels = true
    /// Incident marker (#37); by default only in full renders, not in single-layer probes.
    var drawsMarker: Bool?
    /// QA runner only: draw one still at this app-clock instant instead of the live timeline,
    /// so the rendered phase matches the recorded scenario clock. Production leaves it nil.
    var renderDate: Date?
    /// Render-check only (#138): draw this pack (e.g. with placeholder clips) instead of the model's.
    var packOverride: MascotPack?

    private var pack: MascotPack? { packOverride ?? model.pack }

    var body: some View {
        let reduced = model.effectiveReducedMotion
        let layout = model.layout(model.settings.mascotSize)
        Group {
            if let renderDate {
                scene(at: renderDate, reduced: reduced, layout: layout)
            } else if reduced {
                scene(at: model.clock(), reduced: true, layout: layout)
            } else {
                switch redraw {
                case .continuous(let fps):
                    TimelineView(.animation(minimumInterval: 1 / fps)) { context in
                        scene(at: context.date.addingTimeInterval(model.clockOffset), reduced: false, layout: layout)
                    }
                case .idleFrames(let schedule):
                    // A new schedule (mood, pack timing) starts a fresh timeline from now.
                    TimelineView(schedule) { context in
                        scene(at: context.date.addingTimeInterval(model.clockOffset), reduced: false, layout: layout)
                    }
                    .id(schedule)
                }
            }
        }
        .frame(width: layout.panelWidth, height: layout.panelSize.height)
        // VoiceOver sees the panel's container as one button (see MascotContainerView).
        .accessibilityHidden(true)
    }

    /// How the live (not reduced) mascot redraws (#166).
    enum Redraw: Equatable {
        /// 30 fps while a gesture plays (smooth lean); 8 fps for motion between frames (the
        /// placeholder's breathing, doze's effects, the release spring).
        case continuous(fps: Double)
        /// Only when the idle loop changes frame; a held mood (attention, urgent) never redraws.
        case idleFrames(IdleFrameSchedule)
    }

    static let gestureFPS = 30.0
    static let motionFPS = 8.0
    /// Frame sequences (#138) change image about every 70 ms, so their clips draw at 60 fps (30 would
    /// show each frame for 67 or 100 ms in turn); slower frame clips keep 30.
    static let fastClipFPS = 60.0

    /// Pure, so tests can pin the idle choice: the gesture condition is the one 30 fps always used.
    static func redraw(pack: Bool, clip: EventClipQueue.Clip?, stage: ClipStage, markerBursting: Bool,
                       dozeHasClip: Bool, now: Date, idle: IdleFrameSchedule, fastClips: Bool = false) -> Redraw {
        if clip != nil || stage.scheduled != nil || stage.dragStart != nil || markerBursting {
            return .continuous(fps: fastClips && (clip != nil || stage.scheduled != nil) ? fastClipFPS : gestureFPS)
        }
        let dozing = stage.dozeStart != nil && dozeHasClip
        if !pack || dozing || stage.springAngle(at: now) != 0 { return .continuous(fps: motionFPS) }
        return .idleFrames(idle)
    }

    private var redraw: Redraw {
        let now = model.clock()
        let pack = self.pack
        let library = packOverride.map { ClipLibrary(pack: $0) } ?? model.clipLibrary
        // During an incident a pack with an incident idle loop (#138) idles on that loop's frames.
        let incident = !model.accessories.isEmpty && library.has(.incidentIdle)
        let idle = incident
            // The helmet loop stands in for every mood during an incident, so it redraws like idle.
            ? IdleFrameSchedule(mood: .idle, clockOffset: model.clockOffset,
                                durationsMs: library.durationsMs[.incidentIdle] ?? [], minimumMs: FrameClock.minimumClipDurationMs)
            : IdleFrameSchedule(mood: model.mascotState, clockOffset: model.clockOffset,
                                durationsMs: pack?.manifest.states[MascotState.idle.rawValue]?.durationMs ?? [])
        return Self.redraw(pack: pack != nil, clip: model.activeClip, stage: model.clipStage,
                           markerBursting: model.markerPhase(at: now, reduced: false).time != nil,
                           dozeHasClip: (packOverride.map { ClipLibrary(pack: $0) } ?? model.clipLibrary).has(.doze),
                           now: now, idle: idle,
                           fastClips: library.hasFastClips)
    }

    /// Art and labels for one instant, from one pose, so the count never lags the frame it tracks
    /// (near-touch #28): DEMO is fixed; the count sits at the left of its "99+" slot and moves down
    /// so its capsule stays `MascotLayout.nearTouchGap` above this pose's art.
    private func scene(at date: Date, reduced: Bool, layout: MascotLayout) -> some View {
        let pose = poseOverride ?? pose(at: date, reduced: reduced)
        let badge = badgeOverride ?? model.mascotBadge
        let countWidth = badge.map { layout.count.width(text: Tag.textWidth($0, role: .count, size: layout.count.fontSize)) }
        let offset = countWidth.flatMap { width in
            (packOverride.map { $0.contour(for: pose) } ?? model.contour(for: pose)).map {
                layout.countOffset(contour: $0, width: width, leaning: pose.angle != 0, displayScale: displayScale)
            }
        } ?? 0
        let demo = layout.demoFrame
        return ZStack(alignment: .topLeading) {
            if let marker = model.incidentMarker, drawsMarker ?? (drawsArt && drawsLabels) {
                IncidentMarkerView(marker: marker, layout: layout,
                                   phase: model.markerPhase(at: date, reduced: reduced))
            }
            figure(pose: pose, date: date, reduced: reduced)
                .frame(width: layout.artSide, height: layout.artSide)
                // Art-layer lean about the ground anchor (#29); labels stay upright.
                .rotationEffect(.degrees(pose.angle),
                                anchor: UnitPoint(x: AttentionGesture.pivot.x / 256, y: AttentionGesture.pivot.y / 256))
                .offset(x: layout.artFrame.minX, y: layout.laneHeight)
                .opacity(drawsArt ? 1 : 0)
            if showsPlaceholderTag(pose) {
                placeholderTag(side: layout.artSide)
                    .frame(width: layout.artSide, height: layout.artSide, alignment: .topTrailing)
                    .offset(x: layout.artFrame.minX, y: layout.laneHeight)
            }
            // Engine effects (#138): world space, so they don't lean; never in reduced motion.
            if let pack, let clip = pose.clip, !reduced, drawsArt {
                let path = pack.imagePath(for: pose)
                let spray = pack.spray(clip: clip.id, elapsed: clip.elapsed)
                ClipEffectsView(particles: ClipEffects.particles(clip: clip.id, elapsed: clip.elapsed, head: pack.head(for: path),
                                                                 nozzle: spray?.nozzle ?? pack.nozzle(for: path), hand: pack.hand(for: path),
                                                                 sprayWindow: spray?.window),
                                side: layout.artSide)
                    .frame(width: layout.artSide, height: layout.artSide)
                    .offset(x: layout.artFrame.minX, y: layout.laneHeight)
                    .allowsHitTesting(false)
            }
            if model.isDemo, drawsLabels {
                Tag(text: PrivacyText.demoLabel.uppercased(), role: .demo, metrics: layout.demo)
                    .frame(width: demo.width, height: demo.height)
                    .offset(x: demo.minX, y: demo.minY)
            }
            if let badge, let countWidth, drawsLabels {
                Tag(text: badge, role: model.mascotState == .urgent ? .urgentCount : .count, metrics: layout.count)
                    .frame(width: countWidth, height: layout.count.height)
                    .offset(x: layout.countSlotX, y: offset)
            }
        }
        .frame(width: layout.panelWidth, height: layout.panelSize.height, alignment: .topLeading)
    }

    /// The mascot's spoken label: status first, then the privacy-aware summary.
    static func accessibilityLabel(_ model: AppModel) -> String {
        ([model.statusAccessibilityLabel] + model.summaryLines.dropFirst(model.isDemo ? 1 : 0))
            .joined(separator: ". ")
    }

    func pose(at date: Date, reduced: Bool) -> MascotPose {
        let pack = self.pack
        return MascotAnimator.pose(mood: model.mascotState, clip: model.activeClip, now: date, reducedMotion: reduced,
                                   idleEpoch: .distantPast, gesture: pack?.attentionGesture, stage: model.clipStage,
                                   library: packOverride.map { ClipLibrary(pack: $0) } ?? model.clipLibrary,
                                   accessories: model.accessories) { state in
            pack?.manifest.states[state.rawValue]?.durationMs ?? PlaceholderFigure.durationsMs(state)
        }
    }

    /// "PH" on any clip, held pose or accessory synthesized until the art lands (#138), so a
    /// placeholder is never mistaken for final art.
    private func showsPlaceholderTag(_ pose: MascotPose) -> Bool {
        guard let pack, !pack.placeholderClips.isEmpty else { return false }
        return pose.clip.map { pack.placeholderClips.contains($0.id) } == true
            || pose.accessories.contains(where: pack.placeholderClips.contains)
    }

    private func placeholderTag(side: CGFloat) -> some View {
        Text("PH")
            .font(.system(size: max(7, side * 0.07), weight: .heavy, design: .monospaced))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 2)
            .background(Color(red: 0.75, green: 0, blue: 0.6))
            .padding(side * 0.06)
    }

    @ViewBuilder
    private func figure(pose: MascotPose, date: Date, reduced: Bool) -> some View {
        if let pack {
            PackFigure(pack: pack, pose: pose)
        } else {
            PlaceholderFigure(pose: pose, date: date, reduced: reduced)
        }
    }
}

/// Timeline entries at the idle loop's frame changes only (#166): the pose between them is the same
/// image, so redrawing at a fixed rate repainted identical frames. Dates are wall clock; the loop
/// runs on the app clock, `clockOffset` ahead.
struct IdleFrameSchedule: TimelineSchedule, Hashable {
    var mood: MascotState
    var clockOffset: TimeInterval
    var durationsMs: [Int]
    /// The incident idle loop (#138) plays clip-length frames.
    var minimumMs = FrameClock.minimumDurationMs

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        return AnyIterator {
            defer { next = next.flatMap(change(after:)) }
            return next
        }
    }

    /// The next frame change after `date`, on the same clock and epoch `MascotView.pose` uses.
    func change(after date: Date) -> Date? {
        MascotAnimator.nextIdleFrameChange(after: date.addingTimeInterval(clockOffset), mood: mood, reducedMotion: false,
                                           idleEpoch: .distantPast, minimumMs: minimumMs) { _ in durationsMs }
            .map { $0.addingTimeInterval(-clockOffset) }
    }
}

/// A lane capsule (design spec #28): DEMO in SF bold, the count in SF semibold with monospaced
/// digits; width `max(height, text + 2 × padding)`, never truncated. Fills are appearance-aware
/// with at least 4.5:1 text contrast; urgency is also stated in words elsewhere.
struct Tag: View {
    enum Role { case demo, count, urgentCount }

    /// Native text width of a label at its font (for the capsule width the count tracks with).
    /// Memoized: the mascot asks on every frame it draws, and text measurement was most of a frame (#166).
    @MainActor static func textWidth(_ text: String, role: Role, size: CGFloat) -> CGFloat {
        let key = WidthKey(text: text, demo: role == .demo, size: size)
        if let width = widths[key] { return width }
        let font = role == .demo ? NSFont.systemFont(ofSize: size, weight: .bold)
                                 : NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        // Badges are short and sizes few; a full cache (a size slider dragged end to end) starts over.
        if widths.count >= 512 { widths.removeAll() }
        widths[key] = width
        return width
    }

    private struct WidthKey: Hashable { var text: String; var demo: Bool; var size: CGFloat }
    @MainActor private static var widths: [WidthKey: CGFloat] = [:]

    let text: String
    let role: Role
    let metrics: MascotLayout.Capsule
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Text(text)
            .font(role == .demo
                  ? .system(size: metrics.fontSize, weight: .bold)
                  : .system(size: metrics.fontSize, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(dark ? Color.black : Color.white)
            .padding(.horizontal, metrics.padding)
            .frame(minWidth: metrics.height, minHeight: metrics.height, maxHeight: metrics.height)
            .background(Capsule().fill(fill(dark: dark)))
    }

    private func fill(dark: Bool) -> Color {
        switch role {
        case .demo: return dark ? Color(white: 0.78) : Color(white: 0.32)
        case .count: return dark ? Color(red: 0.61, green: 0.78, blue: 1.0) : Color(red: 0.0, green: 0.31, blue: 0.69)
        case .urgentCount: return dark ? Color(red: 1.0, green: 0.71, blue: 0.67) : Color(red: 0.70, green: 0.15, blue: 0.12)
        }
    }
}

/// Temporary native placeholder, used when no valid pack is available. Purely vector.
struct PlaceholderFigure: View {
    let pose: MascotPose
    let date: Date
    let reduced: Bool

    /// Frame timings mirroring the pack: idle blink loop, one-shot hop for event clips.
    static func durationsMs(_ state: MascotState) -> [Int] {
        state == .idle ? [4000, 150] : [300, 300, 1400]
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let t = date.timeIntervalSinceReferenceDate
            let breathe = reduced ? 1.0 : 1.0 + 0.025 * sin(t * 2 * .pi / 3.5)
            let blinking = pose.state == .idle && pose.frame == 1
            let hop = hopOffset(side: side)
            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: side * 0.55, height: side * 0.08)
                    .offset(y: side * 0.40)
                RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                    .fill(bodyColor.gradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.35), lineWidth: max(1, side * 0.02))
                    )
                    .frame(width: side * 0.66, height: side * 0.60 * breathe)
                    .overlay(face(side: side, blinking: blinking))
                    .offset(y: side * 0.08 - hop)
                if let symbol {
                    Text(symbol)
                        .font(.system(size: side * 0.2, weight: .heavy, design: .rounded))
                        .foregroundStyle(pose.state == .urgent ? Color.red : Color.orange)
                        .offset(x: side * 0.28, y: -side * 0.32 - hop)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var bodyColor: Color {
        switch pose.state {
        case .idle: return Color(red: 0.55, green: 0.42, blue: 0.85)
        case .attention: return Color(red: 0.98, green: 0.70, blue: 0.25)
        case .urgent: return Color(red: 0.90, green: 0.33, blue: 0.33)
        }
    }

    /// Static cue for attention/urgent so meaning never depends on motion or colour alone.
    private var symbol: String? {
        switch pose.state {
        case .idle: return nil
        case .attention: return "✦"
        case .urgent: return "!"
        }
    }

    /// One hop over the clip's first 0.6 s, then still.
    private func hopOffset(side: CGFloat) -> CGFloat {
        guard let elapsed = pose.clipElapsed, elapsed >= 0, elapsed < 0.6 else { return 0 }
        return side * 0.12 * sin(elapsed / 0.6 * .pi)
    }

    private func face(side: CGFloat, blinking: Bool) -> some View {
        HStack(spacing: side * 0.14) {
            ForEach(0..<2, id: \.self) { _ in
                Capsule()
                    .fill(Color.white)
                    .frame(width: side * 0.08, height: blinking ? side * 0.015 : side * 0.12)
            }
        }
        .offset(y: -side * 0.04)
    }
}

/// Renders frames from a validated pack. The art is continuous-tone, so it is scaled
/// smoothly and uniformly; the square canvas fills the square panel, keeping the anchor fixed.
struct PackFigure: View {
    let pack: MascotPack
    let pose: MascotPose

    var body: some View {
        let path = pack.imagePath(for: pose)
        let image = path.flatMap { PackImageCache.shared.image($0, in: pack) }
        // The common case (no accessory) is exactly the single image it was before #138: no extra
        // layout work on the idle timeline.
        if pose.accessories.isEmpty {
            if let image { layer(image) }
        } else {
            ZStack {
                if let image { layer(image) }
                accessories(path: path)
            }
        }
    }

    /// Accessories sit above the art, below the labels, and lean with it (#138). Authored at the
    /// default head point; a frame's own head point moves them.
    private func accessories(path: String?) -> some View {
        GeometryReader { geo in
            let scale = min(geo.size.width, geo.size.height) / CGFloat(MascotPack.canvasSize)
            let offset = pack.headOffset(for: path)
            ForEach(pose.accessories, id: \.self) { id in
                if let image = pack.manifest.accessorySpec(id).flatMap({ PackImageCache.shared.image($0.image, in: pack) }) {
                    layer(image).offset(x: offset.x * scale, y: offset.y * scale)
                }
            }
        }
    }

    private func layer(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .interpolation(.high)
            .antialiased(true)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

/// Engine effect particles (#138), drawn in code until the 64×64 sprites land. Positions are canvas
/// pixels scaled to the art square; effects never reach the label lane.
struct ClipEffectsView: View {
    let particles: [ClipEffects.Particle]
    let side: CGFloat

    var body: some View {
        let scale = side / CGFloat(MascotPack.canvasSize)
        ZStack(alignment: .topLeading) {
            ForEach(Array(particles.enumerated()), id: \.offset) { _, particle in
                sprite(particle.kind)
                    .frame(width: particle.size * scale, height: particle.size * scale)
                    .opacity(particle.opacity)
                    .position(x: particle.x * scale, y: particle.y * scale)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
    }

    @ViewBuilder
    private func sprite(_ kind: ClipEffects.Kind) -> some View {
        switch kind {
        case .mist: Circle().fill(Color.white.opacity(0.75)).overlay(Circle().stroke(Color.cyan.opacity(0.6)))
        case .smoke: Circle().fill(Color.gray.opacity(0.5))
        case .sparkle: Image(systemName: "sparkle").resizable().foregroundStyle(Color.yellow)
        case .z: Text("z").font(.system(size: 100, weight: .bold, design: .rounded)).minimumScaleFactor(0.01)
            .foregroundStyle(Color.secondary)
        }
    }
}

/// Decoded frames keyed by pack directory and frame path, decoded from the bytes
/// validated at load: no disk I/O at all after validation, and none per tick. State frames and
/// accessories stay resident; clip and held frames (#138, up to ~60 per pack) are kept to at most
/// `clipLimit`, oldest dropped first, so a full pack doesn't hold ~15 MiB of decoded frames.
@MainActor
final class PackImageCache {
    static let shared = PackImageCache()
    static let clipLimit = 24
    private var images: [String: NSImage] = [:]
    private var clipOrder: [String] = []

    func image(_ path: String, in pack: MascotPack) -> NSImage? {
        let key = pack.directory.path + "/" + path
        if let cached = images[key] { return cached }
        let image = pack.imageData[path].flatMap(NSImage.init(data:))
        images[key] = image
        if !Self.isResident(path, in: pack) {
            clipOrder.append(key)
            while clipOrder.count > Self.clipLimit { images.removeValue(forKey: clipOrder.removeFirst()) }
        }
        return image
    }

    var clipImageCount: Int { clipOrder.count }

    private static func isResident(_ path: String, in pack: MascotPack) -> Bool {
        MascotState.allCases.contains { state in
            pack.manifest.states[state.rawValue].map { $0.frames.contains(path) || $0.staticFallback == path } ?? false
        } || (pack.manifest.accessories ?? [:]).values.contains { $0.image == path }
    }
}
