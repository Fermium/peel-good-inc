// Renders the app icon into an .icns: the printer artwork (docs/brand/icon.svg) on a
// macOS-style rounded square with a warm off-white gradient, hairline edge and soft shadow.
// Usage: swiftc -O scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon docs/brand/icon.svg Resources/Labelize.icns
import AppKit

let args = CommandLine.arguments
let art = NSImage(contentsOf: URL(fileURLWithPath: args[1]))!
let out = args[2]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Labelize.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    // Apple's grid: an 824 pt body centred on a 1024 pt canvas, corner radius about 185.
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = 22 * k
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(red: 1.0, green: 0.992, blue: 0.965, alpha: 1), NSColor(red: 0.925, green: 0.906, blue: 0.86, alpha: 1)])!
        .draw(in: shape, angle: -90)
    NSColor(white: 0, alpha: 0.08).setStroke()
    shape.lineWidth = max(1, 2 * k)
    shape.stroke()

    // The printer fills about 74% of the body, nudged up a touch so the label has room below.
    let maxSide = 610 * k
    let s = min(maxSide / art.size.width, maxSide / art.size.height)
    let w = art.size.width * s, h = art.size.height * s
    art.draw(in: NSRect(x: body.midX - w / 2, y: body.midY - h / 2 + 8 * k, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if args.count > 3 { try render(1024).write(to: URL(fileURLWithPath: args[3])) }   // optional preview PNG
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try task.run()
task.waitUntilExit()
