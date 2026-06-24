import AppKit

// Renders the DMG background at 2x (window is 660x400 → image 1320x800).
// Coordinates here are bottom-left origin (AppKit). The Finder window uses
// top-left origin; icon centers sit at window (165,185) and (495,185), which
// at 2x bottom-left is y = 800 - 185*2 = 430, x = 330 and 990.

let W = 1320, H = 800
let logoPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// --- background gradient (#0a0a0b -> #161618) ---
let cs = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: Double,_ g: Double,_ b: Double,_ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r/255), CGFloat(g/255), CGFloat(b/255), CGFloat(a)])!
}
let grad = CGGradient(colorsSpace: cs, colors: [rgb(10,10,11), rgb(22,22,24)] as CFArray, locations: [0,1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// --- subtle top vignette glow ---
let glow = CGGradient(colorsSpace: cs, colors: [rgb(10,132,255,0.10), rgb(10,132,255,0)] as CFArray, locations: [0,1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W/2, y: 640), startRadius: 0,
                       endCenter: CGPoint(x: W/2, y: 640), endRadius: 460, options: [])

// --- logo, centered near top ---
let logo = NSImage(contentsOfFile: logoPath)!
let logoSize: CGFloat = 150
logo.draw(in: NSRect(x: CGFloat(W)/2 - logoSize/2, y: 600, width: logoSize, height: logoSize),
          from: .zero, operation: .sourceOver, fraction: 1.0)

// --- wordmark "teebe" under logo ---
func drawText(_ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, centerX: CGFloat, baselineY: CGFloat, tracking: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let nsColor = NSColor(cgColor: color)!
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: nsColor, .kern: tracking]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: centerX - sz.width/2, y: baselineY))
}
drawText("teebe", size: 52, weight: .semibold, color: rgb(237,237,239), centerX: CGFloat(W)/2, baselineY: 540)

// --- arrow from app -> Applications, on the icon centerline (y=430) ---
let arrowY: CGFloat = 430
let x0: CGFloat = 478, x1: CGFloat = 842
ctx.setLineWidth(7)
ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(10,132,255,0.9))
ctx.move(to: CGPoint(x: x0, y: arrowY))
ctx.addLine(to: CGPoint(x: x1 - 18, y: arrowY))
ctx.strokePath()
// arrowhead
ctx.setFillColor(rgb(10,132,255,0.95))
ctx.move(to: CGPoint(x: x1, y: arrowY))
ctx.addLine(to: CGPoint(x: x1 - 30, y: arrowY + 18))
ctx.addLine(to: CGPoint(x: x1 - 30, y: arrowY - 18))
ctx.closePath()
ctx.fillPath()

// --- hint text near bottom ---
drawText("Drag teebe onto Applications to install", size: 24, weight: .regular,
         color: rgb(134,134,139), centerX: CGFloat(W)/2, baselineY: 95)

img.unlockFocus()

// --- write PNG ---
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
