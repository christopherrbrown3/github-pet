import GitHubPetCore
import SwiftUI

/// The incident marker (#37) behind the mascot art, drawn natively from design's spec
/// (`IncidentMarkerSpec`, docs/design/incidents/incident-marker.json; reference maths in
/// render-incident-preview.swift). It works in the 256-unit art canvas (top-left origin, y down),
/// ground-anchored and upright: it does not lean with the #29 gesture. Layers back to front:
/// beacon sweep, smoke, flames, siren. As a safety net every layer is also clipped to
/// `IncidentMarker.frame(in:)`, so nothing can reach the count, quality or DEMO labels.
///
/// The settle crossfades parameters (sweep angle and alpha, flame height and lean) toward the
/// static frame rather than blending two images, so opaque layers never dip.
struct IncidentMarkerView: View {
    let marker: IncidentMarker
    let layout: MascotLayout
    let phase: IncidentMarker.Phase
    var spec: IncidentMarkerSpec = .standard
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let art = layout.artFrame
        let slot = IncidentMarker.frame(in: layout)
        let clipTop = art.maxY - slot.maxY   // slot top in art-local, top-left points
        Canvas { context, size in
            let scale = size.width / 256
            context.clip(to: Path(CGRect(x: 0, y: clipTop, width: size.width, height: slot.height)))
            context.scaleBy(x: scale, y: scale)
            let unitsPerPoint = 1 / scale
            let layers = IncidentMarker.layers(marker.tier, spec: spec)
            if layers.contains(.beaconSweep) { layer(.beaconSweep, &context) { drawSweep(&$0) } }
            if layers.contains(.smoke) { layer(.smoke, &context) { drawSmoke(&$0) } }
            if layers.contains(.flames) { layer(.flames, &context) { drawFlames(&$0, unitsPerPoint: unitsPerPoint) } }
            if layers.contains(.siren) { layer(.siren, &context) { drawSiren(&$0, unitsPerPoint: unitsPerPoint) } }
        }
        .frame(width: art.width, height: art.height)
        .offset(x: art.minX, y: layout.laneHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Each layer fades as one (a transparency layer at its fade-in opacity).
    private func layer(_ kind: IncidentMarker.Layer, _ context: inout GraphicsContext,
                       draw: (inout GraphicsContext) -> Void) {
        let opacity = phase.opacity(kind)
        guard opacity > 0 else { return }
        context.drawLayer { layer in
            layer.opacity = opacity
            draw(&layer)
        }
    }

    private var time: Double { phase.time ?? 0 }
    private var weight: Double { phase.time == nil ? 1 : phase.staticWeight }

    private func color(_ token: String, alpha: Double = 1) -> Color {
        let palette = colorScheme == .dark ? spec.palette.dark : spec.palette.light
        guard let entry = palette[token], let rgb = entry.rgb else { return .clear }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: entry.alpha * alpha)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    // MARK: Beacon sweep

    private func drawSweep(_ context: inout GraphicsContext) {
        let sweep = spec.beaconSweep
        let center = CGPoint(x: sweep.center[0], y: sweep.center[1])
        let animated = (time * 1000).truncatingRemainder(dividingBy: sweep.periodMs) / sweep.periodMs * 360 - 90
        // Shortest way round to the static angle during the settle.
        var delta = (spec.static.beaconAngleDeg - animated).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        let angle = animated + delta * weight
        let alpha = lerp(sweep.alpha, spec.static.beaconAlpha, weight)
        let (width, feather) = (sweep.widthDeg, sweep.edgeFeatherDeg)
        let steps = 24
        for step in 0..<steps {
            let a0 = angle - width / 2 - feather + (width + 2 * feather) * Double(step) / Double(steps)
            let a1 = angle - width / 2 - feather + (width + 2 * feather) * Double(step + 1) / Double(steps)
            let edge = min(1, max(0, (width / 2 + feather - abs((a0 + a1) / 2 - angle)) / feather))
            var wedge = Path()
            wedge.move(to: center)
            wedge.addArc(center: center, radius: sweep.radius, startAngle: .degrees(a0), endAngle: .degrees(a1),
                         clockwise: false)
            wedge.closeSubpath()
            let tint = color("incident.beacon", alpha: alpha * edge)
            context.fill(wedge, with: .radialGradient(Gradient(colors: [tint, tint.opacity(0)]), center: center,
                                                       startRadius: 0, endRadius: sweep.radius))
        }
    }

    // MARK: Smoke

    private func drawSmoke(_ context: inout GraphicsContext) {
        let smoke = spec.smoke
        let override = spec.sizeOverride(artSide: Double(layout.artSide))
        let minRadius = override?.smokeMinRadius ?? 0
        func puff(_ cx: Double, _ cy: Double, _ r: Double, _ alpha: Double) {
            guard alpha > 0 else { return }
            let tint = color(smoke.color, alpha: alpha)
            for lobe in smoke.puffCluster {
                let lobeRadius = r * lobe.rScale
                let center = CGPoint(x: cx + lobe.dx * r, y: cy + lobe.dy * r)
                let gradient = Gradient(stops: [.init(color: tint, location: 0), .init(color: tint, location: smoke.softEdgeStart),
                                                .init(color: tint.opacity(0), location: 1)])
                context.fill(Path(ellipseIn: CGRect(x: center.x - lobeRadius, y: center.y - lobeRadius,
                                                    width: 2 * lobeRadius, height: 2 * lobeRadius)),
                             with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: lobeRadius))
            }
        }
        if weight < 1 {
            let life = smoke.lifeMs / 1000, stagger = smoke.staggerMs / 1000
            let count = override?.smokeCountPerEmitter ?? smoke.countPerEmitter
            for emitter in smoke.emitters {
                for k in 0..<count {
                    let age = (time + emitter.phase * stagger + Double(k) * stagger).truncatingRemainder(dividingBy: life) / life
                    let p = IncidentMarker.ease(age, smoke.curve.motion)
                    let r = max(minRadius, lerp(smoke.radius[0], smoke.radius[1], p))
                    puff(emitter.x + emitter.dx * p, emitter.y + emitter.dy * p, r,
                         lerp(smoke.alphaScale[0], smoke.alphaScale[1], age) * (1 - weight))
                }
            }
        }
        if weight > 0 {
            for still in smoke.static {
                puff(still.cx, still.cy, max(minRadius, still.r), spec.static.smokeAlphaScale * weight)
            }
        }
    }

    // MARK: Flames

    private func drawFlames(_ context: inout GraphicsContext, unitsPerPoint: CGFloat) {
        let flames = spec.flames
        let override = spec.sizeOverride(artSide: Double(layout.artSide))
        let nested = flames.nestedScales.filter { override?.nestedScaleTokens.contains($0.token) ?? true }
        let (c1, c2, tipLean) = (flames.shape.leftControl1, flames.shape.leftControl2, flames.shape.tipLeanFactor)
        let tongues = spec.tongues(marker.tier, artSide: Double(layout.artSide))
        for (index, scale) in nested.enumerated() {
            var path = Path()
            for tongue in tongues {
                let (animatedHeight, animatedLean) = flicker(tongue)
                let h = lerp(animatedHeight, tongue.height * spec.static.flameHeightFactor, weight) * scale.height
                let lean = lerp(animatedLean, spec.static.flameLean, weight) * scale.height
                let w = tongue.halfWidth * scale.width
                let (cx, baseY) = (tongue.cx, flames.baseY)
                path.move(to: CGPoint(x: cx - w, y: baseY))
                path.addCurve(to: CGPoint(x: cx + lean, y: baseY - h),
                              control1: CGPoint(x: cx + c1[0] * w, y: baseY - c1[1] * h),
                              control2: CGPoint(x: cx + c2[0] * w + lean * tipLean, y: baseY - c2[1] * h))
                path.addCurve(to: CGPoint(x: cx + w, y: baseY),
                              control1: CGPoint(x: cx - c2[0] * w + lean * tipLean, y: baseY - c2[1] * h),
                              control2: CGPoint(x: cx - c1[0] * w, y: baseY - c1[1] * h))
                path.closeSubpath()
            }
            context.fill(path, with: .color(color(scale.token)))
            if index == 0 {
                context.stroke(path, with: .color(color(flames.rim.token)), lineWidth: flames.rim.widthPt * unitsPerPoint)
            }
        }
    }

    private func flicker(_ tongue: IncidentMarkerSpec.Tongue) -> (height: Double, lean: Double) {
        let f = spec.flames.flicker
        var wave = f.waveOffset
        for w in f.waves { wave += w.amp * sin(2 * .pi * (time / w.periodS + w.phaseMul * tongue.phase)) }
        return (tongue.height * (f.heightBase + f.heightAmp * wave),
                f.leanUnits * sin(2 * .pi * (time / f.leanPeriodS + tongue.phase)))
    }

    // MARK: Siren (same geometry as assets/mascots/mona-pet-v1/ui/incident-siren.svg)

    private func drawSiren(_ context: inout GraphicsContext, unitsPerPoint: CGFloat) {
        let siren = spec.siren
        if spec.static.sirenGlow || phase.time != nil {
            let center = CGPoint(x: siren.glow.center[0], y: siren.glow.center[1])
            let tint = color("incident.beacon", alpha: siren.glow.alpha)
            let r = siren.glow.radius
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                         with: .radialGradient(Gradient(colors: [tint, tint.opacity(0)]), center: center,
                                               startRadius: 0, endRadius: r))
        }
        let outlineWidth = max(siren.outline.widthUnits, siren.outline.minWidthPt * unitsPerPoint)
        let d = siren.dome.rect, r = CGRect(x: d[0], y: d[1], width: d[2], height: d[3]), top = siren.dome.topRadius
        var dome = Path()
        dome.move(to: CGPoint(x: r.minX, y: r.maxY))
        dome.addLine(to: CGPoint(x: r.minX, y: r.minY + top))
        dome.addArc(center: CGPoint(x: r.midX, y: r.minY + top), radius: top, startAngle: .degrees(180),
                    endAngle: .degrees(0), clockwise: false)
        dome.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        dome.closeSubpath()
        context.drawLayer { inner in
            inner.clip(to: dome)
            inner.fill(Path(r), with: .linearGradient(
                Gradient(colors: [color("incident.siren.dome"), color("incident.siren.domeShade")]),
                startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
            let b = siren.dome.band.rect
            inner.fill(Path(CGRect(x: b[0], y: b[1], width: b[2], height: b[3])), with: .color(color("incident.siren.domeShade")))
            let g = siren.gloss.ellipse
            inner.fill(Path(ellipseIn: CGRect(x: g.cx - g.rx, y: g.cy - g.ry, width: 2 * g.rx, height: 2 * g.ry)),
                       with: .color(color("incident.siren.gloss")))
        }
        let outline = color("incident.siren.outline")
        context.stroke(dome, with: .color(outline), style: StrokeStyle(lineWidth: outlineWidth, lineJoin: .round))
        let b = siren.base.rect
        let base = Path(roundedRect: CGRect(x: b[0], y: b[1], width: b[2], height: b[3]), cornerRadius: siren.base.cornerRadius)
        context.fill(base, with: .color(color("incident.siren.base")))
        context.stroke(base, with: .color(outline), style: StrokeStyle(lineWidth: outlineWidth, lineJoin: .round))
    }
}
