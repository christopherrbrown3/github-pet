// Frame a README render: optional crop, rounded window corners, a hairline edge and a soft
// shadow on a transparent canvas, so every image reads as one set on light and dark GitHub.
//
//   swift scripts/readme-frame.swift <in.png> <out.png> window|plain [footer]
//
// window: rounded 10 pt corners (20 px at @2x), hairline, shadow. plain: copied unchanged.
// footer: crop at the last full-width divider in the lower half (the Inbox's update/quit footer,
// whose offscreen render reads "Updates not configured" because snapshot mode never starts the
// updater). The cut is reported on stdout for the provenance README. Kept pixels are unchanged.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 4, let style = Optional(arguments[3]), ["window", "plain"].contains(style) else {
    FileHandle.standardError.write(Data("usage: readme-frame.swift <in.png> <out.png> window|plain [footer]\n".utf8))
    exit(64)
}
let cropFooter = arguments.count > 4 && arguments[4] == "footer"
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("readme-frame: cannot read \(arguments[1])\n".utf8)); exit(1)
}

/// The y (from the top) of the lowest divider: a row whose middle 80% is one colour that differs
/// from the window background, sampled at the left edge.
func footerDivider(_ image: CGImage) -> Int? {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    func px(_ x: Int, _ y: Int) -> [Int] { let i = (y * w + x) * 4; return [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])] }
    func near(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 3 } }
    let background = px(2, h - 2)
    for y in stride(from: h - 1, through: h / 2, by: -1) {
        let reference = px(w / 2, y)
        if near(reference, background) { continue }
        let xs = stride(from: w / 10, to: w * 9 / 10, by: 2)
        if xs.allSatisfy({ near(px($0, y), reference) }) {
            var top = y   // a 2 px hairline at @2x: cut above its first row
            while top > 0, near(px(w / 2, top - 1), reference) { top -= 1 }
            return top
        }
    }
    return nil
}
var cropBottom = 0
if cropFooter {
    guard let divider = footerDivider(full) else {
        FileHandle.standardError.write(Data("readme-frame: no footer divider in \(arguments[1])\n".utf8)); exit(1)
    }
    cropBottom = full.height - divider
    print("cropped \(cropBottom) px footer (divider at y=\(divider))")
}
// CGImage cropping is top-left based.
guard let image = full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: full.height - cropBottom)) else { exit(1) }
let dark = arguments[1].hasSuffix("-dark.png")

let window = style == "window"
let margin = window ? 48 : 0        // room for the shadow
let radius: CGFloat = 20
let width = image.width + margin * 2, height = image.height + margin * 2
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
let rect = CGRect(x: margin, y: margin, width: image.width, height: image.height)
if window {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // Two shadows: a tight contact shadow and a wide ambient one, like a macOS window.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40,
                      color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.22))
    context.addPath(path); context.setFillColor(CGColor(gray: dark ? 0.12 : 1, alpha: 1)); context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.18))
    context.addPath(path); context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(path); context.clip()
    context.draw(image, in: rect)
    context.restoreGState()
    // Hairline: dark windows get a faint light edge, light windows a faint dark one.
    context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5,
                           cornerHeight: radius - 0.5, transform: nil))
    context.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.16) : CGColor(gray: 0, alpha: 0.14))
    context.setLineWidth(1)
    context.strokePath()
} else {
    context.draw(image, in: rect)
}
guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else { exit(1) }
// 144 dpi marks the file as @2x for viewers that honour it.
CGImageDestinationAddImage(destination, output, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { exit(1) }
