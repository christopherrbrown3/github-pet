import AppKit
import GitHubPetCore
import SwiftUI

/// Draws the mascot: a validated artwork pack when one is loaded, otherwise the
/// native placeholder. Timing comes from `MascotAnimator` on the app clock, so QA clock
/// hooks drive animation too. Reduced motion pins a static pose; text and badge never move.
struct MascotView: View {

    @ObservedObject var model: AppModel
    /// Render-check only: draw a fixed pose and badge, and only some layers.
    var poseOverride: MascotPose?
    var badgeOverride: String?
    var drawsArt = true
    var drawsLabels = true

    var body: some View {
        let reduced = model.effectiveReducedMotion
        let layout = model.layout(model.settings.mascotSize)
        Group {
            if reduced {
                scene(at: model.clock(), reduced: true, layout: layout)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { context in
                    scene(at: context.date.addingTimeInterval(model.clockOffset), reduced: false, layout: layout)
                }
            }
        }
        .frame(width: layout.panelWidth, height: layout.panelSize.height)
        // VoiceOver sees the panel's container as one button (see MascotContainerView).
        .accessibilityHidden(true)
    }

    /// Art and labels for one instant, from one pose, so the count never lags the frame it tracks
    /// (near-touch #28): DEMO is fixed; the count sits at the left of its "99+" slot and moves down
    /// so its capsule stays `MascotLayout.nearTouchGap` above this pose's art.
    private func scene(at date: Date, reduced: Bool, layout: MascotLayout) -> some View {
        let pose = poseOverride ?? pose(at: date, reduced: reduced)
        let badge = badgeOverride ?? model.badge
        let countWidth = badge.map { layout.count.width(text: Tag.textWidth($0, role: .count, size: layout.count.fontSize)) }
        let offset = countWidth.flatMap { width in
            model.contour(for: pose).map { layout.countOffset(contour: $0, width: width) }
        } ?? 0
        let demo = layout.demoFrame
        return ZStack(alignment: .topLeading) {
            figure(pose: pose, date: date, reduced: reduced)
                .frame(width: layout.artSide, height: layout.artSide)
                .offset(x: layout.artFrame.minX, y: layout.laneHeight)
                .opacity(drawsArt ? 1 : 0)
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

    private func pose(at date: Date, reduced: Bool) -> MascotPose {
        MascotAnimator.pose(mood: model.mascotState, clip: model.activeClip, now: date, reducedMotion: reduced,
                            idleEpoch: .distantPast) { state in
            model.pack?.manifest.states[state.rawValue]?.durationMs ?? PlaceholderFigure.durationsMs(state)
        }
    }

    @ViewBuilder
    private func figure(pose: MascotPose, date: Date, reduced: Bool) -> some View {
        if let pack = model.pack {
            PackFigure(pack: pack, pose: pose)
        } else {
            PlaceholderFigure(pose: pose, date: date, reduced: reduced)
        }
    }
}

/// A lane capsule (design spec #28): DEMO in SF bold, the count in SF semibold with monospaced
/// digits; width `max(height, text + 2 × padding)`, never truncated. Fills are appearance-aware
/// with at least 4.5:1 text contrast; urgency is also stated in words elsewhere.
struct Tag: View {
    enum Role { case demo, count, urgentCount }

    /// Native text width of a label at its font (for the capsule width the count tracks with).
    static func textWidth(_ text: String, role: Role, size: CGFloat) -> CGFloat {
        let font = role == .demo ? NSFont.systemFont(ofSize: size, weight: .bold)
                                 : NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

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
        if let image = currentImage() {
            Image(nsImage: image)
                .interpolation(.high)
                .antialiased(true)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private func currentImage() -> NSImage? {
        guard let frame = pose.frame else {
            return PackImageCache.shared.image(pack.staticFallbackURL(for: pose.state))
        }
        let urls = pack.frameURLs(for: pose.state)
        return PackImageCache.shared.image(urls.indices.contains(frame) ? urls[frame] : nil)
    }
}

/// Decoded frames for the single loaded pack (12 images, about 3 MB): no disk I/O per tick.
@MainActor
final class PackImageCache {
    static let shared = PackImageCache()
    private var images: [URL: NSImage] = [:]

    func image(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let cached = images[url] { return cached }
        let image = NSImage(contentsOf: url)
        images[url] = image
        return image
    }
}
