// Renders a simple MagSleep app icon: moon on a dark rounded square.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

let inset: CGFloat = size * 0.08
let bgRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: size * 0.18, yRadius: size * 0.18)
bgPath.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.28, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.14, alpha: 1),
])?.draw(in: bgRect, angle: -90)

let moonCenter = CGPoint(x: size * 0.48, y: size * 0.52)
let moonRadius = size * 0.22
NSColor(calibratedRed: 0.85, green: 0.88, blue: 0.95, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(
    x: moonCenter.x - moonRadius,
    y: moonCenter.y - moonRadius,
    width: moonRadius * 2,
    height: moonRadius * 2
)).fill()

NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.20, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(
    x: moonCenter.x - moonRadius * 0.25,
    y: moonCenter.y - moonRadius * 0.55,
    width: moonRadius * 1.7,
    height: moonRadius * 1.7
)).fill()

ctx.flush()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
