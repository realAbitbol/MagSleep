// Renders a polished MagSleep app icon: moon on a dark rounded square.
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
    NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.26, alpha: 1),
    NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.09, alpha: 1),
])?.draw(in: bgRect, angle: -90)

let moonCenter = CGPoint(x: size * 0.52, y: size * 0.50)
let moonRadius = size * 0.22

let cx1 = moonCenter.x, cy1 = moonCenter.y, r1 = moonRadius

let cutoutRect = CGRect(
    x: moonCenter.x - moonRadius * 0.25,
    y: moonCenter.y - moonRadius * 0.55,
    width: moonRadius * 1.7,
    height: moonRadius * 1.7
)
let cx2 = cutoutRect.midX, cy2 = cutoutRect.midY, r2 = cutoutRect.width / 2

ctx.saveGState()
let glowColor1 = CGColor(red: 0.45, green: 0.55, blue: 0.85, alpha: 0.12)
let glowColor2 = CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
if let glowGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [glowColor1, glowColor2] as CFArray,
    locations: nil
) {
    // Start radius is 0 so it fades smoothly outward from the center
    ctx.drawRadialGradient(
        glowGradient,
        startCenter: moonCenter,
        startRadius: 0,
        endCenter: moonCenter,
        endRadius: moonRadius * 2.5,
        options: []
    )
}
ctx.restoreGState()

let dx = cx2 - cx1, dy = cy2 - cy1
let d = hypot(dx, dy)
let a = (r1*r1 - r2*r2 + d*d) / (2*d)
let h = sqrt(max(0, r1*r1 - a*a))

let px = cx1 + a*dx/d, py = cy1 + a*dy/d
let ox = h*dy/d, oy = -h*dx/d

let p1 = CGPoint(x: px + ox, y: py + oy)
let p2 = CGPoint(x: px - ox, y: py - oy)

let a1 = atan2(p1.y - cy1, p1.x - cx1)
let a2 = atan2(p2.y - cy1, p2.x - cx1)
let b1 = atan2(p1.y - cy2, p1.x - cx2)
let b2 = atan2(p2.y - cy2, p2.x - cx2)

let crescentPath = CGMutablePath()
crescentPath.move(to: p1)
crescentPath.addArc(center: CGPoint(x: cx1, y: cy1), radius: r1, startAngle: a1, endAngle: a2, clockwise: true)
crescentPath.addArc(center: CGPoint(x: cx2, y: cy2), radius: r2, startAngle: b2, endAngle: b1, clockwise: false)
crescentPath.closeSubpath()

ctx.saveGState()
ctx.addPath(crescentPath)
ctx.clip()

let moonGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.99, alpha: 1.0),
    NSColor(calibratedRed: 0.72, green: 0.76, blue: 0.86, alpha: 1.0)
])
moonGradient?.draw(in: CGRect(x: 0, y: 0, width: size, height: size), angle: 135)

ctx.restoreGState()

let borderPath = NSBezierPath(roundedRect: bgRect, xRadius: size * 0.18, yRadius: size * 0.18)
borderPath.lineWidth = 1.5
NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.4).setStroke()
borderPath.stroke()

ctx.flush()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("error: could not write \(outputPath): \(error)\n", stderr)
    exit(1)
}
print("wrote \(outputPath)")
