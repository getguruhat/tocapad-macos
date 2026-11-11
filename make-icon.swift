// Draws icon.png (1024 px) and AppIcon.icns. Run: swift make-icon.swift
// A fingertip resting on the right edge of a dark trackpad, with touch ripples and the
// edge lit in GuruHat blue up to the finger, as the volume would be.
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
func withShadow(_ color: NSColor, blur: Double, y: Double = 0, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: y)
    s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

let glow = rgb(110, 136, 255)
let glowDeep = rgb(67, 98, 255)

// The tile: deep ink, a little lighter at the top.
let inset = size * 0.09
let tileRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: tileRect.width * 0.225, yRadius: tileRect.width * 0.225)
NSGradient(starting: rgb(36, 46, 64), ending: rgb(10, 14, 22))!.draw(in: tile, angle: -90)
NSGraphicsContext.saveGraphicsState()
tile.addClip()

// The trackpad: a glassy slab with a hairline highlight.
let pad = NSRect(x: 196, y: 318, width: 632, height: 420)
let padPath = NSBezierPath(roundedRect: pad, xRadius: 54, yRadius: 54)
withShadow(NSColor.black.withAlphaComponent(0.5), blur: 40, y: -16) {
    rgb(30, 38, 53).setFill()
    padPath.fill()
}
NSGradient(starting: rgb(58, 70, 92), ending: rgb(33, 41, 57))!.draw(in: padPath, angle: -90)
rgb(255, 255, 255, 0.14).setStroke()
padPath.lineWidth = 4
padPath.stroke()

// The right edge: a faint track, lit in glow from the bottom up to the finger.
let contact = NSPoint(x: pad.maxX - 62, y: 655)
let trackW = 30.0
let track = NSRect(x: contact.x - trackW / 2, y: pad.minY + 46, width: trackW, height: pad.height - 92)
rgb(255, 255, 255, 0.08).setFill()
NSBezierPath(roundedRect: track, xRadius: trackW / 2, yRadius: trackW / 2).fill()
let lit = NSRect(x: track.minX, y: track.minY, width: trackW, height: contact.y - track.minY)
withShadow(glow.withAlphaComponent(0.85), blur: 36) {
    NSGradient(starting: glowDeep, ending: glow)!.draw(in: NSBezierPath(roundedRect: lit, xRadius: trackW / 2, yRadius: trackW / 2), angle: 90)
}

// Ripples where the finger touches.
for (radius, alpha) in [(88.0, 0.6), (128.0, 0.3), (168.0, 0.13)] {
    let ring = NSBezierPath(ovalIn: NSRect(x: contact.x - radius, y: contact.y - radius, width: radius * 2, height: radius * 2))
    ring.lineWidth = 9
    glow.withAlphaComponent(alpha).setStroke()
    ring.stroke()
}

// The finger, coming in from the bottom right, its tip on the edge.
NSGraphicsContext.saveGraphicsState()
let turn = NSAffineTransform()
turn.translateX(by: contact.x, yBy: contact.y)
turn.rotate(byDegrees: 42)
turn.concat()
let fingerW = 156.0
let finger = NSBezierPath(roundedRect: NSRect(x: -fingerW / 2, y: -900, width: fingerW, height: 900 + 78),
                          xRadius: fingerW / 2, yRadius: fingerW / 2)
withShadow(NSColor.black.withAlphaComponent(0.55), blur: 46, y: -22) {
    rgb(244, 232, 222).setFill()
    finger.fill()
}
NSGradient(colors: [rgb(226, 204, 188), rgb(250, 240, 232), rgb(255, 248, 242), rgb(232, 212, 198)],
           atLocations: [0, 0.38, 0.55, 1], colorSpace: .sRGB)!.draw(in: finger, angle: 0)
// The nail.
let nail = NSBezierPath(roundedRect: NSRect(x: -50, y: -104, width: 100, height: 150), xRadius: 46, yRadius: 46)
NSGradient(starting: rgb(255, 236, 232), ending: rgb(246, 214, 208))!.draw(in: nail, angle: 90)
rgb(196, 160, 150, 0.6).setStroke()
nail.lineWidth = 4
nail.stroke()
// A knuckle crease further down.
let crease = NSBezierPath()
crease.move(to: NSPoint(x: -46, y: -300))
crease.curve(to: NSPoint(x: 46, y: -300), controlPoint1: NSPoint(x: -20, y: -314), controlPoint2: NSPoint(x: 20, y: -314))
crease.lineWidth = 6
crease.lineCapStyle = .round
rgb(196, 166, 150, 0.55).setStroke()
crease.stroke()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()  // tile clip
// A soft inner edge on the tile.
rgb(255, 255, 255, 0.10).setStroke()
tile.lineWidth = 4
tile.stroke()
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon.png"))
let image = NSImage(size: NSSize(width: size, height: size))
image.addRepresentation(rep)

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TocaPad.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let data = small.representation(using: .png, properties: [:])!
    if px <= 512 { try! data.write(to: iconset.appendingPathComponent("icon_\(px)x\(px).png")) }
    if px >= 32 { try! data.write(to: iconset.appendingPathComponent("icon_\(px / 2)x\(px / 2)@2x.png")) }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "AppIcon.icns"]
try! task.run(); task.waitUntilExit()
