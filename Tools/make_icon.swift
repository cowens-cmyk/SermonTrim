import AppKit
import CoreGraphics

// Draws the Sermon Trim icon: a clip on a timeline that fades out, with a blade cutting through it.
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let S = CGFloat(size)

// macOS icon grid: rounded square inset ~10%
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = CGPath(roundedRect: rect, cornerWidth: 184, cornerHeight: 184, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(bg); ctx.setFillColor(CGColor(red: 0.1, green: 0.14, blue: 0.4, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.20, green: 0.42, blue: 0.98, alpha: 1),
                                                 CGColor(red: 0.07, green: 0.10, blue: 0.36, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 700, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// soft top highlight
let hi = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.28), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hi, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

// Clip bar fading to black on the right
let bar = CGRect(x: 190, y: 400, width: 644, height: 224)
let barPath = CGPath(roundedRect: bar, cornerWidth: 56, cornerHeight: 56, transform: nil)
ctx.saveGState()
ctx.addPath(barPath); ctx.clip()
ctx.setFillColor(CGColor(gray: 1, alpha: 0.96)); ctx.fill(bar)
let fade = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 0.04, alpha: 0), CGColor(red: 0.04, green: 0.06, blue: 0.2, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fade, start: CGPoint(x: 520, y: 0), end: CGPoint(x: 834, y: 0), options: [])
// frame ticks along the bar
ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.95, alpha: 0.35))
var x: CGFloat = 226
while x < 520 { ctx.fill(CGRect(x: x, y: 424, width: 14, height: 30)); ctx.fill(CGRect(x: x, y: 570, width: 14, height: 30)); x += 42 }
ctx.restoreGState()

// Blade: vertical cut line with a little playhead cap
let bx: CGFloat = 470
ctx.setStrokeColor(CGColor(red: 1, green: 0.62, blue: 0.2, alpha: 1))
ctx.setLineWidth(22); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: bx, y: 330)); ctx.addLine(to: CGPoint(x: bx, y: 694)); ctx.strokePath()
ctx.setFillColor(CGColor(red: 1, green: 0.62, blue: 0.2, alpha: 1))
let cap = CGMutablePath()
cap.move(to: CGPoint(x: bx - 52, y: 760)); cap.addLine(to: CGPoint(x: bx + 52, y: 760)); cap.addLine(to: CGPoint(x: bx, y: 676)); cap.closeSubpath()
ctx.addPath(cap); ctx.fillPath()
ctx.restoreGState()

// Border glint
ctx.addPath(bg); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); ctx.setLineWidth(4); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
