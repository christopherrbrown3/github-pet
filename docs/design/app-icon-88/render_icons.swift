// GitHub Pet app-icon directions for issue #88.
// Deterministic vector source: every shape below is authored geometry in a
// 1024 × 1024 design space, drawn with CoreGraphics. No raster inputs.
//
// Usage (from the repo root):
//   swift docs/design/app-icon-88/render_icons.swift [output-dir] [iconset-dir]
// Defaults: docs/design/app-icon-88/renders and assets/app-icon/AppIcon.iconset
// (the production iconset of the approved Direction A).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

struct RGBA {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ hex: UInt32, _ a: CGFloat = 1) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
        self.a = a
    }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

let ink = RGBA(0x16171B)          // Mona's body
let inkTop = RGBA(0x2E3038)       // top of the body gradient
let earInner = RGBA(0x4A4C56)
let mask = RGBA(0xF8DCC8)         // Mona's face
let eye = RGBA(0x16171B)
let blush = RGBA(0xF29A9A, 0.55)
let white = RGBA(0xFFFFFF)

// MARK: - Geometry helpers

let space: CGFloat = 1024
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Superellipse approximating the macOS continuous-corner icon tile.
func tilePath(_ r: CGRect = tileRect) -> CGPath {
    let p = CGMutablePath()
    let n: CGFloat = 5.2
    let a = r.width / 2, b = r.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = r.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), transform: nil)
}

func linearGradient(_ ctx: CGContext, _ colors: [RGBA], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: colors.map(\.cg) as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Level of detail. Small renders drop whiskers/highlights and enlarge features.
enum Detail { case full, small, tiny }

func detail(for px: Int) -> Detail { px <= 16 ? .tiny : (px <= 32 ? .small : .full) }

// MARK: - Tile

struct TileStyle {
    let top: RGBA, bottom: RGBA
    let rim: RGBA          // hairline so light tiles hold their edge on light backgrounds
}

func drawTile(_ ctx: CGContext, _ style: TileStyle, px: Int) {
    let path = tilePath()
    // Restrained drop shadow (Apple grid: soft, offset downward).
    ctx.saveGState()
    let s = CGFloat(px) / space
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 22 * s, color: RGBA(0x000000, 0.30).cg)
    ctx.addPath(path); ctx.setFillColor(style.bottom.cg); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    linearGradient(ctx, [style.top, style.bottom], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(style.rim.cg)
    ctx.setLineWidth(max(4, 1.0 / s))   // at least ~1 device pixel
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Mona head (original geometry inspired by the mona-pet-v1 frames)

/// Draws Mona's head centred at (cx, cy) with head width w (y-down space).
/// The head is a soft cat hood with a peach face; no tentacle silhouette, so it
/// stays clear of the GitHub Invertocat mark.
func monaHeadPieces(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat) -> [CGPath] {
    var pieces = [ellipse(cx, cy + 0.04 * w, w, 0.84 * w)]
    for side in [-1.0, 1.0] as [CGFloat] {
        let ear = CGMutablePath()
        ear.move(to: CGPoint(x: cx + side * 0.45 * w, y: cy - 0.10 * w))
        ear.addLine(to: CGPoint(x: cx + side * 0.38 * w, y: cy - 0.50 * w))
        ear.addLine(to: CGPoint(x: cx + side * 0.10 * w, y: cy - 0.30 * w))
        ear.closeSubpath()
        // Round the ear tip by stroking with a round join; fill both pieces
        // separately so winding never cancels.
        pieces.append(ear.copy(strokingWithWidth: 0.09 * w, lineCap: .round, lineJoin: .round, miterLimit: 1))
        pieces.append(ear)
    }
    return pieces
}

func drawMona(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, w: CGFloat, d: Detail, px: Int) {
    let pieces = monaHeadPieces(cx, cy, w)

    // Silhouette in a transparency layer, then a soft top-lit gradient atop it.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for piece in pieces { ctx.addPath(piece); ctx.setFillColor(ink.cg); ctx.fillPath() }
    ctx.setBlendMode(.sourceAtop)
    linearGradient(ctx, [inkTop, ink], from: CGPoint(x: cx, y: cy - 0.55 * w), to: CGPoint(x: cx, y: cy + 0.1 * w))
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()

    if d == .full {
        // Inner ears.
        for side in [-1.0, 1.0] as [CGFloat] {
            let e = CGMutablePath()
            e.move(to: CGPoint(x: cx + side * 0.40 * w, y: cy - 0.14 * w))
            e.addLine(to: CGPoint(x: cx + side * 0.36 * w, y: cy - 0.40 * w))
            e.addLine(to: CGPoint(x: cx + side * 0.20 * w, y: cy - 0.29 * w))
            e.closeSubpath()
            ctx.setFillColor(earInner.cg)
            ctx.addPath(e.copy(strokingWithWidth: 0.04 * w, lineCap: .round, lineJoin: .round, miterLimit: 1))
            ctx.fillPath()
            ctx.addPath(e); ctx.fillPath()
        }
        // Restrained gloss on the crown.
        ctx.saveGState()
        ctx.addPath(pieces[0]); ctx.clip()
        let gloss = CGMutablePath()
        gloss.addArc(center: CGPoint(x: cx, y: cy + 0.10 * w), radius: 0.40 * w,
                     startAngle: .pi * 1.18, endAngle: .pi * 1.42, clockwise: false)
        ctx.addPath(gloss)
        ctx.setStrokeColor(RGBA(0xFFFFFF, 0.22).cg)
        ctx.setLineWidth(0.035 * w); ctx.setLineCap(.round); ctx.strokePath()
        ctx.restoreGState()
    }

    // Face: one wide peach shape; small sizes enlarge it so it survives 16 px.
    let faceW: CGFloat = d == .full ? 0.76 : 0.80
    let faceH: CGFloat = d == .full ? 0.52 : 0.56
    ctx.addPath(ellipse(cx, cy + 0.14 * w, faceW * w, faceH * w))
    ctx.setFillColor(mask.cg); ctx.fillPath()

    if d == .full {
        // Eyes with a catchlight, and a curved smile.
        let eyeY = cy + 0.10 * w
        for side in [-1.0, 1.0] as [CGFloat] {
            ctx.addPath(ellipse(cx + side * 0.165 * w, eyeY, 0.095 * w, 0.13 * w))
            ctx.setFillColor(eye.cg); ctx.fillPath()
            ctx.addPath(ellipse(cx + side * 0.165 * w + 0.018 * w, eyeY - 0.03 * w, 0.034 * w, 0.034 * w))
            ctx.setFillColor(white.cg); ctx.fillPath()
        }
        let smile = CGMutablePath()
        smile.move(to: CGPoint(x: cx - 0.065 * w, y: cy + 0.235 * w))
        smile.addQuadCurve(to: CGPoint(x: cx + 0.065 * w, y: cy + 0.235 * w),
                           control: CGPoint(x: cx, y: cy + 0.32 * w))
        ctx.addPath(smile)
        ctx.setStrokeColor(eye.cg)
        ctx.setLineWidth(0.026 * w)
        ctx.setLineCap(.round); ctx.strokePath()
    } else {
        // Pixel-snapped features for 16/32 px: the eyes and smile fill whole
        // device pixels (g design units each), mirrored about cx, so they stay
        // solid black instead of anti-aliasing to grey.
        let g = space / CGFloat(px)
        let ew: CGFloat = d == .small ? 2 : 1, eh: CGFloat = d == .small ? 3 : 2
        let eyeY = cy + 0.10 * w
        let left = ((cx - 0.18 * w - ew * g / 2) / g).rounded() * g
        let top = ((eyeY - eh * g / 2) / g).rounded() * g
        ctx.setFillColor(eye.cg)
        for x in [left, 2 * cx - left - ew * g] {
            ctx.fill(CGRect(x: x, y: top, width: ew * g, height: eh * g))
        }
        if d == .small {
            // A two-pixel mouth with one-pixel upturned corners.
            let row = ((cy + 0.27 * w) / g).rounded() * g
            ctx.fill(CGRect(x: cx - g, y: row, width: 2 * g, height: g))
            ctx.fill(CGRect(x: cx - 2 * g, y: row - g, width: g, height: g))
            ctx.fill(CGRect(x: cx + g, y: row - g, width: g, height: g))
        }
    }

    if d == .full {
        for side in [-1.0, 1.0] as [CGFloat] {
            ctx.addPath(ellipse(cx + side * 0.27 * w, cy + 0.22 * w, 0.085 * w, 0.05 * w))
            ctx.setFillColor(blush.cg); ctx.fillPath()
            // Whiskers: two short strokes per side, inside the mask.
            for (i, dy) in [CGFloat(0.165), 0.205].enumerated() {
                let wp = CGMutablePath()
                let x0 = cx + side * 0.25 * w, x1 = cx + side * 0.34 * w
                wp.move(to: CGPoint(x: x0, y: cy + dy * w))
                wp.addLine(to: CGPoint(x: x1, y: cy + (dy + (i == 0 ? -0.012 : 0.012)) * w))
                ctx.addPath(wp)
            }
            ctx.setStrokeColor(RGBA(0x16171B, 0.55).cg)
            ctx.setLineWidth(0.012 * w); ctx.setLineCap(.round); ctx.strokePath()
        }
    }
}

/// Mona's tentacle skirt: four short, thick strokes under the chin whose tips
/// curl outward, as in the mona-pet-v1 frames. Drawn before the head so the
/// roots tuck behind it. Only used at sizes where the strokes stay distinct.
func drawTentacles(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, w: CGFloat) {
    let roots: [(dx: CGFloat, reach: CGFloat, drop: CGFloat)] = [
        (-0.30, -0.26, 0.24), (-0.10, -0.12, 0.34), (0.10, 0.12, 0.34), (0.30, 0.26, 0.24),
    ]
    for r in roots {
        let side: CGFloat = r.dx < 0 ? -1 : 1
        let start = CGPoint(x: cx + r.dx * w, y: cy + 0.30 * w)
        let end = CGPoint(x: start.x + r.reach * w, y: start.y + r.drop * w)
        let p = CGMutablePath()
        p.move(to: start)
        p.addQuadCurve(to: end, control: CGPoint(x: start.x, y: end.y + 0.02 * w))
        // Tip curls back up.
        p.addQuadCurve(to: CGPoint(x: end.x + side * 0.02 * w, y: end.y - 0.08 * w),
                       control: CGPoint(x: end.x + side * 0.08 * w, y: end.y + 0.01 * w))
        ctx.addPath(p)
        ctx.setStrokeColor(ink.cg)
        ctx.setLineWidth(0.10 * w); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.strokePath()
    }
}

// MARK: - Inbox tray (shared by directions B and C)

/// Rounded tray front, the GitHub Pet "inbox" cue. Returns the tray top y.
func drawTray(_ ctx: CGContext, top: CGFloat, color: RGBA, lip: RGBA, d: Detail) {
    let left: CGFloat = 196, right: CGFloat = 828
    let bottom: CGFloat = 860
    let p = CGMutablePath()
    p.addRoundedRect(in: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                     cornerWidth: 70, cornerHeight: 70)
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    linearGradient(ctx, [color, RGBA(0x000000, 0)], from: CGPoint(x: 512, y: top), to: CGPoint(x: 512, y: top))
    ctx.restoreGState()
    ctx.addPath(p); ctx.setFillColor(color.cg); ctx.fillPath()

    // Tray slot: the classic inbox notch, scaled up so it reads at 32 px.
    let notch = CGMutablePath()
    let ny = top + (bottom - top) * 0.36
    notch.move(to: CGPoint(x: left + 70, y: ny))
    notch.addLine(to: CGPoint(x: 400, y: ny))
    notch.addLine(to: CGPoint(x: 430, y: ny + 64))
    notch.addLine(to: CGPoint(x: 594, y: ny + 64))
    notch.addLine(to: CGPoint(x: 624, y: ny))
    notch.addLine(to: CGPoint(x: right - 70, y: ny))
    if d != .tiny {
        ctx.addPath(notch)
        ctx.setStrokeColor(lip.cg)
        ctx.setLineWidth(d == .full ? 30 : 46)
        ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
    }
    // Lip highlight along the top edge.
    if d == .full {
        let hl = CGMutablePath()
        hl.move(to: CGPoint(x: left + 60, y: top + 16))
        hl.addLine(to: CGPoint(x: right - 60, y: top + 16))
        ctx.addPath(hl)
        ctx.setStrokeColor(RGBA(0xFFFFFF, 0.25).cg)
        ctx.setLineWidth(10); ctx.setLineCap(.round); ctx.strokePath()
    }
}

// MARK: - Little Chris head (exploration only)

let skin = RGBA(0xE9B48E)
let hair = RGBA(0x7A4524)
let beard = RGBA(0x5E3418)
let hood = RGBA(0x22305A)

func drawLittleChris(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, w: CGFloat, d: Detail) {
    // Hood behind the head.
    ctx.addPath(ellipse(cx, cy + 0.12 * w, 1.04 * w, 0.92 * w))
    ctx.setFillColor(hood.cg); ctx.fillPath()
    // Face.
    ctx.addPath(ellipse(cx, cy + 0.08 * w, 0.74 * w, 0.80 * w))
    ctx.setFillColor(skin.cg); ctx.fillPath()
    // Beard: lower half of the face.
    ctx.saveGState()
    ctx.addPath(ellipse(cx, cy + 0.08 * w, 0.74 * w, 0.80 * w)); ctx.clip()
    let b = CGMutablePath()
    b.move(to: CGPoint(x: cx - 0.40 * w, y: cy + 0.12 * w))
    b.addQuadCurve(to: CGPoint(x: cx + 0.40 * w, y: cy + 0.12 * w), control: CGPoint(x: cx, y: cy + 0.26 * w))
    b.addLine(to: CGPoint(x: cx + 0.40 * w, y: cy + 0.6 * w))
    b.addLine(to: CGPoint(x: cx - 0.40 * w, y: cy + 0.6 * w))
    b.closeSubpath()
    ctx.addPath(b); ctx.setFillColor(beard.cg); ctx.fillPath()
    if d != .tiny {
        // Mouth opening in the beard.
        ctx.addPath(ellipse(cx, cy + 0.30 * w, 0.18 * w, d == .full ? 0.08 * w : 0.10 * w))
        ctx.setFillColor(RGBA(0xFFFFFF).cg); ctx.fillPath()
    }
    ctx.restoreGState()
    // Hair: a scalloped cap of spikes.
    let hp = CGMutablePath()
    let spikes = d == .full ? 9 : 5
    hp.addPath(ellipse(cx, cy - 0.22 * w, 0.84 * w, 0.46 * w))
    for i in 0..<spikes {
        let t = CGFloat(i) / CGFloat(spikes - 1)
        let ang = CGFloat.pi * (1.10 + 0.80 * t)
        let px = cx + cos(ang) * 0.40 * w, py = cy - 0.20 * w + sin(ang) * 0.30 * w
        hp.addPath(ellipse(px, py, 0.20 * w, 0.20 * w))
    }
    ctx.addPath(hp); ctx.setFillColor(hair.cg); ctx.fillPath()
    // Eyes.
    let ew: CGFloat = d == .full ? 0.12 : 0.14
    for side in [-1.0, 1.0] as [CGFloat] {
        ctx.addPath(ellipse(cx + side * 0.15 * w, cy + 0.04 * w, ew * w, ew * 1.15 * w))
        ctx.setFillColor(d == .full ? white.cg : RGBA(0x1A1410).cg); ctx.fillPath()
        if d == .full {
            ctx.addPath(ellipse(cx + side * 0.15 * w, cy + 0.05 * w, 0.075 * w, 0.085 * w))
            ctx.setFillColor(RGBA(0x1A1410).cg); ctx.fillPath()
        }
    }
    if d == .full {
        for side in [-1.0, 1.0] as [CGFloat] {
            let br = CGMutablePath()
            br.move(to: CGPoint(x: cx + side * 0.08 * w, y: cy - 0.07 * w))
            br.addLine(to: CGPoint(x: cx + side * 0.23 * w, y: cy - 0.09 * w))
            ctx.addPath(br)
        }
        ctx.setStrokeColor(beard.cg); ctx.setLineWidth(0.035 * w); ctx.setLineCap(.round); ctx.strokePath()
    }
}

// MARK: - Directions

struct Direction {
    let id: String
    let title: String
    let draw: (CGContext, Int) -> Void
}

let directions: [Direction] = [
    Direction(id: "a-mona-portrait", title: "A · Mona portrait") { ctx, px in
        let d = detail(for: px)
        drawTile(ctx, TileStyle(top: RGBA(0x7CC8FF), bottom: RGBA(0x3D6EF0), rim: RGBA(0x000000, 0.10)), px: px)
        ctx.saveGState()
        ctx.addPath(tilePath()); ctx.clip()
        // Full size adds Mona's tentacle skirt under a slightly smaller head;
        // small sizes are the head alone, as large as the tile allows.
        let w: CGFloat = d == .full ? 540 : 680
        let cx: CGFloat = 512
        let cy: CGFloat = d == .full ? 470 : 566
        if d == .full { drawTentacles(ctx, cx: cx, cy: cy, w: w) }
        drawMona(ctx, cx: cx, cy: cy, w: w, d: d, px: px)
        ctx.restoreGState()
    },
    Direction(id: "b-mona-inbox", title: "B · Mona inbox peek") { ctx, px in
        let d = detail(for: px)
        drawTile(ctx, TileStyle(top: RGBA(0xFFF7EC), bottom: RGBA(0xF1E2CF), rim: RGBA(0x000000, 0.09)), px: px)
        ctx.saveGState()
        ctx.addPath(tilePath()); ctx.clip()
        let w: CGFloat = d == .full ? 510 : 600
        let trayTop: CGFloat = d == .full ? 640 : 650
        drawMona(ctx, cx: 512, cy: d == .full ? 456 : 432, w: w, d: d, px: px)
        drawTray(ctx, top: trayTop, color: RGBA(0x5B4BDB), lip: RGBA(0x3A2DA8), d: d)
        ctx.restoreGState()
    },
    Direction(id: "c-little-chris-inbox", title: "C · Little Chris inbox peek (exploration)") { ctx, px in
        let d = detail(for: px)
        drawTile(ctx, TileStyle(top: RGBA(0xFFF7EC), bottom: RGBA(0xF1E2CF), rim: RGBA(0x000000, 0.09)), px: px)
        ctx.saveGState()
        ctx.addPath(tilePath()); ctx.clip()
        let w: CGFloat = d == .full ? 500 : 580
        drawLittleChris(ctx, cx: 512, cy: d == .full ? 440 : 420, w: w, d: d)
        drawTray(ctx, top: d == .full ? 640 : 650, color: RGBA(0x5B4BDB), lip: RGBA(0x3A2DA8), d: d)
        ctx.restoreGState()
    },
]

// MARK: - Rendering

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func render(_ dir: Direction, px: Int) -> CGImage {
    let ctx = makeContext(px, px)
    // Flip to a y-down 1024 design space.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / space, y: -CGFloat(px) / space)
    dir.draw(ctx, px)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "failed to write \(url.path)")
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "docs/design/app-icon-88/renders")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var rendered: [String: [Int: CGImage]] = [:]
for dir in directions {
    let sub = outDir.appendingPathComponent(dir.id)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    for px in sizes {
        let img = render(dir, px: px)
        rendered[dir.id, default: [:]][px] = img
        // 1024 is the master; 512/256 previews are kept, smaller sizes too.
        writePNG(img, sub.appendingPathComponent("icon-\(px).png"))
    }
}

/// Contact sheet: per direction, 256 preview, then 128/64/32/16 at 1×, then
/// 32 and 16 magnified ×4 with nearest-neighbour so pixel legibility is visible.
func contactSheet(background: RGBA) -> CGImage {
    let rowH = 300, pad = 24
    let width = 256 + 128 + 64 + 32 + 16 + 128 + 64 + pad * 9
    let height = rowH * directions.count + pad
    let ctx = makeContext(width, height)
    ctx.setFillColor(background.cg)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (row, dir) in directions.enumerated() {
        let baseY = height - pad - rowH * row - 256 - 20   // y-up
        var x = pad
        func place(_ px: Int, drawn: Int, nearest: Bool = false) {
            let img = rendered[dir.id]![px]!
            ctx.interpolationQuality = nearest ? .none : .high
            let y = baseY + (256 - drawn) / 2
            ctx.draw(img, in: CGRect(x: x, y: y, width: drawn, height: drawn))
            x += drawn + pad
        }
        place(1024, drawn: 256)
        place(128, drawn: 128)
        place(64, drawn: 64)
        place(32, drawn: 32)
        place(16, drawn: 16)
        place(32, drawn: 128, nearest: true)
        place(16, drawn: 64, nearest: true)
    }
    return ctx.makeImage()!
}

writePNG(contactSheet(background: RGBA(0xF2F2F4)), outDir.appendingPathComponent("contact-light.png"))
writePNG(contactSheet(background: RGBA(0x1E1E22)), outDir.appendingPathComponent("contact-dark.png"))
// Production iconset for the approved direction (A). Detail level follows the
// pixel size, so icon_16x16@2x uses the 32 px drawing.
let approved = directions.first { $0.id == "a-mona-portrait" }!
let iconsetDir = URL(fileURLWithPath: CommandLine.arguments.count > 2
                     ? CommandLine.arguments[2] : "assets/app-icon/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        writePNG(render(approved, px: points * scale), iconsetDir.appendingPathComponent(name))
    }
}
print("wrote 10-image iconset into \(iconsetDir.path)")
print("rendered \(directions.count) directions × \(sizes.count) sizes into \(outDir.path)")
