// Draws Sweep's app icon (dark drive with sparkles on a mint tile) and writes AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: a) }

func symbol(_ name: String, _ size: CGFloat, weight: NSFont.Weight) -> NSImage {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))!
}

/// The symbol's shape filled with a top-to-bottom gradient.
func filled(_ sym: NSImage, _ top: NSColor, _ bottom: NSColor) -> NSImage {
    NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r)
        NSGraphicsContext.current!.compositingOperation = .sourceIn
        NSGradient(colors: [top, bottom])!.draw(in: r, angle: -90)
        return true
    }
}

func draw(_ img: NSImage, centerX: CGFloat, centerY: CGFloat, shadow: NSShadow?) {
    NSGraphicsContext.saveGraphicsState()
    shadow?.set()
    img.draw(in: NSRect(x: centerX - img.size.width / 2, y: centerY - img.size.height / 2,
                        width: img.size.width, height: img.size.height))
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 rounded square, centred.
    let inset = s * 100 / 1024, box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let w = box.width
    let tile = NSBezierPath(roundedRect: box, xRadius: w * 0.225, yRadius: w * 0.225)
    NSGradient(colors: [rgb(0.35, 0.92, 0.78), rgb(0.08, 0.55, 0.60)])!.draw(in: tile, angle: -90)
    NSGraphicsContext.saveGraphicsState()   // soft light from the top
    tile.addClip()
    let top = NSPoint(x: box.midX, y: box.maxY)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0)])!
        .draw(fromCenter: top, radius: 0, toCenter: top, radius: w * 0.75, options: [])
    NSGraphicsContext.restoreGraphicsState()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.30)
    shadow.shadowBlurRadius = w * 0.06
    shadow.shadowOffset = NSSize(width: 0, height: -w * 0.024)
    let drive = filled(symbol("internaldrive.fill", w * 0.44, weight: .semibold), rgb(0.10, 0.13, 0.28), rgb(0.05, 0.06, 0.15))
    draw(drive, centerX: box.midX, centerY: box.midY - w * 0.06, shadow: shadow)

    let glow = NSShadow()
    glow.shadowColor = NSColor(white: 1, alpha: 0.9)
    glow.shadowBlurRadius = w * 0.06
    for (fx, fy, scale) in [(0.76, 0.75, 0.22), (0.62, 0.86, 0.10)] {
        let spark = filled(symbol("sparkle", w * scale, weight: .bold), .white, .white)
        draw(spark, centerX: box.minX + w * fx, centerY: box.minY + w * fy, shadow: glow)
    }

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory() + "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote AppIcon.icns" : "iconutil failed")
