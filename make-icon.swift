// Draws icon.png (1024 px) and AppIcon.icns. Run: swift make-icon.swift
// A trackpad on GuruHat's blue-to-violet tile, with a brightness slider on its left
// edge and a volume slider on its right.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset = size * 0.09
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
NSGradient(starting: NSColor(red: 0.16, green: 0.42, blue: 0.98, alpha: 1),
           ending: NSColor(red: 0.42, green: 0.20, blue: 0.86, alpha: 1))!.draw(in: tile, angle: -60)

// The trackpad.
let pad = NSRect(x: size * 0.25, y: size * 0.27, width: size * 0.50, height: size * 0.46)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = size * 0.03
shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
shadow.set()
NSColor.white.setFill()
NSBezierPath(roundedRect: pad, xRadius: size * 0.06, yRadius: size * 0.06).fill()
NSGraphicsContext.current?.restoreGraphicsState()

// The two edge sliders: a track, then the filled part.
func slider(x: Double, fill: Double, color: NSColor) {
    let w = size * 0.045
    let track = NSRect(x: x - w / 2, y: pad.minY + size * 0.06, width: w, height: pad.height - size * 0.12)
    NSColor(white: 0.88, alpha: 1).setFill()
    NSBezierPath(roundedRect: track, xRadius: w / 2, yRadius: w / 2).fill()
    let level = NSRect(x: track.minX, y: track.minY, width: w, height: track.height * fill)
    color.setFill()
    NSBezierPath(roundedRect: level, xRadius: w / 2, yRadius: w / 2).fill()
}
slider(x: pad.minX + size * 0.07, fill: 0.55, color: NSColor(red: 1.0, green: 0.62, blue: 0.10, alpha: 1))
slider(x: pad.maxX - size * 0.07, fill: 0.78, color: NSColor(red: 0.26, green: 0.38, blue: 1.0, alpha: 1))
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon.png"))

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TocaPad.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let small = NSImage(size: NSSize(width: px, height: px))
    small.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    small.unlockFocus()
    let data = NSBitmapImageRep(data: small.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    if px <= 512 { try! data.write(to: iconset.appendingPathComponent("icon_\(px)x\(px).png")) }
    if px >= 32 { try! data.write(to: iconset.appendingPathComponent("icon_\(px / 2)x\(px / 2)@2x.png")) }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "AppIcon.icns"]
try! task.run(); task.waitUntilExit()
