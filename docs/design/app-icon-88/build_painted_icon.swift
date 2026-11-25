// GitHub Pet painted app icon (issue #88, Direction B, painted).
//
// Turns the generated painted master into a clean production icon using
// resampling and compositing only. The character is never repainted:
//   1. The painted tile's measured bounds are mapped onto the 824 px macOS tile
//      of render_icons.swift (uniform scale, so nothing is distorted).
//   2. The painted tile's own edge band (haze, rim light, halo, drop shadow) is
//      discarded. Inside a core inset 16 px from the painted edge the pixels are
//      kept as generated; outside it each pixel is the tile's own colour sampled
//      just inside the core along the radius, so the gradient extends under the clip.
//   3. The result is clipped to the exact continuous-corner tile path, with the
//      drop shadow and hairline rim drawn in code exactly as render_icons.swift's
//      drawTile does (kept in sync by hand; see check below).
//   4. The ten iconset images are Lanczos-3 downsamples of the 1024 master.
//      16 and 32 px optionally get an unsharp mask; `sharpenSmall` records the
//      choice made from the comparison sheet.
//
// Usage (from the repo root):
//   swift docs/design/app-icon-88/build_painted_icon.swift
// Outputs: painted/painted-b-inbox-clean-1024.png, assets/app-icon/AppIcon.iconset,
// renders-painted/{contact-light,contact-dark,small-size-compare}.png.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Settings

let paintedPath = "docs/design/app-icon-88/painted/painted-b-inbox.png"
let masterPath = "docs/design/app-icon-88/painted/painted-b-inbox-clean-1024.png"
let iconsetPath = "assets/app-icon/AppIcon.iconset"
let sheetsPath = "docs/design/app-icon-88/renders-painted"

/// Chosen from small-size-compare.png: see README.
let sharpenSmall = true
let sharpenAmount: Float = 0.6
let sharpenSigma: Float = 0.7

// Painted tile bounds measured on painted-b-inbox.png (alpha < 235 along rays
// from the centre), in the master's y-down pixel space.
let srcLeft = 88.8, srcRight = 932.1, srcTop = 98.8, srcBottom = 953.0
let coreInset = 16.0       // painted pixels within this of the painted edge are replaced
let sampleDepth = 4.0      // extension colour is taken this far inside the core
let seamWidth = 4.0        // painted -> extension cross-fade width at the core boundary
let tileN = 5.2            // superellipse exponent, as render_icons.swift

// MARK: - Tile (verbatim from render_icons.swift)

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

let space: CGFloat = 1024
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)

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

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func writePNG(_ img: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "failed to write \(url.path)")
}

// MARK: - Extend the painted tile's gradient

struct Pixels {
    let w: Int, h: Int
    var d: [UInt8]   // premultiplied RGBA
}

func loadPixels(_ path: String) -> Pixels {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let ctx = makeContext(img.width, img.height)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let n = img.width * img.height * 4
    let p = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: n)
    return Pixels(w: img.width, h: img.height, d: Array(p))
}

func makeImage(_ px: Pixels) -> CGImage {
    var d = px.d
    return d.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: px.w, height: px.h, bitsPerComponent: 8,
                            bytesPerRow: px.w * 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

/// Painted pixels inside the core, the tile's own gradient extended outward elsewhere.
func extendedArtwork(_ src: Pixels) -> Pixels {
    let cx = (srcLeft + srcRight) / 2, cy = (srcTop + srcBottom) / 2
    let a = (srcRight - srcLeft) / 2 - coreInset, b = (srcBottom - srcTop) / 2 - coreInset
    var out = src
    func at(_ x: Double, _ y: Double) -> [Double] {
        // 7 × 7 box average of the painted pixels around (x, y).
        var s = [0.0, 0.0, 0.0]
        var n = 0.0
        for j in -3...3 {
            for i in -3...3 {
                let xi = min(max(Int(x.rounded()) + i, 0), src.w - 1), yi = min(max(Int(y.rounded()) + j, 0), src.h - 1)
                let o = (yi * src.w + xi) * 4
                for c in 0..<3 { s[c] += Double(src.d[o + c]) }
                n += 1
            }
        }
        return s.map { $0 / n }
    }
    for y in 0..<src.h {
        for x in 0..<src.w {
            let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
            let u = pow(abs(dx) / a, tileN) + pow(abs(dy) / b, tileN)   // 1 on the core boundary
            let r = (dx * dx + dy * dy).squareRoot()
            let rb = r / pow(max(u, 1e-9), 1 / tileN)                     // core boundary radius on this ray
            // Distance past the core boundary along the ray, in pixels.
            let past = r - rb
            if past < -seamWidth { continue }
            let k = max(rb - sampleDepth, 1) / max(r, 1e-9)
            let ext = at(cx + dx * k, cy + dy * k)
            let weight = min(max((past + seamWidth) / seamWidth, 0), 1)   // 0 inside the seam band, 1 outside
            let o = (y * src.w + x) * 4
            for c in 0..<3 {
                out.d[o + c] = UInt8((Double(src.d[o + c]) * (1 - weight) + ext[c] * weight).rounded())
            }
            out.d[o + 3] = 255
        }
    }
    return out
}

// MARK: - Master

func renderMaster() -> CGImage {
    let art = makeImage(extendedArtwork(loadPixels(paintedPath)))
    let ctx = makeContext(1024, 1024)
    ctx.translateBy(x: 0, y: space)
    ctx.scaleBy(x: 1, y: -1)               // y-down 1024 design space
    let path = tilePath()

    // Drop shadow, as drawTile: a downward offset, soft, 30 % black. The fill
    // colour is the tile's bottom colour (fully covered by the artwork below).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: RGBA(0x000000, 0.30).cg)
    ctx.addPath(path); ctx.setFillColor(RGBA(0x0F4FE0).cg); ctx.fillPath()
    ctx.restoreGState()

    // Artwork, uniformly scaled so the painted tile's width is the 824 px tile.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let s = Double(tileRect.width) / (srcRight - srcLeft)
    let cx = (srcLeft + srcRight) / 2, cy = (srcTop + srcBottom) / 2
    let x0 = 512 - cx * s, y0 = 512 - cy * s
    ctx.translateBy(x: x0, y: y0 + Double(art.height) * s)
    ctx.scaleBy(x: s, y: -s)               // image rows run downward
    ctx.interpolationQuality = .high
    ctx.draw(art, in: CGRect(x: 0, y: 0, width: art.width, height: art.height))
    ctx.restoreGState()

    // Hairline rim, as drawTile with the blue tile's style (black at 10 %).
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(RGBA(0x000000, 0.10).cg)
    ctx.setLineWidth(4)                    // max(4, 1 / s) at s = 1
    ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - Downsampling (Lanczos-3, premultiplied, separable)

func lanczos(_ x: Double) -> Double {
    if x == 0 { return 1 }
    if abs(x) >= 3 { return 0 }
    let px = Double.pi * x
    return 3 * sin(px) * sin(px / 3) / (px * px)
}

func resamplePass(_ src: [Float], w: Int, h: Int, newW: Int, horizontal: Bool) -> [Float] {
    let inLen = horizontal ? w : h, outLen = horizontal ? newW : h
    let target = horizontal ? newW : newW
    let f = Double(inLen) / Double(target)
    let support = 3 * max(f, 1)
    let lines = horizontal ? h : w
    let outCount = horizontal ? newW : newW
    var out = [Float](repeating: 0, count: horizontal ? newW * h * 4 : w * newW * 4)
    _ = outLen; _ = outCount
    for o in 0..<target {
        let c = (Double(o) + 0.5) * f
        let lo = max(Int((c - support).rounded(.up)) - 1, 0), hi = min(Int((c + support).rounded(.down)), inLen - 1)
        var wts: [Float] = [], sum: Float = 0
        for j in lo...hi {
            let wt = Float(lanczos((Double(j) + 0.5 - c) / max(f, 1)))
            wts.append(wt); sum += wt
        }
        for line in 0..<lines {
            var acc: [Float] = [0, 0, 0, 0]
            for (k, j) in (lo...hi).enumerated() {
                let idx = horizontal ? (line * w + j) * 4 : (j * w + line) * 4
                for c in 0..<4 { acc[c] += src[idx + c] * wts[k] }
            }
            let oidx = horizontal ? (line * newW + o) * 4 : (o * w + line) * 4
            for c in 0..<4 { out[oidx + c] = acc[c] / sum }
        }
    }
    return out
}

func finalize(_ f: [Float], px: Int) -> Pixels {
    var d = [UInt8](repeating: 0, count: px * px * 4)
    for i in 0..<(px * px) {
        let a = min(max(f[i * 4 + 3], 0), 255)
        for c in 0..<3 { d[i * 4 + c] = UInt8(min(max(f[i * 4 + c], 0), a).rounded()) }
        d[i * 4 + 3] = UInt8(a.rounded())
    }
    return Pixels(w: px, h: px, d: d)
}

func downsample(_ master: Pixels, to px: Int, sharpen: Bool = false) -> Pixels {
    if px == master.w { return master }
    let f = master.d.map { Float($0) }
    var cur = resamplePass(f, w: master.w, h: master.h, newW: px, horizontal: true)
    cur = resamplePass(cur, w: px, h: master.h, newW: px, horizontal: false)
    if sharpen { cur = unsharp(cur, px: px) }
    return finalize(cur, px: px)
}

func unsharp(_ f: [Float], px: Int) -> [Float] {
    let rad = Int((3 * sharpenSigma).rounded(.up))
    var k = (-rad...rad).map { expf(-Float($0 * $0) / (2 * sharpenSigma * sharpenSigma)) }
    let ks = k.reduce(0, +); k = k.map { $0 / ks }
    var tmp = f, blur = f
    for y in 0..<px { for x in 0..<px { for c in 0..<4 {
        var s: Float = 0
        for (i, wt) in k.enumerated() { s += wt * f[(y * px + min(max(x + i - rad, 0), px - 1)) * 4 + c] }
        tmp[(y * px + x) * 4 + c] = s
    } } }
    for y in 0..<px { for x in 0..<px { for c in 0..<4 {
        var s: Float = 0
        for (i, wt) in k.enumerated() { s += wt * tmp[(min(max(y + i - rad, 0), px - 1) * px + x) * 4 + c] }
        blur[(y * px + x) * 4 + c] = s
    } } }
    var out = f
    for i in 0..<out.count where i % 4 != 3 { out[i] = f[i] + sharpenAmount * (f[i] - blur[i]) }
    return out
}

// MARK: - Run

let master = renderMaster()
writePNG(master, URL(fileURLWithPath: masterPath))
let masterPixels = loadPixels(masterPath)

var cache: [String: CGImage] = [:]
func icon(_ px: Int, sharpen: Bool = false) -> CGImage {
    let key = "\(px)-\(sharpen)"
    if let c = cache[key] { return c }
    let img = makeImage(downsample(masterPixels, to: px, sharpen: sharpen))
    cache[key] = img
    return img
}

let iconsetDir = URL(fileURLWithPath: iconsetPath)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        writePNG(icon(px, sharpen: sharpenSmall && px <= 32), iconsetDir.appendingPathComponent(name))
    }
}

/// Contact sheet: one row, 1024 at 256, then 128/64/32/16 at 1×, then 32 and 16
/// magnified with nearest-neighbour. Sizes come from the shipped iconset logic.
func contactSheet(background: RGBA) -> CGImage {
    let pad = 24, width = 256 + 128 + 64 + 32 + 16 + 128 + 64 + pad * 8, height = 256 + pad * 2
    let ctx = makeContext(width, height)
    ctx.setFillColor(background.cg)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var x = pad
    func place(_ px: Int, drawn: Int, nearest: Bool = false) {
        ctx.interpolationQuality = nearest ? .none : .high
        ctx.draw(icon(px, sharpen: sharpenSmall && px <= 32), in: CGRect(x: x, y: pad + (256 - drawn) / 2, width: drawn, height: drawn))
        x += drawn + pad
    }
    place(1024, drawn: 256); place(128, drawn: 128); place(64, drawn: 64)
    place(32, drawn: 32); place(16, drawn: 16)
    place(32, drawn: 128, nearest: true); place(16, drawn: 64, nearest: true)
    return ctx.makeImage()!
}
let sheets = URL(fileURLWithPath: sheetsPath)
writePNG(contactSheet(background: RGBA(0xF2F2F4)), sheets.appendingPathComponent("contact-light.png"))
writePNG(contactSheet(background: RGBA(0x1E1E22)), sheets.appendingPathComponent("contact-dark.png"))

/// Small-size comparison: plain Lanczos vs unsharp-masked, at 1× and ×8 nearest, light and dark.
func compareSheet() -> CGImage {
    let pad = 16, cell = 256
    let width = pad + 2 * (cell + pad) * 2, height = pad + 4 * (cell + pad)
    let ctx = makeContext(width, height)
    var row = 0
    for (bgIdx, bg) in [RGBA(0xF2F2F4), RGBA(0x1E1E22)].enumerated() {
        ctx.setFillColor(bg.cg)
        ctx.fill(CGRect(x: CGFloat(bgIdx) * CGFloat(width / 2), y: 0, width: CGFloat(width / 2), height: CGFloat(height)))
    }
    for px in [32, 16] {
        for sharpen in [false, true] {
            for (bgIdx, _) in [0, 1].enumerated() {
                let baseX = bgIdx * (width / 2) + pad
                let y = height - pad - (row + 1) * (cell + pad) + pad
                ctx.interpolationQuality = .none
                ctx.draw(icon(px, sharpen: sharpen), in: CGRect(x: baseX, y: y, width: cell, height: cell))
                ctx.interpolationQuality = .high
                ctx.draw(icon(px, sharpen: sharpen), in: CGRect(x: baseX + cell + pad, y: y + cell / 2 - px / 2, width: px, height: px))
            }
            row += 1
        }
    }
    return ctx.makeImage()!
}
writePNG(compareSheet(), sheets.appendingPathComponent("small-size-compare.png"))
print("wrote master, 10-image iconset (sharpenSmall=\(sharpenSmall)) and contact sheets")
