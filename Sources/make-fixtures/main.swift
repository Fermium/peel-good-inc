// Generates test inputs in ./Fixtures: shipping labels on Letter pages, a phone screenshot
// of a return QR code, and SVGs. Codes are real (Core Image generators) so Vision can read them.
import AppKit
import CoreImage
import CoreText
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Fixtures")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

func text(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, bold: Bool = false, gray: CGFloat = 0) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
    ]
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs)), ctx)
}

func centered(_ ctx: CGContext, _ s: String, _ midX: CGFloat, _ y: CGFloat, _ size: CGFloat, bold: Bool = false, gray: CGFloat = 0) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    text(ctx, s, midX - CGFloat(w) / 2, y, size, bold: bold, gray: gray)
}

func code(_ filter: String, _ message: String) -> CGImage {
    let f = CIFilter(name: filter)!
    f.setValue(Data(message.utf8), forKey: "inputMessage")
    if filter == "CIQRCodeGenerator" { f.setValue("M", forKey: "inputCorrectionLevel") }
    if filter == "CICode128BarcodeGenerator" { f.setValue(0, forKey: "inputQuietSpace") }
    let out = f.outputImage!
    return CIContext().createCGImage(out, from: out.extent)!
}

func drawCode(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.interpolationQuality = .none
    ctx.draw(image, in: rect)
    ctx.restoreGState()
}

func paragraph(_ ctx: CGContext, x: CGFloat, top: CGFloat, width: CGFloat, lines: Int, size: CGFloat = 9) {
    let words = "Print this label and attach it securely to your package. Do not cover the barcode with tape. Drop off at any post office or schedule a pickup online. Keep the receipt for tracking.".split(separator: " ")
    var line = "", y = top, n = 0, i = 0
    while n < lines {
        let w = String(words[i % words.count]); i += 1
        if CGFloat(line.count + w.count) * size * 0.5 > width {
            text(ctx, line, x, y, size); y -= size * 1.4; n += 1; line = ""
        }
        line += (line.isEmpty ? "" : " ") + w
    }
}

/// A 4x6 portrait shipping label drawn in `rect` (288x432 pt).
func shippingLabel(_ ctx: CGContext, at origin: CGPoint, carrier: String, tracking: String) {
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.setStrokeColor(gray: 0, alpha: 1)
    ctx.setLineWidth(2)
    ctx.stroke(CGRect(x: 1, y: 1, width: 286, height: 430))
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 1, y: 372, width: 286, height: 59))
    text(ctx, carrier, 14, 392, 24, bold: true, gray: 1)
    ctx.fill(CGRect(x: 1, y: 370, width: 286, height: 2))
    text(ctx, "FROM: Fermium Labs, 12 Via Roma, Torino IT", 12, 352, 8)
    text(ctx, "SHIP TO:", 12, 318, 10, bold: true)
    text(ctx, "JANE DOE", 40, 296, 16, bold: true)
    text(ctx, "1234 MAPLE AVENUE APT 5", 40, 278, 13)
    text(ctx, "SPRINGFIELD IL 62704-1234", 40, 260, 13)
    ctx.fill(CGRect(x: 1, y: 236, width: 286, height: 2))
    text(ctx, "\(carrier) TRACKING #", 60, 216, 10, bold: true)
    drawCode(ctx, code("CICode128BarcodeGenerator", tracking), in: CGRect(x: 24, y: 120, width: 240, height: 86))
    centered(ctx, tracking, 144, 102, 11)
    ctx.fill(CGRect(x: 1, y: 88, width: 286, height: 2))
    drawCode(ctx, code("CIQRCodeGenerator", "https://track.example/\(tracking)"), in: CGRect(x: 14, y: 12, width: 66, height: 66))
    text(ctx, "Weight 1.2 lb   Ref #1234", 96, 50, 9)
    ctx.restoreGState()
}

func pdf(_ name: String, size: CGSize, pages: [(CGContext) -> Void]) {
    var box = CGRect(origin: .zero, size: size)
    let ctx = CGContext(dir.appendingPathComponent(name) as CFURL, mediaBox: &box, nil)!
    for draw in pages { ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage() }
    ctx.closePDF()
}

let letter = CGSize(width: 612, height: 792)

// USPS-style: portrait label top-left, receipt column on the right, instructions at the bottom.
pdf("letter-usps.pdf", size: letter, pages: [{ ctx in
    shippingLabel(ctx, at: CGPoint(x: 36, y: 324), carrier: "USPS PRIORITY", tracking: "9405511899223197428490")
    text(ctx, "Shipping Receipt", 360, 740, 14, bold: true)
    paragraph(ctx, x: 360, top: 716, width: 216, lines: 14)
    ctx.setLineDash(phase: 0, lengths: [6, 4]); ctx.setStrokeColor(gray: 0.4, alpha: 1)
    ctx.strokeLineSegments(between: [CGPoint(x: 36, y: 300), CGPoint(x: 576, y: 300)])
    text(ctx, "Instructions", 36, 270, 14, bold: true)
    paragraph(ctx, x: 36, top: 246, width: 540, lines: 12)
}])

// UPS-style: label printed landscape across the top half, fold line, instructions below.
pdf("letter-ups-landscape.pdf", size: letter, pages: [{ ctx in
    ctx.saveGState()
    ctx.translateBy(x: 90, y: 420)
    ctx.rotate(by: .pi / 2)
    ctx.translateBy(x: 0, y: -432)
    shippingLabel(ctx, at: .zero, carrier: "UPS GROUND", tracking: "1Z999AA10123456784")
    ctx.restoreGState()
    ctx.setLineDash(phase: 0, lengths: [6, 4]); ctx.setStrokeColor(gray: 0.4, alpha: 1)
    ctx.strokeLineSegments(between: [CGPoint(x: 36, y: 380), CGPoint(x: 576, y: 380)])
    centered(ctx, "FOLD HERE", 306, 366, 8, gray: 0.4)
    text(ctx, "UPS Internet Shipping: Instructions", 36, 320, 14, bold: true)
    paragraph(ctx, x: 36, top: 296, width: 540, lines: 16)
}])

// Two label-sized pages.
pdf("two-labels.pdf", size: CGSize(width: 288, height: 432), pages: [
    { shippingLabel($0, at: .zero, carrier: "DHL", tracking: "JD014600006281234567") },
    { shippingLabel($0, at: .zero, carrier: "DHL", tracking: "JD014600006281234568") },
])

// Phone screenshot of a return QR code, 1179x2556 px like an iPhone 15.
do {
    let w = 1179, h = 2556
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let W = CGFloat(w), H = CGFloat(h)
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    text(ctx, "9:41", 120, H - 110, 46, bold: true)
    text(ctx, "▮▮▮  ◠  ▭", W - 330, H - 110, 40)
    ctx.setFillColor(red: 0.137, green: 0.184, blue: 0.243, alpha: 1)   // Amazon navy header
    ctx.fill(CGRect(x: 0, y: H - 330, width: W, height: 170))
    text(ctx, "‹  Your Returns", 50, H - 268, 52, bold: true, gray: 1)
    centered(ctx, "Show this code at drop-off", W / 2, H - 470, 54, bold: true)
    centered(ctx, "No box or label needed", W / 2, H - 545, 40, gray: 0.35)
    drawCode(ctx, code("CIQRCodeGenerator", "AMZN-RET-7Q4K9X2M8P"), in: CGRect(x: (W - 760) / 2, y: H - 1380, width: 760, height: 760))
    centered(ctx, "Return code: 7Q4K 9X2M 8P", W / 2, H - 1480, 48, bold: true)
    centered(ctx, "Return by Nov 28, 2026 · UPS Store", W / 2, H - 1550, 38, gray: 0.35)
    ctx.setFillColor(red: 1, green: 0.847, blue: 0.078, alpha: 1)       // yellow button
    ctx.addPath(CGPath(roundedRect: CGRect(x: 80, y: 520, width: W - 160, height: 130), cornerWidth: 65, cornerHeight: 65, transform: nil)); ctx.fillPath()
    centered(ctx, "Add to Apple Wallet", W / 2, 570, 44)
    ctx.setFillColor(gray: 0.95, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: 250))
    for (i, label) in ["Home", "You", "Cart", "Menu"].enumerated() {
        centered(ctx, label, W / 8 * CGFloat(2 * i + 1), 120, 32, gray: 0.4)
    }
    let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("amazon-return.png") as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

try """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300" width="400" height="300">
  <rect x="20" y="20" width="360" height="260" rx="24" fill="none" stroke="black" stroke-width="8"/>
  <circle cx="110" cy="150" r="60" fill="black"/>
  <path d="M210 90 L350 90 L280 210 Z" fill="black"/>
  <text x="200" y="260" font-family="Helvetica" font-size="28" text-anchor="middle">FRAGILE</text>
</svg>
""".write(to: dir.appendingPathComponent("logo.svg"), atomically: true, encoding: .utf8)

try """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 450" width="300" height="450">
  <defs><radialGradient id="g"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#123"/></radialGradient></defs>
  <rect width="300" height="450" fill="url(#g)"/>
  <circle cx="150" cy="200" r="90" fill="#e63"/>
</svg>
""".write(to: dir.appendingPathComponent("gradient.svg"), atomically: true, encoding: .utf8)

print("fixtures written to \(dir.path)")
