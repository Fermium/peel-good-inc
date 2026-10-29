import CoreGraphics
import Foundation

public enum CropMode: String, CaseIterable, Sendable {
    /// Find the label on a larger page; otherwise trim to the content.
    case auto
    /// Trim to everything that isn't white.
    case content
    /// Use the whole page.
    case none
}

public struct CropResult {
    /// The crop in page coordinates (points, origin bottom-left).
    public var rect: CGRect
    /// Content blocks found on the page, largest first. Empty unless label detection ran.
    public var blocks: [CGRect]
    /// Codes found on the source page, with rects in page coordinates.
    public var barcodes: [Barcode]
    public var reason: String
    /// Bounds of the ink inside `rect`; `rect` itself when there is none.
    public var ink: CGRect
}

enum Cropper {
    /// Pixels darker than this count as ink.
    static let inkLevel: UInt8 = 240

    static func crop(_ page: SourcePage, mode: CropMode, padding: CGFloat, target: LabelSize) -> CropResult {
        // Rasterize at about 1600 px on the long side: enough to read barcodes, quick to scan.
        let scale = 1600 / max(page.size.width, page.size.height)
        let mask = GrayBitmap.render(
            width: max(1, Int((page.size.width * scale).rounded())),
            height: max(1, Int((page.size.height * scale).rounded()))
        ) { ctx in
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: scale, y: scale)
            page.draw(in: ctx)
        }
        let barcodes = BarcodeReader.read(mask).map { code in
            var c = code
            c.rect = CGRect(x: code.rect.minX / scale, y: code.rect.minY / scale,
                            width: code.rect.width / scale, height: code.rect.height / scale)
            return c
        }
        func toPage(_ r: PixelRect) -> CGRect {
            CGRect(x: CGFloat(r.x0) / scale, y: CGFloat(mask.height - r.y1) / scale,
                   width: CGFloat(r.width) / scale, height: CGFloat(r.height) / scale)
        }
        func result(_ rect: CGRect, _ blocks: [CGRect] = [], _ reason: String = "") -> CropResult {
            let px = PixelRect(x0: max(0, Int((rect.minX * scale).rounded(.down))), y0: max(0, mask.height - Int((rect.maxY * scale).rounded(.up))),
                               x1: min(mask.width, Int((rect.maxX * scale).rounded(.up))), y1: min(mask.height, mask.height - Int((rect.minY * scale).rounded(.down))))
            let ink = px.width > 0 && px.height > 0 ? inkBounds(mask, px).map(toPage)?.intersection(rect) : nil
            return CropResult(rect: rect, blocks: blocks, barcodes: barcodes, reason: reason, ink: ink ?? rect)
        }

        guard mode != .none else { return result(page.bounds, [], "whole page") }
        let labelSized = abs(page.size.width - target.points.width) <= 4 && abs(page.size.height - target.points.height) <= 4
        if mode == .auto && labelSized { return result(page.bounds, [], "page is already \(target)") }

        let all = PixelRect(x0: 0, y0: 0, x1: mask.width, y1: mask.height)
        guard let content = inkBounds(mask, all) else { return result(page.bounds, [], "page is blank") }

        func padded(_ r: CGRect) -> CGRect { r.insetBy(dx: -padding, dy: -padding).intersection(page.bounds) }

        let contentRect = toPage(content)
        // Only look for a label inside the page when the page is clearly bigger than a label.
        let pageArea = page.size.width * page.size.height
        let labelArea = target.points.width * target.points.height
        // Screenshots and photos print whole (white margins trimmed); only big PDF or SVG pages
        // are searched for a label-shaped block.
        guard mode == .auto, !page.isRaster, pageArea > labelArea * 1.5 else {
            return result(padded(contentRect), [], "trimmed to content")
        }

        // Blocks are ink joined across gaps under 0.2 in (or 1% of a big image like a screenshot),
        // with nested or overlapping blocks merged: a bordered label becomes one block.
        let joinPoints = max(0.2 * 72, 0.01 * max(page.size.width, page.size.height))
        let blocks = regions(mask, radius: max(1, Int(joinPoints * scale / 2))).map(toPage)
            .sorted { $0.width * $0.height > $1.width * $1.height }

        let targetRatio = max(target.width, target.height) / min(target.width, target.height)
        func score(_ r: CGRect) -> CGFloat {
            guard min(r.width, r.height) >= 72 else { return 0 }
            let ratio = max(r.width, r.height) / min(r.width, r.height)
            return r.width * r.height * min(ratio, targetRatio) / max(ratio, targetRatio)
        }
        guard let best = blocks.max(by: { score($0) < score($1) }), score(best) > 0,
              best.width * best.height < contentRect.width * contentRect.height * 0.85
        else {
            return result(padded(contentRect), blocks, "trimmed to content")
        }
        return result(padded(best), blocks, "found label block (\(blocks.count) blocks on page)")
    }

    /// Gap between two rects; 0 if they overlap.
    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
        let dy = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
        return max(dx, dy)
    }

    struct PixelRect {
        var x0, y0, x1, y1: Int
        var width: Int { x1 - x0 }
        var height: Int { y1 - y0 }

        func overlaps(_ o: PixelRect) -> Bool { x0 < o.x1 && o.x0 < x1 && y0 < o.y1 && o.y0 < y1 }
        func union(_ o: PixelRect) -> PixelRect {
            PixelRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
        }
    }

    static func inkBounds(_ m: GrayBitmap, _ r: PixelRect) -> PixelRect? {
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 where m[x, y] < inkLevel {
                x0 = min(x0, x); x1 = max(x1, x)
                y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        return x1 < 0 ? nil : PixelRect(x0: x0, y0: y0, x1: x1 + 1, y1: y1 + 1)
    }

    /// Bounding boxes of ink regions, joining ink closer than 2 × radius, then merging boxes that overlap.
    static func regions(_ m: GrayBitmap, radius r: Int) -> [PixelRect] {
        let w = m.width, h = m.height
        let ink = m.pixels.map { $0 < inkLevel }

        // Dilate with a (2r+1)² box, separably, using running sums.
        var wide = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            var sum = 0
            for x in 0..<min(r, w) where ink[y * w + x] { sum += 1 }
            for x in 0..<w {
                if x + r < w, ink[y * w + x + r] { sum += 1 }
                if x - r - 1 >= 0, ink[y * w + x - r - 1] { sum -= 1 }
                wide[y * w + x] = sum > 0
            }
        }
        var grown = [Bool](repeating: false, count: w * h)
        for x in 0..<w {
            var sum = 0
            for y in 0..<min(r, h) where wide[y * w + x] { sum += 1 }
            for y in 0..<h {
                if y + r < h, wide[(y + r) * w + x] { sum += 1 }
                if y - r - 1 >= 0, wide[(y - r - 1) * w + x] { sum -= 1 }
                grown[y * w + x] = sum > 0
            }
        }

        // Flood-fill the grown mask; each box covers only the original ink in its region.
        var seen = [Bool](repeating: false, count: w * h)
        var boxes: [PixelRect] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where grown[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var box = PixelRect(x0: .max, y0: .max, x1: -1, y1: -1)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                if ink[i] {
                    box.x0 = min(box.x0, x); box.x1 = max(box.x1, x + 1)
                    box.y0 = min(box.y0, y); box.y1 = max(box.y1, y + 1)
                }
                for n in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
                where n >= 0 && grown[n] && !seen[n] {
                    seen[n] = true
                    stack.append(n)
                }
            }
            if box.x1 > 0 { boxes.append(box) }
        }

        var merged = true
        while merged {
            merged = false
            outer: for i in boxes.indices {
                for j in boxes.indices where j > i && boxes[i].overlaps(boxes[j]) {
                    boxes[i] = boxes[i].union(boxes[j])
                    boxes.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return boxes
    }
}
