import AppKit

// Renders the DMG background: a plain neutral grey (subtle vertical gradient),
// no decoration. The two icons are placed on top by dmgbuild. Window is
// 600x440; image is 2x (1200x880).

let W = 1200, H = 880
let outPath = CommandLine.arguments[1]

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func grey(_ v: Double) -> CGColor { CGColor(colorSpace: cs, components: [CGFloat(v/255), CGFloat(v/255), CGFloat(v/255), 1])! }
let grad = CGGradient(colorsSpace: cs, colors: [grey(236), grey(220)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
