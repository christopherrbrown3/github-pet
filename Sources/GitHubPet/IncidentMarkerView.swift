import GitHubPetCore
import SwiftUI

/// Placeholder incident marker (#37), drawn behind the mascot art until design's final layers land
/// (docs/design/incidents). Works in the design's 256-unit art canvas (top-left origin, y down),
/// ground-anchored and upright (it does not lean with the #29 gesture). Every layer is clipped to
/// `IncidentMarker.frame(in:)`, so it never reaches the count, quality or DEMO labels.
///
/// Tiers: minor = siren beacon; major = beacon and flames; critical = beacon, flames and smoke.
/// `elapsed` is the time into the ~6 s burst; nil draws the one static frame (Reduce Motion, quiet
/// hours, snooze, or no burst playing).
struct IncidentMarkerView: View {
    let marker: IncidentMarker
    let layout: MascotLayout
    let elapsed: TimeInterval?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let art = layout.artFrame
        let slot = IncidentMarker.frame(in: layout)
        // Slot in art-local, top-left coordinates.
        let clipTop = art.maxY - slot.maxY
        Canvas { context, size in
            let scale = size.width / 256
            context.clip(to: Path(CGRect(x: 0, y: clipTop, width: size.width, height: slot.height)))
            context.scaleBy(x: scale, y: scale)
            let t = elapsed ?? 0
            if marker.tier == .critical { drawSmoke(&context, t: t) }
            if marker.tier >= .major { drawFlames(&context, t: t, tall: marker.tier == .critical) }
            drawBeacon(&context, t: t, scale: scale)
        }
        .frame(width: art.width, height: art.height)
        .offset(x: art.minX, y: layout.laneHeight)
        .allowsHitTesting(false)
    }

    private var dark: Bool { colorScheme == .dark }

    private func drawBeacon(_ context: inout GraphicsContext, t: TimeInterval, scale: CGFloat) {
        let center = CGPoint(x: 28, y: 214)
        // Sweep: rotates once per 1.2 s during a burst; a fixed angle otherwise.
        let angle = Angle.degrees(-60 + (elapsed == nil ? 0 : t / 1.2 * 360))
        var wedge = Path()
        wedge.move(to: center)
        wedge.addArc(center: center, radius: 120, startAngle: angle - .degrees(18), endAngle: angle + .degrees(18),
                     clockwise: false)
        wedge.closeSubpath()
        context.fill(wedge, with: .color(Color(red: 1, green: 0.78, blue: 0.2).opacity(dark ? 0.30 : 0.38)))
        let base = CGRect(x: center.x - 16, y: center.y + 6, width: 32, height: 10)
        context.fill(Path(roundedRect: base, cornerRadius: 3), with: .color(dark ? Color(white: 0.55) : Color(white: 0.3)))
        let dome = Path(ellipseIn: CGRect(x: center.x - 12, y: center.y - 14, width: 24, height: 26))
        context.fill(dome, with: .color(Color(red: 0.93, green: 0.18, blue: 0.13)))
        context.stroke(dome, with: .color(.black.opacity(0.45)), lineWidth: 1 / scale)
    }

    private func drawFlames(_ context: inout GraphicsContext, t: TimeInterval, tall: Bool) {
        let baseY: CGFloat = 232
        let tongues: [(cx: CGFloat, halfWidth: CGFloat, height: CGFloat, phase: Double)] = [
            (62, 16, 52, 0.0), (88, 13, 40, 0.37), (168, 13, 42, 0.61), (194, 16, 54, 0.18),
        ]
        let layers: [(scale: CGFloat, color: Color)] = [
            (1.0, Color(red: 0.86, green: 0.20, blue: 0.08)),
            (0.7, Color(red: 0.98, green: 0.52, blue: 0.10)),
            (0.45, Color(red: 1.0, green: 0.86, blue: 0.35)),
        ]
        for tongue in tongues {
            let animated = elapsed != nil
            let wave = animated ? (sin(2 * .pi * (t / 0.42 + tongue.phase)) + sin(2 * .pi * (t / 0.61 + tongue.phase))) / 2 : 0
            let height = tongue.height * (tall ? 1.25 : 1) * CGFloat(0.86 + 0.14 * wave)
            let lean = animated ? CGFloat(6 * sin(2 * .pi * (t / 0.9 + tongue.phase))) : 0
            for layer in layers {
                context.fill(teardrop(cx: tongue.cx, baseY: baseY, halfWidth: tongue.halfWidth * layer.scale,
                                      height: height * layer.scale, lean: lean * layer.scale),
                             with: .color(layer.color))
            }
        }
    }

    private func teardrop(cx: CGFloat, baseY: CGFloat, halfWidth: CGFloat, height: CGFloat, lean: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: cx + lean, y: baseY - height))
        path.addQuadCurve(to: CGPoint(x: cx + halfWidth, y: baseY - halfWidth * 0.6),
                          control: CGPoint(x: cx + halfWidth * 0.9 + lean / 2, y: baseY - height * 0.55))
        path.addQuadCurve(to: CGPoint(x: cx - halfWidth, y: baseY - halfWidth * 0.6),
                          control: CGPoint(x: cx, y: baseY + halfWidth * 0.5))
        path.addQuadCurve(to: CGPoint(x: cx + lean, y: baseY - height),
                          control: CGPoint(x: cx - halfWidth * 0.9 + lean / 2, y: baseY - height * 0.55))
        path.closeSubpath()
        return path
    }

    private func drawSmoke(_ context: inout GraphicsContext, t: TimeInterval) {
        let gray = dark ? Color(white: 0.7) : Color(white: 0.45)
        for (index, x) in [CGFloat(54), 80, 176, 202].enumerated() {
            // Puffs rise and fade over 2 s during a burst; fixed puffs otherwise.
            let life = elapsed == nil ? 0.5 : (t / 2 + Double(index) * 0.27).truncatingRemainder(dividingBy: 1)
            let y = 170 - CGFloat(life) * 70
            let r = 10 + CGFloat(life) * 12
            context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                         with: .color(gray.opacity(0.55 * (1 - life * 0.7))))
        }
    }
}
