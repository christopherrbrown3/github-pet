// Design preview renderer for the #37 incident marker.
// Draws incident-marker.json with CoreGraphics behind a real mona-pet-v1 frame.
// These are design previews, not native MascotView renders.
//
// Usage: swift docs/design/incidents/render-incident-preview.swift <repo-root> <out-dir>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: render-incident-preview.swift <repo-root> <out-dir>") }
let root = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let spec = try JSONSerialization.jsonObject(
    with: Data(contentsOf: root.appendingPathComponent("docs/design/incidents/incident-marker.json"))) as! [String: Any]

func dict(_ o: Any?) -> [String: Any] { o as! [String: Any] }
func num(_ o: Any?) -> CGFloat { CGFloat((o as! NSNumber).doubleValue) }
func nums(_ o: Any?) -> [CGFloat] { (o as! [NSNumber]).map { CGFloat($0.doubleValue) } }

func loadImage(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

func color(_ appearance: String, _ token: String, alpha: CGFloat = 1) -> CGColor {
    let entry = dict(dict(dict(spec["palette"])[appearance])[token])
    let hex = (entry["hex"] as! String).dropFirst()
    let v = Int(hex, radix: 16)!
    return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                   blue: CGFloat(v & 255) / 255, alpha: num(entry["alpha"]) * alpha)
}

struct Tongue { var cx, halfWidth, height, phase: CGFloat }

func tongues(_ tier: String, size: Int) -> [Tongue] {
    let key = "flames.\(tier)"
    let list = (dict(spec["sizeOverrides"])["\(size)"] as? [String: Any])?[key] ?? dict(spec["flames"])[tier]
    return (list as! [[String: Any]]).map {
        Tongue(cx: num($0["cx"]), halfWidth: num($0["halfWidth"]), height: num($0["height"]), phase: num($0["phase"]))
    }
}

func flicker(_ t: Tongue, time: Double?) -> (height: CGFloat, lean: CGFloat) {
    let f = dict(dict(spec["flames"])["flicker"])
    guard let time else { return (t.height * num(dict(spec["static"])["flameHeightFactor"]), 0) }
    var wave = num(f["waveOffset"])
    for w in f["waves"] as! [[String: Any]] {
        wave += num(w["amp"]) * sin(2 * .pi * (CGFloat(time) / num(w["periodS"]) + num(w["phaseMul"]) * t.phase))
    }
    let h = t.height * (num(f["heightBase"]) + num(f["heightAmp"]) * wave)
    let lean = num(f["leanUnits"]) * sin(2 * .pi * (CGFloat(time) / num(f["leanPeriodS"]) + t.phase))
    return (h, lean)
}

func cubicBezierEase(_ x: CGFloat, _ c: [CGFloat]) -> CGFloat {
    // Solve x(s) for s by bisection, then return y(s).
    func b(_ s: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
        3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
    }
    var lo: CGFloat = 0, hi: CGFloat = 1
    for _ in 0..<40 { let mid = (lo + hi) / 2; if b(mid, c[0], c[2]) < x { lo = mid } else { hi = mid } }
    return b((lo + hi) / 2, c[1], c[3])
}

// Draws the marker for one tier into ctx, already transformed to canvas units.
// time == nil draws the static frame.
func drawMarker(_ ctx: CGContext, tier: String, appearance: String, size: Int, time: Double?, unitsPerPt: CGFloat) {
    let tierSpec = dict(dict(spec["tiers"])[tier])
    let staticSpec = dict(spec["static"])
    let timing = dict(spec["timing"])
    var envelope: CGFloat = 1
    if let time {
        let fadeIn = num(timing["fadeInMs"]) / 1000
        if CGFloat(time) < fadeIn { envelope = cubicBezierEase(CGFloat(time) / fadeIn, nums(timing["fadeInCurve"])) }
    }

    // Beacon sweep.
    let sweep = dict(spec["beaconSweep"])
    let center = nums(sweep["center"])
    let angle: CGFloat = time.map { CGFloat($0 * 1000).truncatingRemainder(dividingBy: num(sweep["periodMs"])) / num(sweep["periodMs"]) * 360 - 90 }
        ?? num(staticSpec["beaconAngleDeg"])
    let sweepAlpha = (time == nil ? num(staticSpec["beaconAlpha"]) : num(sweep["alpha"])) * envelope
    let width = num(sweep["widthDeg"]), feather = num(sweep["edgeFeatherDeg"]), radius = num(sweep["radius"])
    let steps = 24
    for i in 0..<steps {
        let a0 = angle - width / 2 - feather + (width + 2 * feather) * CGFloat(i) / CGFloat(steps)
        let a1 = angle - width / 2 - feather + (width + 2 * feather) * CGFloat(i + 1) / CGFloat(steps)
        let mid = (a0 + a1) / 2
        let edge = min(1, max(0, (width / 2 + feather - abs(mid - angle)) / feather))
        ctx.saveGState()
        ctx.move(to: CGPoint(x: center[0], y: center[1]))
        ctx.addArc(center: CGPoint(x: center[0], y: center[1]), radius: radius,
                   startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
        ctx.closePath()
        ctx.clip()
        let c = color(appearance, "incident.beacon", alpha: sweepAlpha * edge)
        let g = CGGradient(colorsSpace: nil, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: center[0], y: center[1]), startRadius: 0,
                               endCenter: CGPoint(x: center[0], y: center[1]), endRadius: radius, options: [])
        ctx.restoreGState()
    }

    // Smoke.
    if tierSpec["smoke"] as? Bool == true {
        let smoke = dict(spec["smoke"])
        let lobes = smoke["puffCluster"] as! [[String: Any]]
        let softStart = num(smoke["softEdgeStart"])
        func puff(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ alpha: CGFloat) {
            for lobe in lobes {
                let lr = r * num(lobe["rScale"])
                let c = CGPoint(x: cx + num(lobe["dx"]) * r, y: cy + num(lobe["dy"]) * r)
                let col = color(appearance, "incident.smoke", alpha: alpha)
                let g = CGGradient(colorsSpace: nil, colors: [col, col, col.copy(alpha: 0)!] as CFArray,
                                   locations: [0, softStart, 1])!
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: lr, options: [])
            }
        }
        let override = dict(spec["sizeOverrides"])["\(size)"] as? [String: Any]
        let minR = num(override?["smokeMinRadius"] ?? 0)
        if let time {
            let life = num(smoke["lifeMs"]) / 1000
            let count = Int(num(override?["smokeCountPerEmitter"] ?? smoke["countPerEmitter"]))
            let stagger = num(smoke["staggerMs"]) / 1000
            let radii = nums(smoke["radius"]), alphas = nums(smoke["alphaScale"])
            let curve = nums(dict(smoke["curve"])["motion"])
            for e in smoke["emitters"] as! [[String: Any]] {
                for k in 0..<count {
                    let age = (CGFloat(time) + num(e["phase"]) * stagger + CGFloat(k) * stagger)
                        .truncatingRemainder(dividingBy: life) / life
                    let p = cubicBezierEase(age, curve)
                    let r = max(minR, radii[0] + (radii[1] - radii[0]) * p)
                    let a = (alphas[0] + (alphas[1] - alphas[0]) * age) * envelope
                    let cx = num(e["x"]) + num(e["dx"]) * p, cy = num(e["y"]) + num(e["dy"]) * p
                    puff(cx, cy, r, a)
                }
            }
        } else {
            for still in smoke["static"] as! [[String: Any]] {
                let r = max(minR, num(still["r"]))
                puff(num(still["cx"]), num(still["cy"]), r, num(staticSpec["smokeAlphaScale"]))
            }
        }
    }

    // Flames.
    if let tierFlames = tierSpec["flames"] as? String {
        let flames = dict(spec["flames"])
        let baseY = num(flames["baseY"])
        let shape = dict(flames["shape"])
        let c1 = nums(shape["leftControl1"]), c2 = nums(shape["leftControl2"]), tipLean = num(shape["tipLeanFactor"])
        let override = dict(spec["sizeOverrides"])["\(size)"] as? [String: Any]
        let allowed = override?["nestedScaleTokens"] as? [String]
        let layers = (flames["nestedScales"] as! [[String: Any]]).filter { allowed?.contains($0["token"] as! String) ?? true }
        let tier = String(tierFlames.dropFirst("flames.".count))
        for (index, layer) in layers.enumerated() {
            let path = CGMutablePath()
            for t in tongues(tier, size: size) {
                var (h, lean) = flicker(t, time: time)
                h *= num(layer["height"]) * envelope
                let w = t.halfWidth * num(layer["width"])
                lean *= num(layer["height"])
                let tip = CGPoint(x: t.cx + lean, y: baseY - h)
                path.move(to: CGPoint(x: t.cx - w, y: baseY))
                path.addCurve(to: tip,
                              control1: CGPoint(x: t.cx + c1[0] * w, y: baseY - c1[1] * h),
                              control2: CGPoint(x: t.cx + c2[0] * w + lean * tipLean, y: baseY - c2[1] * h))
                path.addCurve(to: CGPoint(x: t.cx + w, y: baseY),
                              control1: CGPoint(x: t.cx - c2[0] * w + lean * tipLean, y: baseY - c2[1] * h),
                              control2: CGPoint(x: t.cx - c1[0] * w, y: baseY - c1[1] * h))
                path.closeSubpath()
            }
            ctx.addPath(path)
            ctx.setFillColor(color(appearance, layer["token"] as! String))
            ctx.fillPath()
            if index == 0 {
                ctx.addPath(path)
                ctx.setStrokeColor(color(appearance, "incident.flame.rim"))
                ctx.setLineWidth(num(dict(flames["rim"])["widthPt"]) * unitsPerPt)
                ctx.strokePath()
            }
        }
    }

    // Siren (same geometry as assets/mascots/mona-pet-v1/ui/incident-siren.svg).
    let siren = dict(spec["siren"])
    let glow = dict(siren["glow"])
    let gc = nums(glow["center"])
    let glowColor = color(appearance, "incident.beacon", alpha: num(glow["alpha"]))
    let glowGradient = CGGradient(colorsSpace: nil, colors: [glowColor, glowColor.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glowGradient, startCenter: CGPoint(x: gc[0], y: gc[1]), startRadius: 0,
                           endCenter: CGPoint(x: gc[0], y: gc[1]), endRadius: num(glow["radius"]), options: [])
    let outline = dict(siren["outline"])
    let outlineWidth = max(num(outline["widthUnits"]), num(outline["minWidthPt"]) * unitsPerPt)
    let dome = dict(siren["dome"]), domeRect = nums(dome["rect"]), topRadius = num(dome["topRadius"])
    let r = CGRect(x: domeRect[0], y: domeRect[1], width: domeRect[2], height: domeRect[3])
    let domePath = CGMutablePath()
    domePath.move(to: CGPoint(x: r.minX, y: r.maxY))
    domePath.addLine(to: CGPoint(x: r.minX, y: r.minY + topRadius))
    domePath.addArc(center: CGPoint(x: r.midX, y: r.minY + topRadius), radius: topRadius,
                    startAngle: .pi, endAngle: 0, clockwise: false)
    domePath.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    domePath.closeSubpath()
    ctx.saveGState()
    ctx.addPath(domePath); ctx.clip()
    let domeGradient = CGGradient(colorsSpace: nil, colors: [color(appearance, "incident.siren.dome"),
                                                             color(appearance, "incident.siren.domeShade")] as CFArray,
                                  locations: [0, 1])!
    ctx.drawLinearGradient(domeGradient, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
    let band = nums(dict(dome["band"])["rect"])
    ctx.setFillColor(color(appearance, "incident.siren.domeShade"))
    ctx.fill(CGRect(x: band[0], y: band[1], width: band[2], height: band[3]))
    let gloss = dict(dict(siren["gloss"])["ellipse"])
    ctx.setFillColor(color(appearance, "incident.siren.gloss"))
    ctx.fillEllipse(in: CGRect(x: num(gloss["cx"]) - num(gloss["rx"]), y: num(gloss["cy"]) - num(gloss["ry"]),
                               width: 2 * num(gloss["rx"]), height: 2 * num(gloss["ry"])))
    ctx.restoreGState()
    ctx.addPath(domePath)
    ctx.setStrokeColor(color(appearance, "incident.siren.outline"))
    ctx.setLineWidth(outlineWidth)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    let base = dict(siren["base"]), baseRect = nums(base["rect"])
    let basePath = CGPath(roundedRect: CGRect(x: baseRect[0], y: baseRect[1], width: baseRect[2], height: baseRect[3]),
                          cornerWidth: num(base["cornerRadius"]), cornerHeight: num(base["cornerRadius"]), transform: nil)
    ctx.addPath(basePath)
    ctx.setFillColor(color(appearance, "incident.siren.base"))
    ctx.fillPath()
    ctx.addPath(basePath)
    ctx.strokePath()
}

// Panel geometry from the merged near-touch layout: panel W x H, lane L above the S x S art square.
let panels: [Int: (width: CGFloat, lane: CGFloat)] = [64: (96, 18), 128: (128, 22), 256: (256, 17)]
let backgrounds: [String: CGColor] = [
    "light": CGColor(srgbRed: 0.925, green: 0.925, blue: 0.925, alpha: 1),
    "dark": CGColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1),
]
let scale: CGFloat = 2
let frameFor: [String: String] = ["minor": "attention-03", "major": "urgent-00", "critical": "urgent-00"]
let columns: [(label: String, time: Double?)] = [("static", nil), ("burst 0.15 s", 0.15), ("burst 1.2 s", 1.2), ("burst 2.6 s", 2.6)]
let tiers = ["minor", "major", "critical"]

var keepOutReport: [String] = []

func renderSheet(size: Int, appearance: String, annotate: Bool) throws {
    let s = CGFloat(size)
    let panel = panels[size]!
    let cellW = panel.width + 16, cellH = panel.lane + s + 16
    let width = Int(cellW * CGFloat(columns.count) * scale), height = Int(cellH * CGFloat(tiers.count) * scale)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(backgrounds[appearance]!)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Flip to y-down points.
    ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: scale, y: -scale)
    let unitsPerPt = 256 / s
    for (row, tier) in tiers.enumerated() {
        for (col, column) in columns.enumerated() {
            let originX = CGFloat(col) * cellW + 8 + (panel.width - s) / 2
            let originY = CGFloat(row) * cellH + 8 + panel.lane
            ctx.saveGState()
            ctx.clip(to: CGRect(x: CGFloat(col) * cellW + 8, y: CGFloat(row) * cellH + 8, width: panel.width, height: panel.lane + s))
            ctx.translateBy(x: originX, y: originY)
            ctx.scaleBy(x: s / 256, y: s / 256)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: CGFloat((dict(spec["keepOut"])["topBandMaxY"] as! NSNumber).doubleValue), width: 256, height: 256))
            drawMarker(ctx, tier: tier, appearance: appearance, size: size, time: column.time, unitsPerPt: unitsPerPt)
            ctx.restoreGState()
            // Mascot art on top. CGContext draws images y-up, so flip locally.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: 256); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(loadImage("assets/mascots/mona-pet-v1/frames/\(frameFor[tier]!).png"), in: CGRect(x: 0, y: 0, width: 256, height: 256))
            ctx.restoreGState()
            if annotate {
                ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 0.9))
                ctx.setLineWidth(unitsPerPt)
                ctx.setLineDash(phase: 0, lengths: [4 * unitsPerPt, 3 * unitsPerPt])
                ctx.stroke(CGRect(x: 0, y: -panel.lane * unitsPerPt, width: 256, height: 64 + panel.lane * unitsPerPt))
            }
            ctx.restoreGState()
        }
    }
    let image = ctx.makeImage()!
    let name = "incident-\(size)-\(appearance)\(annotate ? "-keepout" : "").png"
    let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(name)") }
    print("wrote \(name) \(width)x\(height)")
}

// Keep-out check: draw each marker alone, unclipped, at 256 units and look for alpha above the band.
func checkKeepOut() {
    let band = Int(num(dict(spec["keepOut"])["topBandMaxY"]))
    let times: [Double?] = [nil] + stride(from: 0.0, to: 6.0, by: 1.0 / 30).map { Optional($0) }
    for size in [64, 128, 256] {
        for tier in tiers {
            var worstTop = 256
            for time in times {
                let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.translateBy(x: 0, y: 256); ctx.scaleBy(x: 1, y: -1)
                drawMarker(ctx, tier: tier, appearance: "light", size: size, time: time, unitsPerPt: 256 / CGFloat(size))
                let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
                rows: for y in 0..<256 {
                    for x in 0..<256 where data[(y * 256 + x) * 4 + 3] > 0 {
                        worstTop = min(worstTop, y); break rows
                    }
                }
            }
            keepOutReport.append("keep-out @\(size) \(tier): topmost marker row y=\(worstTop) (band y<\(band)) \(worstTop >= band ? "PASS" : "FAIL") over static + 180 burst frames")
        }
    }
}

for size in [64, 128, 256] {
    for appearance in ["light", "dark"] { try renderSheet(size: size, appearance: appearance, annotate: false) }
}
try renderSheet(size: 128, appearance: "light", annotate: true)
checkKeepOut()
let report = (["Design previews of incident-marker.json drawn with CoreGraphics behind real mona-pet-v1 frames.",
               "Not native MascotView renders; labels (DEMO/count) are not drawn. Columns: static, burst 0.15/1.2/2.6 s. Rows: minor, major, critical."]
              + keepOutReport).joined(separator: "\n") + "\n"
try report.write(to: outDir.appendingPathComponent("preview-report.txt"), atomically: true, encoding: .utf8)
print(report)
