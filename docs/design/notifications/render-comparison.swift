// Standalone AppKit design renderer. No application/runtime source is imported.
// From repository root: swift docs/design/notifications/render-comparison.swift
import AppKit
import Foundation

struct Scale: Decodable {
    let size, panelWidth, laneHeight, countHeight, countFont, countPadding: Int
    let demoHeight, demoFont, demoPadding, inset, minimumGap: Int
}
struct Metrics: Decodable { let scales: [Scale]; let comparisonLabels: [String] }
struct Step: Decodable { let startMs, durationMs: Int; let frame: String; let angleDegrees: Double }
struct Storyboard: Decodable { let steps: [Step] }
let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let root = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let art = root.appendingPathComponent("assets/mascots/mona-pet-v1/frames")
let metrics = try JSONDecoder().decode(Metrics.self, from: Data(contentsOf: directory.appendingPathComponent("badge-metrics.json")))
let storyboard = try JSONDecoder().decode(Storyboard.self, from: Data(contentsOf: directory.appendingPathComponent("attention-storyboard.json")))
let app = NSApplication.shared
var measurements: [[String: Any]] = []
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor) {
    (value as NSString).draw(at: NSPoint(x:x,y:y), withAttributes:[.font:font,.foregroundColor:color])
}
func width(_ value: String, _ font: NSFont) -> CGFloat { (value as NSString).size(withAttributes:[.font:font]).width }
func pill(_ value: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, font: NSFont, fill: NSColor, foreground: NSColor) {
    fill.setFill(); NSBezierPath(roundedRect:NSRect(x:x,y:y,width:w,height:h),xRadius:h/2,yRadius:h/2).fill()
    let size = (value as NSString).size(withAttributes:[.font:font])
    text(value,x+(w-size.width)/2,y+(h-size.height)/2,font,foreground)
}
func image(_ filename: String, x: CGFloat, y: CGFloat, size: CGFloat, angle: Double = 0) {
    let source = NSImage(contentsOf:art.appendingPathComponent(filename))!
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by:x+size/2,yBy:y+size*232/256)
    transform.rotate(byDegrees:CGFloat(angle))
    transform.translateX(by:-size/2,yBy:-size*232/256)
    transform.concat()
    source.draw(in:NSRect(x:0,y:0,width:size,height:size),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
}
final class Board: NSView {
    let dark: Bool; let story: Bool
    init(dark:Bool,story:Bool) { self.dark=dark; self.story=story; super.init(frame:NSRect(x:0,y:0,width:1184,height:story ? 330 : 930)) }
    required init?(coder:NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ rect:NSRect) {
        let background = dark ? NSColor(calibratedWhite:0.12,alpha:1) : .white
        let foreground = dark ? NSColor.white : NSColor.black
        background.setFill(); bounds.fill()
        text(story ? "Friendly double wave — native key poses" : "Responsive badge comparison — native point sizes",32,18,.systemFont(ofSize:20,weight:.semibold),foreground)
        text("Design composition · actual AppKit fonts and original generated pack art · not an app screenshot",32,48,.systemFont(ofSize:12),foreground)
        if story {
            for (index,step) in storyboard.steps.enumerated() {
                let x = CGFloat(32+index*160)
                image(step.frame,x:x,y:105,size:128,angle:step.angleDegrees)
                text("\(step.startMs) ms · \(step.angleDegrees)°",x,260,.systemFont(ofSize:12,weight:.semibold),foreground)
                text("hold \(step.durationMs) ms",x,280,.systemFont(ofSize:11),foreground)
            }
            return
        }
        var top: CGFloat = 92
        for scale in metrics.scales {
            text("\(scale.size) pt art · \(scale.panelWidth) × \(scale.size+scale.laneHeight) pt panel",32,top,.systemFont(ofSize:14,weight:.semibold),foreground)
            for (index,label) in metrics.comparisonLabels.enumerated() {
                let x = CGFloat(32+index*280)+(256-CGFloat(scale.panelWidth))/2
                let y = top+30; let lane = CGFloat(scale.laneHeight)
                let font = NSFont.monospacedDigitSystemFont(ofSize:CGFloat(scale.countFont),weight:.semibold)
                let demoFont = NSFont.systemFont(ofSize:CGFloat(scale.demoFont),weight:.bold)
                let countWidth = max(CGFloat(scale.countHeight),ceil(width(label,font))+CGFloat(scale.countPadding*2))
                let demoWidth = ceil(width("DEMO",demoFont))+CGFloat(scale.demoPadding*2)
                let availableGap = CGFloat(scale.panelWidth-scale.inset*2)-countWidth-demoWidth
                precondition(availableGap >= CGFloat(scale.minimumGap),"Bad label fit")
                let countX=x+CGFloat(scale.panelWidth-scale.inset)-countWidth
                pill("DEMO",x:x+CGFloat(scale.inset),y:y+(lane-CGFloat(scale.demoHeight))/2,w:demoWidth,h:CGFloat(scale.demoHeight),font:demoFont,fill:dark ? .white : .black,foreground:dark ? .black : .white)
                pill(label,x:countX,y:y+(lane-CGFloat(scale.countHeight))/2,w:countWidth,h:CGFloat(scale.countHeight),font:font,fill:dark ? NSColor(calibratedRed:0.55,green:0.76,blue:1,alpha:1) : NSColor(calibratedRed:0.02,green:0.29,blue:0.65,alpha:1),foreground:dark ? .black : .white)
                image("idle-00.png",x:x+(CGFloat(scale.panelWidth-scale.size))/2,y:y+lane,size:CGFloat(scale.size))
                // Thin boundary is review-only; native window itself stays transparent.
                NSColor.gray.withAlphaComponent(0.5).setStroke()
                NSBezierPath(rect:NSRect(x:x,y:y,width:CGFloat(scale.panelWidth),height:CGFloat(scale.size+scale.laneHeight))).stroke()
                text(label,x+CGFloat(scale.panelWidth)/2-8,y+lane+CGFloat(scale.size)+8,.systemFont(ofSize:11),foreground)
                if !dark { measurements.append(["size":scale.size,"label":label,"countWidth":countWidth,"demoWidth":demoWidth,"gap":availableGap,"minimumGap":scale.minimumGap]) }
            }
            top += CGFloat(scale.size+scale.laneHeight+80)
        }
        text("Thin rectangles show panel bounds for review only. Art remains centered and unscaled within its specified square.",32,900,.systemFont(ofSize:12),foreground)
    }
}
func save(_ view:NSView,_ filename:String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(view.bounds.width),pixelsHigh:Int(view.bounds.height),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    bitmap.size=view.bounds.size
    view.cacheDisplay(in:view.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(filename))
}
try save(Board(dark:false,story:false),"badges-light.png")
try save(Board(dark:true,story:false),"badges-dark.png")
try save(Board(dark:false,story:true),"attention-keyposes.png")
try JSONSerialization.data(withJSONObject:["renderer":"AppKit standalone design composition","pointToPixelScale":1,"measurements":measurements],options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("native-measurements.json"))
print("Rendered native size comparisons and key poses; measured all badge labels.")
