import AppKit
import GitHubPetCore
import SwiftUI

/// Draws the mascot: a validated artwork pack when one is loaded, otherwise the
/// native placeholder. Reduced motion pins a static pose; text and badge never move.
struct MascotView: View {
    @ObservedObject var model: AppModel
    @State private var stateSince = Date()

    var body: some View {
        let reduced = model.effectiveReducedMotion
        ZStack(alignment: .topTrailing) {
            if reduced {
                figure(at: stateSince, reduced: true)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { context in
                    figure(at: context.date, reduced: false)
                }
            }
            if let badge = model.badge {
                Text(badge)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(model.mascotState == .urgent ? Color.red : Color.accentColor))
                    .padding(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.mascotState) { _ in stateSince = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.summaryLines.joined(separator: ". "))
    }

    @ViewBuilder
    private func figure(at date: Date, reduced: Bool) -> some View {
        if let pack = model.pack {
            PackFigure(pack: pack, state: model.mascotState, date: date, stateSince: stateSince, reduced: reduced)
        } else {
            PlaceholderFigure(state: model.mascotState, clip: model.activeClip, date: date, reduced: reduced)
        }
    }
}

/// Temporary native placeholder until the designer's pack lands. Purely vector, no artwork.
struct PlaceholderFigure: View {
    let state: MascotState
    let clip: EventClipQueue.Clip?
    let date: Date
    let reduced: Bool

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let t = date.timeIntervalSinceReferenceDate
            let breathe = reduced ? 1.0 : 1.0 + 0.025 * sin(t * 2 * .pi / 3.5)
            let blinking = !reduced && t.truncatingRemainder(dividingBy: 4.2) < 0.15
            let hop = reduced ? 0.0 : hopOffset(side: side)
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
                if let symbol = clipSymbol {
                    Text(symbol)
                        .font(.system(size: side * 0.2, weight: .heavy, design: .rounded))
                        .foregroundStyle(state == .urgent ? Color.red : Color.orange)
                        .offset(x: side * 0.28, y: -side * 0.32 - hop)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var bodyColor: Color {
        switch state {
        case .idle: return Color(red: 0.55, green: 0.42, blue: 0.85)
        case .attention: return Color(red: 0.98, green: 0.70, blue: 0.25)
        case .urgent: return Color(red: 0.90, green: 0.33, blue: 0.33)
        }
    }

    /// Shown for the whole one-shot clip and as a static cue in attention/urgent states,
    /// so the meaning never depends on motion or colour alone.
    private var clipSymbol: String? {
        if clip != nil { return clip?.event.severity == .critical ? "!" : "✦" }
        switch state {
        case .idle: return nil
        case .attention: return "✦"
        case .urgent: return "!"
        }
    }

    /// One hop over the clip's first 0.6 s, then still for the rest of it.
    private func hopOffset(side: CGFloat) -> CGFloat {
        guard let clip else { return 0 }
        let elapsed = EventClipQueue.clipDuration - clip.endsAt.timeIntervalSince(date)
        guard elapsed >= 0, elapsed < 0.6 else { return 0 }
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

/// Renders frames from a validated pack, nearest-neighbour, anchored bottom-centre.
struct PackFigure: View {
    let pack: MascotPack
    let state: MascotState
    let date: Date
    let stateSince: Date
    let reduced: Bool

    var body: some View {
        if let image = currentImage() {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private func currentImage() -> NSImage? {
        guard let spec = pack.manifest.states[state.rawValue] else { return nil }
        if reduced { return PackImageCache.shared.image(pack.staticFallbackURL(for: state)) }
        let elapsed = Int(date.timeIntervalSince(stateSince) * 1000)
        let index = FrameClock.frameIndex(durationsMs: spec.durationMs, loop: spec.loop,
                                          elapsedMs: elapsed, reducedMotion: false)
        let urls = pack.frameURLs(for: state)
        return PackImageCache.shared.image(urls.indices.contains(index) ? urls[index] : nil)
    }
}

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
