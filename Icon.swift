// swift Icon.swift AppIcon.icns : regenerates the committed app icon, the menu bar glyph on a dark rounded square.
// Kept out of the build because AppKit drawing does not work inside Homebrew's sandbox.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let set = out.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let plate = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: s * 0.22, yRadius: s * 0.22)
    NSGradient(starting: NSColor(white: 0.20, alpha: 1), ending: NSColor(white: 0.05, alpha: 1))!.draw(in: plate, angle: -90)
    // The menu bar glyph on its 18-unit grid, scaled to 60% of the plate and centred.
    let u = s * 0.6 / 18, ox = (s - 18 * u) / 2, oy = (s - 18 * u) / 2 - 0.4 * u
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: ox + 1 * u, y: oy + 12.25 * u, width: 3 * u, height: 3 * u)).fill()
    for (i, w) in [12.0, 9, 6].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: ox + 6 * u, y: oy + (12.5 - Double(i) * 4.5) * u, width: w * u, height: 2.5 * u),
                     xRadius: 1.25 * u, yRadius: 1.25 * u).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
let pack = Process()
pack.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
pack.arguments = ["-c", "icns", set.path, "-o", out.path]
try! pack.run()
pack.waitUntilExit()
try? FileManager.default.removeItem(at: set)
exit(pack.terminationStatus)
