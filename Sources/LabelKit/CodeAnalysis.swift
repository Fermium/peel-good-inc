import CoreGraphics
import Foundation

/// How a code's bars and modules land on the print head's dot grid.
public struct CodeDots {
    public var symbology: String
    /// Bars parallel to the feed ("picket fence", each edge set by fixed head elements)
    /// rather than across it ("ladder", edges set by paper stepping and heat build-up).
    public var picketFence: Bool
    /// Run length in dots → how many runs had that length, across scanlines through the code.
    public var runs: [Int: Int]
    /// Narrowest element (one module) in dots, as drawn before conversion.
    public var moduleDots: Double
}

public enum CodeAnalysis {
    public static func analyze(_ label: ComposedLabel, dpi: Double = 200) -> [CodeDots] {
        let b = label.bitmap
        let dots = CGFloat(dpi) / 72
        return label.expectedCodes.map { code in
            // Code rect on the label, in dots with row 0 at the top.
            let r = code.rect.applying(label.placement.transform)
            let x0 = max(0, Int((r.minX * dots).rounded())), x1 = min(b.width, Int((r.maxX * dots).rounded()))
            let y0 = max(0, b.height - Int((r.maxY * dots).rounded())), y1 = min(b.height, b.height - Int((r.minY * dots).rounded()))
            let is1D = code.isLinear
            let horizontal = (x1 - x0) >= (y1 - y0)
            var runs: [Int: Int] = [:]
            func scan(_ line: [UInt8]) {
                var len = 0, color = line.first ?? 255, all: [Int] = []
                for v in line { if v == color { len += 1 } else { all.append(len); len = 1; color = v } }
                for l in all.dropFirst() { runs[l, default: 0] += 1 }   // first run is cut by the rect edge
            }
            let fractions = [0.3, 0.4, 0.5, 0.6, 0.7]
            if !is1D || horizontal {
                for f in fractions { let y = y0 + Int(Double(y1 - y0) * f); if y < b.height { scan((x0..<x1).map { b[$0, y] }) } }
            }
            if !is1D || !horizontal {
                for f in fractions { let x = x0 + Int(Double(x1 - x0) * f); if x < b.width { scan((y0..<y1).map { b[x, $0] }) } }
            }
            // Module estimate from the narrowest common runs.
            let sorted = runs.flatMap { Array(repeating: $0.key, count: $0.value) }.sorted()
            let narrow = sorted.prefix(max(1, sorted.count / 4))
            let module = narrow.isEmpty ? 0 : Double(narrow.reduce(0, +)) / Double(narrow.count)
            return CodeDots(symbology: code.symbology, picketFence: is1D ? horizontal : true, runs: runs, moduleDots: module)
        }
    }
}
