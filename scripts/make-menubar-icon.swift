// Draws the menu bar glyph: a front view of the label printer from docs/brand/icon.svg with a
// label (text lines and barcode) coming out of its slot. Template images, black on clear:
// macOS tints them for light/dark menu bars. Two vector PDFs, 18 x 16 pt:
//   menubar.pdf         outline (idle), 1.5 pt strokes
//   menubar-filled.pdf  solid (a file hovers over the icon), details knocked out
// Usage: swift scripts/make-menubar-icon.swift Resources
import CoreGraphics
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let size = CGSize(width: 18, height: 16)
let stroke: CGFloat = 1.5

// Geometry in points, origin bottom left. Stroke centres sit on quarter points so the 1.5 pt
// lines land on whole pixels at 2x; the label marks are whole-point rects, crisp at 1x too.
let body = CGRect(x: 1.25, y: 6.5, width: 15.5, height: 8)          // printer housing (centre line)
let bodyRadius: CGFloat = 3
let label = CGRect(x: 4.25, y: 1.25, width: 9.5, height: 7.5)       // sheet (centre line), top in the slot
let slotY: CGFloat = 8.75                                           // paper exit slot
let slotInset: CGFloat = 1.5
let button = CGPoint(x: 13, y: 12)                                  // the coral control button
let buttonRadius: CGFloat = 1.25

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func buttonRect() -> CGRect {
    CGRect(x: button.x - buttonRadius, y: button.y - buttonRadius, width: 2 * buttonRadius, height: 2 * buttonRadius)
}

/// A text line and a barcode on the label.
let labelMarks = [
    CGRect(x: 6, y: 6, width: 6, height: 1),                         // text line
    CGRect(x: 6, y: 3, width: 1, height: 2),                         // barcode
    CGRect(x: 8, y: 3, width: 2, height: 2),
    CGRect(x: 11, y: 3, width: 1, height: 2),
]

func drawOutline(_ c: CGContext) {
    c.setLineWidth(stroke)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    // Housing, interrupted where the label passes in front of it.
    c.saveGState()
    c.addRect(CGRect(origin: .zero, size: size))
    c.addRect(CGRect(x: label.minX, y: 0, width: label.width, height: slotY))
    c.clip(using: .evenOdd)
    c.addPath(roundedRect(body, bodyRadius))
    c.strokePath()
    c.restoreGState()
    // Slot across the front.
    c.move(to: CGPoint(x: body.minX + slotInset, y: slotY))
    c.addLine(to: CGPoint(x: body.maxX - slotInset, y: slotY))
    c.strokePath()
    // Label: sides and bottom, open at the top where it leaves the slot.
    c.move(to: CGPoint(x: label.minX, y: slotY))
    c.addLine(to: CGPoint(x: label.minX, y: label.minY + 1))
    c.addArc(tangent1End: CGPoint(x: label.minX, y: label.minY), tangent2End: CGPoint(x: label.midX, y: label.minY), radius: 1)
    c.addArc(tangent1End: CGPoint(x: label.maxX, y: label.minY), tangent2End: CGPoint(x: label.maxX, y: label.minY + 1), radius: 1)
    c.addLine(to: CGPoint(x: label.maxX, y: slotY))
    c.strokePath()
    for m in labelMarks { c.fill(m) }
    c.fillEllipse(in: buttonRect())
}

func drawFilled(_ c: CGContext) {
    let half = stroke / 2
    let outer = body.insetBy(dx: -half, dy: -half)
    let sheet = CGRect(x: label.minX - half, y: label.minY - half, width: label.width + stroke, height: slotY - 0.5 - (label.minY - half))
    let gap: CGFloat = 1
    // Housing with the button, the slot and a gap around the label knocked out.
    c.addPath(roundedRect(outer, bodyRadius + half))
    c.addEllipse(in: buttonRect())
    let slotX = outer.minX + slotInset + half
    c.addRect(CGRect(x: slotX, y: slotY - 0.5, width: outer.maxX - slotInset - half - slotX, height: 1))
    c.addRect(CGRect(x: sheet.minX - gap, y: outer.minY - 1, width: sheet.width + 2 * gap, height: slotY - 0.5 - outer.minY + 1))
    c.fillPath(using: .evenOdd)
    // Label in front, marks knocked out.
    c.addPath(roundedRect(sheet, 1.5))
    for m in labelMarks { c.addRect(m) }
    c.fillPath(using: .evenOdd)
}

func writePDF(_ name: String, _ draw: (CGContext) -> Void) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    var box = CGRect(origin: .zero, size: size)
    let c = CGContext(url as CFURL, mediaBox: &box, nil)!
    c.beginPDFPage(nil)
    c.setFillColor(CGColor(gray: 0, alpha: 1))
    c.setStrokeColor(CGColor(gray: 0, alpha: 1))
    draw(c)
    c.endPDFPage()
    c.closePDF()
    print("wrote \(url.path)")
}

writePDF("menubar.pdf", drawOutline)
writePDF("menubar-filled.pdf", drawFilled)
