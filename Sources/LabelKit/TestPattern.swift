import AppKit
import CoreImage
import CoreText

public enum TestPattern {
    /// Digits only: Code 128 packs two per character, so the bars stay wide enough to scan even on small labels.
    public static let barcodeText = "123456"

    /// A label-sized page: border 2 mm in, centre rulers with mm ticks, a QR code, a Code 128 barcode,
    /// a Data Matrix and a title. Shows offset (border distance per edge), scale (ruler) and scan quality
    /// for each kind of code.
    public static func page(size: LabelSize, title: String) -> SourcePage {
        let r = CGRect(origin: .zero, size: size.points)
        return SourcePage(size: r.size) { ctx in
            let mm: CGFloat = 72 / 25.4
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.setLineWidth(0.75)
            ctx.stroke(r.insetBy(dx: 2 * mm, dy: 2 * mm))
            ctx.setLineWidth(0.5)
            // Rulers through the centre, with a gap where they cross and numbers every 10 mm.
            // The vertical one stops below the title.
            let gap = 4 * mm, titleBottom = r.height - 15 * mm
            let numberFont = CTFontCreateUIFontForLanguage(.system, 6, nil)!
            func number(_ value: Int, at point: CGPoint) {
                let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): numberFont,
                                                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(value)", attributes: attrs))
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: point.x - CGFloat(w) / 2, y: point.y)
                CTLineDraw(line, ctx)
            }
            for x in stride(from: 0, through: r.width, by: mm) where abs(x - r.midX) > gap {
                let tick = Int((x / mm).rounded())
                let h: CGFloat = tick % 10 == 0 ? 3 : tick % 5 == 0 ? 2.2 : 1.5
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: r.midY - h * mm), CGPoint(x: x, y: r.midY + h * mm)])
                if tick % 10 == 0 && tick > 0 && x < r.width - 2 * mm { number(tick, at: CGPoint(x: x, y: r.midY - 3 * mm - 7)) }
            }
            for y in stride(from: 0, through: titleBottom, by: mm) where abs(y - r.midY) > gap {
                let tick = Int((y / mm).rounded())
                let h: CGFloat = tick % 10 == 0 ? 3 : tick % 5 == 0 ? 2.2 : 1.5
                ctx.strokeLineSegments(between: [CGPoint(x: r.midX - h * mm, y: y), CGPoint(x: r.midX + h * mm, y: y)])
                if tick % 10 == 0 && tick > 0 { number(tick, at: CGPoint(x: r.midX + 3 * mm + 6, y: y - 2)) }
            }
            let side = min(r.width, r.height) * 0.35
            if let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("peelgood-test \(size)".utf8)])?.outputImage {
                fillModules(ctx, modules(of: qr), in: CGRect(x: 5 * mm, y: 5 * mm, width: side, height: side))
            }
            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, max(6, min(r.width, r.height) / 16), nil)!
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            for (i, line) in [title, "border 2 mm in from each edge · numbers in mm"].enumerated() {
                let scale: CGFloat = i == 0 ? 1 : 0.55
                var a = attrs
                a[NSAttributedString.Key(kCTFontAttributeName as String)] = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
                ctx.textPosition = CGPoint(x: 5 * mm, y: r.height - 5 * mm - CTFontGetSize(font) * (i == 0 ? 1 : 1.9))
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: a)), ctx)
            }
            // A barcode and a Data Matrix in the upper quarters, between the subtitle and the rulers, when
            // there's room: below 12 mm a code wouldn't scan anyway.
            let top = min(titleBottom, r.height - 5 * mm - CTFontGetSize(font) * 2.2) - 2 * mm, bottom = r.midY + 6 * mm
            let room = top - bottom
            let leftWidth = r.midX - 10 * mm, rightWidth = r.width - 5 * mm - (r.midX + 12 * mm)
            if room >= 12 * mm, leftWidth >= 20 * mm,
               let bars = CIFilter(name: "CICode128BarcodeGenerator", parameters: ["inputMessage": Data(barcodeText.utf8), "inputQuietSpace": 0])?.outputImage {
                // Bars 0.40 mm wide: about 3 dots once the page is fitted inside its padding (≈95 %) on 200 and
                // 203 dpi heads, so fitting the barcode to whole dots doesn't shrink the label. Code 128's quiet
                // zone of 10 bars each side; left out where that doesn't fit.
                let pattern = modules(of: bars).first ?? []
                let x = 0.40 * mm, height = min(room, leftWidth * 0.5)
                if x * CGFloat(pattern.count + 20) <= leftWidth {
                    fillBars(ctx, pattern, in: CGRect(x: 5 * mm + 10 * x, y: top - height, width: x * CGFloat(pattern.count), height: height))
                }
            }
            if room >= 12 * mm, rightWidth >= 12 * mm, let matrix = DataMatrix.encode("peelgood-dm \(size)") {
                let s = min(rightWidth, room, side * 0.8)
                fillModules(ctx, matrix, in: CGRect(x: r.width - 5 * mm - s, y: top - s, width: s, height: s))
            }
        }
    }

    /// The step wedge's patches: requested coverage 0, 10, ..., 100 %.
    public static let wedgeSteps = (0...10).map { Double($0) / 10 }

    /// The sRGB gray that asks for `coverage` (0 white, 1 black) once converted to linear light.
    public static func wedgeGray(_ coverage: Double) -> CGFloat {
        let lin = 1 - coverage
        let v = lin <= 0.0031308 ? lin * 12.92 : 1.055 * pow(lin, 1 / 2.4) - 0.055
        return CGFloat(min(1, max(0, v)))
    }

    /// Calibration page: 11 gray patches from 0 to 100 % coverage, each labelled, in two columns.
    /// Print it in Photo or Halftone with tone compensation off (toneGamma 1) and measure each patch.
    public static func stepWedge(size: LabelSize, title: String = "Step wedge") -> SourcePage {
        let r = CGRect(origin: .zero, size: size.points)
        return SourcePage(size: r.size) { ctx in
            let mm: CGFloat = 72 / 25.4
            let margin = 4 * mm, labelW = 12 * mm, gap = 1.5 * mm
            let titleH = 9 * mm
            func text(_ s: String, _ p: CGPoint, _ size: CGFloat, bold: Bool = false) {
                let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
                let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
                ctx.textPosition = p
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs)), ctx)
            }
            let fontSize = max(6, min(r.width, r.height) / 22)
            text(title, CGPoint(x: margin, y: r.height - margin - fontSize), fontSize, bold: true)
            // Patches in a column down the page, two columns when the label is wide.
            let columns = r.width > r.height ? 2 : 1
            let perColumn = (wedgeSteps.count + columns - 1) / columns
            let colW = (r.width - 2 * margin - CGFloat(columns - 1) * 3 * mm) / CGFloat(columns)
            let top = r.height - margin - titleH
            let rowH = (top - margin) / CGFloat(perColumn)
            for (i, c) in wedgeSteps.enumerated() {
                let col = i / perColumn, row = i % perColumn
                let x = margin + CGFloat(col) * (colW + 3 * mm)
                let y = top - CGFloat(row + 1) * rowH
                let patch = CGRect(x: x + labelW, y: y + gap / 2, width: colW - labelW, height: rowH - gap)
                ctx.setFillColor(gray: wedgeGray(c), alpha: 1)
                ctx.fill(patch)
                ctx.setStrokeColor(gray: 0, alpha: 1)
                ctx.setLineWidth(0.5)
                ctx.stroke(patch)
                text("\(Int((c * 100).rounded()))%", CGPoint(x: x, y: y + rowH / 2 - fontSize * 0.35), fontSize * 0.8)
            }
        }
    }

    /// A generated code's modules, one per pixel, row 0 at the top, true = dark.
    static func modules(of code: CIImage) -> [[Bool]] {
        let w = Int(code.extent.width), h = Int(code.extent.height)
        var pixels = [UInt8](repeating: 255, count: w * h)
        CIContext().render(code, toBitmap: &pixels, rowBytes: w, bounds: code.extent, format: .L8, colorSpace: nil)
        return (0..<h).map { y in (0..<w).map { x in pixels[y * w + x] < 128 } }
    }

    /// Draws modules as filled squares across the rect's width, so the code stays sharp at any scale.
    static func fillModules(_ ctx: CGContext, _ grid: [[Bool]], in rect: CGRect) {
        guard let cols = grid.first?.count, cols > 0 else { return }
        let m = rect.width / CGFloat(cols)
        for (y, row) in grid.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                ctx.fill(CGRect(x: rect.minX + CGFloat(x) * m, y: rect.maxY - CGFloat(y + 1) * m, width: m, height: m))
            }
        }
    }

    /// Draws a linear barcode's bars across the rect.
    static func fillBars(_ ctx: CGContext, _ bars: [Bool], in rect: CGRect) {
        guard !bars.isEmpty else { return }
        let m = rect.width / CGFloat(bars.count)
        for (x, dark) in bars.enumerated() where dark {
            ctx.fill(CGRect(x: rect.minX + CGFloat(x) * m, y: rect.minY, width: m, height: rect.height))
        }
    }
}

extension TestPattern {
    /// The test pattern with a smooth gray ramp in the lower right, so each ink mode shows its character.
    public static func inkSample(size: LabelSize, title: String) -> SourcePage {
        let s = size.points
        return SourcePage(size: s) { ctx in
            page(size: size, title: title).draw(in: ctx)
            let ramp = CGRect(x: s.width * 0.55, y: 14, width: s.width * 0.4, height: s.height * 0.3)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                  colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: nil) {
                ctx.saveGState()
                ctx.clip(to: ramp)
                ctx.drawLinearGradient(g, start: CGPoint(x: ramp.minX, y: 0), end: CGPoint(x: ramp.maxX, y: 0), options: [])
                ctx.restoreGState()
            }
        }
    }
}
