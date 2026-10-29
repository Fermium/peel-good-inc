import AppKit
import CoreText
import LabelKit

/// A gray ramp: eleven 10% steps from white to black and a smooth gradient beside them, each step
/// labelled. Printed once per ink mode it shows which keeps grays apart.
/// If LabelKit gains its own step wedge (branch `dither`), use that here instead.
enum StepWedge {
    static func page(size: LabelSize, title: String) -> SourcePage {
        let r = CGRect(origin: .zero, size: size.points)
        return SourcePage(size: r.size) { ctx in
            let mm: CGFloat = 72 / 25.4
            let inner = r.insetBy(dx: 3 * mm, dy: 3 * mm)
            let titleHeight = min(8 * mm, inner.height * 0.12)
            let font = CTFontCreateUIFontForLanguage(.system, min(9, titleHeight * 0.8), nil)!

            func text(_ s: String, center: CGPoint, white: Bool, size: CGFloat) {
                let f = CTFontCreateCopyWithAttributes(font, size, nil, nil)
                let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: white ? 1 : 0, alpha: 1)]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: center.x - CGFloat(w) / 2, y: center.y - size * 0.35)
                CTLineDraw(line, ctx)
            }

            text(title, center: CGPoint(x: inner.midX, y: inner.maxY - titleHeight / 2), white: false, size: min(9, titleHeight * 0.8))
            let body = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height - titleHeight - 1 * mm)
            let tall = body.height >= body.width
            // Steps take 75% of the short side, the gradient the rest.
            let stepsArea: CGRect, rampArea: CGRect
            if tall {
                stepsArea = CGRect(x: body.minX, y: body.minY, width: body.width * 0.72, height: body.height)
                rampArea = CGRect(x: body.minX + body.width * 0.78, y: body.minY, width: body.width * 0.22, height: body.height)
            } else {
                rampArea = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.22)
                stepsArea = CGRect(x: body.minX, y: body.minY + body.height * 0.28, width: body.width, height: body.height * 0.72)
            }
            let steps = 11
            for i in 0..<steps {
                let level = Double(i) / Double(steps - 1)   // 0 white ... 1 black
                let cell: CGRect = tall
                    ? CGRect(x: stepsArea.minX, y: stepsArea.maxY - CGFloat(i + 1) * stepsArea.height / CGFloat(steps),
                             width: stepsArea.width, height: stepsArea.height / CGFloat(steps))
                    : CGRect(x: stepsArea.minX + CGFloat(i) * stepsArea.width / CGFloat(steps), y: stepsArea.minY,
                             width: stepsArea.width / CGFloat(steps), height: stepsArea.height)
                ctx.setFillColor(gray: 1 - level, alpha: 1)
                ctx.fill(cell)
                let labelSize = min(8, min(cell.width, cell.height) * 0.45)
                text("\(Int(level * 100))%", center: CGPoint(x: cell.midX, y: cell.midY), white: level >= 0.5, size: labelSize)
            }
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.setLineWidth(0.5)
            ctx.stroke(stepsArea)

            let space = CGColorSpaceCreateDeviceGray()
            let gradient = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1])!
            ctx.saveGState()
            ctx.clip(to: rampArea)
            let start = tall ? CGPoint(x: rampArea.midX, y: rampArea.maxY) : CGPoint(x: rampArea.minX, y: rampArea.midY)
            let end = tall ? CGPoint(x: rampArea.midX, y: rampArea.minY) : CGPoint(x: rampArea.maxX, y: rampArea.midY)
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
            ctx.restoreGState()
            ctx.stroke(rampArea)
        }
    }
}
