import CoreGraphics
import CoreImage
import Foundation

/// How likely a code is to scan once printed, judged by its module size in printer dots.
/// Vision verifies the ideal bitmap, which is optimistic: thermal dots spread, so thin bars fill in.
public enum CodeSeverity: Int, Comparable, Sendable, CustomStringConvertible {
    case ok, caution, error

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var description: String { ["ok", "caution", "error"][rawValue] }
}

/// How one code lands on the print head's dot grid.
public struct CodeReport: Sendable {
    public var symbology: String
    public var payload: String
    /// Narrow bar (1D) or module (2D) in printer dots, as printed.
    public var moduleDots: Double
    /// Bars parallel to the feed, scanned across the head. Always true for 2D codes.
    public var picketFence: Bool
    /// Redrawn as whole-dot modules from the decoded symbol.
    public var redrawn: Bool
    public var severity: CodeSeverity
    public var message: String?
}

/// A code measured on the source page.
struct CodeGeometry {
    var code: Barcode
    /// Symbol extent in page points: outer bar edges along the scan (1D), or the module grid (2D).
    var bounds: CGRect
    /// One module in page points, per page axis. 1D codes only use the scan axis.
    var module: CGSize
    /// A point on the module grid: bar edges or module corners fall at origin + n × module.
    var origin: CGPoint
    /// 1D: scanlines run along page x (the bars stand upright on the page).
    var scanAlongX: Bool
    /// 2D: modules across × up the page, when the grid could be read.
    var grid: (cols: Int, rows: Int)?

    var isLinear: Bool { code.isLinear }
    /// The module that sets the scale: along the scan for 1D, the smaller axis for 2D.
    var narrow: CGFloat { isLinear ? (scanAlongX ? module.width : module.height) : min(module.width, module.height) }
    /// Bars parallel to the feed once placed on the label.
    func picketFence(rotated: Bool) -> Bool { !isLinear || rotated != scanAlongX }
}

/// A 2D symbol as a grid of modules, x to the right and y up; true is black.
struct ModuleGrid: Equatable {
    var cols: Int
    var rows: Int
    var bits: [Bool]

    subscript(x: Int, y: Int) -> Bool { bits[y * cols + x] }

    /// Quarter turn counter-clockwise.
    var turned: ModuleGrid {
        var g = ModuleGrid(cols: rows, rows: cols, bits: bits)
        for y in 0..<g.rows { for x in 0..<g.cols { g.bits[y * g.cols + x] = self[y, rows - 1 - x] } }
        return g
    }
    var mirrored: ModuleGrid {
        var g = self
        for y in 0..<rows { for x in 0..<cols { g.bits[y * cols + x] = self[cols - 1 - x, y] } }
        return g
    }

    /// Share of modules that agree; 0 when the sizes differ.
    func agreement(_ o: ModuleGrid) -> Double {
        guard cols == o.cols, rows == o.rows, !bits.isEmpty else { return 0 }
        return Double(zip(bits, o.bits).filter { $0 == $1 }.count) / Double(bits.count)
    }

    /// The symbol at `px` pixels per module with a 4-module quiet zone, for checking it decodes.
    func bitmap(px: Int) -> GrayBitmap {
        let w = (cols + 8) * px, h = (rows + 8) * px
        var b = GrayBitmap(width: w, height: h, pixels: [UInt8](repeating: 255, count: w * h))
        for y in 0..<rows { for x in 0..<cols where self[x, y] {
            for dy in 0..<px { for dx in 0..<px { b[(x + 4) * px + dx, h - 1 - ((y + 4) * px + dy)] = 0 } }
        } }
        return b
    }
}

enum CodeFit {
    /// Narrowest a 1D bar may be: thinner bars fill in. Below `cautionLinear` they print but are fragile.
    static let minLinear = 2.0, cautionLinear = 3.0
    /// Same for 2D modules.
    static let minGrid = 3.0, cautionGrid = 4.0
    /// Quiet zone kept around codes, in modules.
    static let quietLinear: CGFloat = 10, quietGrid: CGFloat = 4
    /// Snapping never shrinks the label by more than this.
    static let maxShrink: CGFloat = 2.0 / 3.0

    // MARK: Scale and position

    /// The code that sets the scale: 1D codes first (their bar-to-space ratios matter most), smallest module first.
    static func primary(_ codes: [CodeGeometry]) -> CodeGeometry? {
        codes.min { a, b in a.isLinear != b.isLinear ? a.isLinear : a.narrow < b.narrow }
    }

    /// The scale nearest to `scale` that makes `module` (page points) a whole number of dots, without going
    /// over `limit`. Rounds down unless rounding up still fits. Leaves the scale alone rather than shrink
    /// a code below `floor` dots (it's too small either way, and gets a warning) or the label by over a third.
    static func snappedScale(_ scale: CGFloat, module: CGFloat, dotsPerPoint: CGFloat, limit: CGFloat = .infinity,
                             floor: CGFloat = 1) -> CGFloat {
        let perScale = module * dotsPerPoint
        guard perScale > 0 else { return scale }
        let now = scale * perScale
        var n = now.rounded()
        if n / perScale > limit * (1 + 1e-9) { n = (limit * perScale).rounded(.down) }
        n = min(n, now.rounded(.up))
        guard n >= 1, n >= floor || n >= now else { return scale }
        let snapped = n / perScale
        return snapped < scale * maxShrink ? scale : snapped
    }

    /// The largest scale at which `content` still fits on the label, centered on the crop as placements are.
    static func fitLimit(content: CGRect, crop: CGRect, rotated: Bool, target: CGSize, margin: CGFloat) -> CGFloat {
        let halfX = max(crop.midX - content.minX, content.maxX - crop.midX)
        let halfY = max(crop.midY - content.minY, content.maxY - crop.midY)
        let (w, h) = rotated ? (halfY, halfX) : (halfX, halfY)
        return min((target.width / 2 - margin) / max(w, 1e-6), (target.height / 2 - margin) / max(h, 1e-6))
    }

    /// Shifts the placement so `point` (page coordinates) lands exactly on a dot boundary.
    static func snappedOffset(_ p: Placement, point: CGPoint, dotsPerPoint d: CGFloat) -> CGPoint {
        let q = point.applying(p.transform)
        return CGPoint(x: p.offset.x + ((q.x * d).rounded() - q.x * d) / d,
                       y: p.offset.y + ((q.y * d).rounded() - q.y * d) / d)
    }

    /// Grows the crop so each code keeps its quiet zone: 10 modules beside 1D bars, 4 around 2D symbols.
    static func withQuietZones(_ crop: CGRect, _ codes: [CodeGeometry], page: CGRect) -> CGRect {
        codes.reduce(crop) { c, g in
            let need = g.isLinear
                ? g.bounds.insetBy(dx: g.scanAlongX ? -quietLinear * g.narrow : 0, dy: g.scanAlongX ? 0 : -quietLinear * g.narrow)
                : g.bounds.insetBy(dx: -quietGrid * g.module.width, dy: -quietGrid * g.module.height)
            return c.union(need.intersection(page))
        }
    }

    // MARK: Rules

    static func severity(moduleDots: Double, linear: Bool) -> CodeSeverity {
        let (low, caution) = linear ? (minLinear, cautionLinear) : (minGrid, cautionGrid)
        return moduleDots < low - 0.05 ? .error : moduleDots < caution - 0.05 ? .caution : .ok
    }

    /// `placed` is the crop size as placed on the label (after rotation), in points.
    static func report(_ g: CodeGeometry, moduleDots: Double, rotated: Bool, redrawn: Bool, placed: CGSize, dpi: Double) -> CodeReport {
        let picket = g.picketFence(rotated: rotated)
        var severity = severity(moduleDots: moduleDots, linear: g.isLinear)
        let what = g.isLinear ? "bars" : "squares"
        let mm = String(format: "%.2f", moduleDots / dpi * 25.4)
        var message: String?
        switch severity {
        case .error:
            let need = (g.isLinear ? minLinear : minGrid) / max(moduleDots, 0.01)
            let w = (placed.width * need / 72 * 10).rounded(.up) / 10, h = (placed.height * need / 72 * 10).rounded(.up) / 10
            message = "\(g.code.symbology) is too small to scan: its \(what) are \(mm) mm. Use a label of at least \(LabelSize.format(w)) × \(LabelSize.format(h)) in."
        case .caution:
            message = "\(g.code.symbology) \(what) are only \(mm) mm and may not scan if the print is light."
        case .ok: break
        }
        if !picket && moduleDots < cautionLinear {
            severity = max(severity, .caution)
            message = (message.map { $0 + " " } ?? "")
                + "Its bars run across the paper feed, which prints them less sharply."
        }
        return CodeReport(symbology: g.code.symbology, payload: g.code.payload, moduleDots: moduleDots, picketFence: picket,
                          redrawn: redrawn, severity: severity, message: message)
    }

    // MARK: Measuring

    /// Measures a code from a sharp render of its region of the page.
    static func measure(_ code: Barcode, on page: SourcePage) -> CodeGeometry? {
        let r = code.rect
        let grow: CGFloat = code.isLinear ? 0.15 : 0.04
        let region = r.insetBy(dx: -r.width * grow, dy: -r.height * grow).intersection(page.bounds)
        guard region.width > 1, region.height > 1 else { return nil }
        let k = min(8, 3000 / max(region.width, region.height))
        let img = render(page, region, pixelsPerPoint: k)
        let hi = CGFloat(img.height)
        func pageX(_ p: Double) -> CGFloat { region.minX + CGFloat(p) / k }
        func pageY(_ p: Double) -> CGFloat { region.minY + (hi - CGFloat(p)) / k }
        func row(_ y: Int) -> [UInt8] { Array(img.pixels[(y * img.width)..<((y + 1) * img.width)]) }
        func column(_ x: Int) -> [UInt8] { (0..<img.height).map { img[x, $0] } }
        // The Vision rect in pixels of the render.
        let rx0 = Double((r.minX - region.minX) * k), rx1 = Double((r.maxX - region.minX) * k)
        let ry0 = Double((region.maxY - r.maxY) * k), ry1 = Double((region.maxY - r.minY) * k)
        func clampX(_ v: Double) -> Int { min(img.width - 1, max(0, Int(v))) }
        func clampY(_ v: Double) -> Int { min(img.height - 1, max(0, Int(v))) }

        if code.isLinear {
            let midRow = row(clampY((ry0 + ry1) / 2)), midCol = column(clampX((rx0 + rx1) / 2))
            let alongX = crossings(midRow).count >= crossings(midCol).count
            let (s0, s1) = alongX ? (rx0, rx1) : (ry0, ry1)
            let whole = Barcode.wholeModules.contains(code.symbology)
            var modules: [Double] = [], edges: [Double] = [], starts: [Double] = [], ends: [Double] = []
            for f in stride(from: 0.2, through: 0.8, by: 0.075) {
                let line = alongX ? row(clampY(ry0 + (ry1 - ry0) * f)) : column(clampX(rx0 + (rx1 - rx0) * f))
                let cs = crossings(line)
                guard let bars = barGroup(cs, startsBlack: (line.first ?? 255) < 128, from: s0, to: s1, whole: whole) else { continue }
                modules.append(bars.module); edges += bars.edges
                starts.append(bars.edges.first!); ends.append(bars.edges.last!)
            }
            guard modules.count >= 3 else { return nil }
            let m = median(modules)
            let phase = circularMean(edges, period: m)
            let lo = median(starts), hi = median(ends)
            let (a, b) = alongX ? (pageX(lo), pageX(hi)) : (pageY(hi), pageY(lo))
            let unit = m / Double(k)
            let origin = alongX ? CGPoint(x: pageX(phase), y: r.minY) : CGPoint(x: r.minX, y: pageY(phase))
            let bounds = alongX ? CGRect(x: a, y: r.minY, width: b - a, height: r.height)
                                : CGRect(x: r.minX, y: a, width: r.width, height: b - a)
            return CodeGeometry(code: code, bounds: bounds, module: CGSize(width: unit, height: unit), origin: origin,
                                scanAlongX: alongX, grid: nil)
        }

        // 2D: the ink inside the rect is the symbol (finder patterns reach its edges).
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in 0..<img.height { for x in 0..<img.width where img[x, y] < 128 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        guard x1 > x0 + 4, y1 > y0 + 4 else { return nil }
        var runs: [Double] = [], xEdges: [Double] = [], yEdges: [Double] = []
        for f in stride(from: 0.1, through: 0.9, by: 0.05) {
            let y = y0 + Int(Double(y1 - y0) * f), x = x0 + Int(Double(x1 - x0) * f)
            let h = crossings(row(y)).filter { $0 > Double(x0) - 1 && $0 < Double(x1) + 2 }
            let v = crossings(column(x)).filter { $0 > Double(y0) - 1 && $0 < Double(y1) + 2 }
            xEdges += h; yEdges += v
            runs += zip(h.dropFirst(), h).map(-) + zip(v.dropFirst(), v).map(-)
        }
        guard runs.count >= 8, let m0 = wholeModule(runs) else { return nil }
        let w = Double(x1 + 1 - x0), h = Double(y1 + 1 - y0)
        var cols = Int((w / m0).rounded()), rows = Int((h / m0).rounded())
        var gridOK = abs(w / m0 - Double(cols)) < 0.3 && abs(h / m0 - Double(rows)) < 0.3
        if code.symbology == "DataMatrix" { gridOK = gridOK && cols % 2 == 0 && rows % 2 == 0 }
        if let d = code.descriptor, let gen = generated(d) {
            // The descriptor knows the true size; match its orientation to the page's aspect.
            let flip = (gen.cols > gen.rows) != (w > h)
            (cols, rows) = flip ? (gen.rows, gen.cols) : (gen.cols, gen.rows)
            gridOK = abs(w / Double(cols) / m0 - 1) < 0.2 && abs(h / Double(rows) / m0 - 1) < 0.2
        }
        guard cols > 0, rows > 0 else { return nil }
        let mx = w / Double(cols), my = h / Double(rows)
        let px = circularMean(xEdges, period: mx), py = circularMean(yEdges, period: my)
        // Grid-aligned bounds: the ink edges, nudged onto the grid the edges agree on.
        let gx0 = px + mx * ((Double(x0) - px) / mx).rounded(), gy0 = py + my * ((Double(y0) - py) / my).rounded()
        let bounds = CGRect(x: pageX(gx0), y: pageY(gy0 + h), width: CGFloat(w) / k, height: CGFloat(h) / k)
        return CodeGeometry(code: code, bounds: bounds, module: CGSize(width: CGFloat(mx) / k, height: CGFloat(my) / k),
                            origin: CGPoint(x: bounds.minX, y: bounds.maxY), scanAlongX: true,
                            grid: gridOK ? (cols, rows) : nil)
    }

    /// The bars on one scanline: the run of edges around the code's middle, up to a gap far wider
    /// than any space in the code (the quiet zone). Returns edge positions and the module estimate.
    static func barGroup(_ cs: [Double], startsBlack: Bool, from s0: Double, to s1: Double, whole: Bool) -> (edges: [Double], module: Double)? {
        // Crossing i turns black when the line starts white and i is even.
        func turnsBlack(_ i: Int) -> Bool { (i % 2 == 0) != startsBlack }
        let inner = s0 + (s1 - s0) * 0.2, outer = s1 - (s1 - s0) * 0.2
        let middle = cs.filter { $0 >= inner && $0 <= outer }
        let middleRuns = zip(middle.dropFirst(), middle).map(-)
        guard middleRuns.count >= 6, let m0 = whole ? wholeModule(middleRuns) : narrowModule(middleRuns) else { return nil }
        let center = (s0 + s1) / 2
        guard var i = cs.indices.min(by: { abs(cs[$0] - center) < abs(cs[$1] - center) }) else { return nil }
        var j = i
        // A white run is from a crossing that turns white to the next crossing.
        while i > 0, turnsBlack(i) ? !(cs[i] - cs[i - 1] > 7 * m0) : true { i -= 1 }
        while j < cs.count - 1, !turnsBlack(j) ? !(cs[j + 1] - cs[j] > 7 * m0) : true { j += 1 }
        guard turnsBlack(i), !turnsBlack(j), j - i >= 10 else { return nil }
        let edges = Array(cs[i...j])
        let runs = zip(edges.dropFirst(), edges).map(-)
        guard let m = whole ? wholeModule(runs) : narrowModule(runs) else { return nil }
        return (edges, m)
    }

    /// Module size from runs that are whole multiples of it. Pairs of neighbouring runs cancel ink spread
    /// (a bar drawn wide makes its spaces narrow); the narrowest pairs are one bar and one space.
    static func wholeModule(_ runs: [Double]) -> Double? {
        let pairs = zip(runs.dropFirst(), runs).map(+).sorted()
        guard pairs.count >= 4 else { return nil }
        var m = pairs[pairs.count / 10] / 2
        for _ in 0..<4 {
            let used = pairs.filter { ($0 / m).rounded() <= 12 }
            let n = used.reduce(0) { $0 + max(2, ($1 / m).rounded()) }
            guard n > 0 else { return nil }
            m = used.reduce(0, +) / n
        }
        return m > 0 ? m : nil
    }

    /// Narrow element for codes with wide bars that aren't whole modules (Code39, ITF): the narrowest pairs, halved.
    static func narrowModule(_ runs: [Double]) -> Double? {
        let pairs = zip(runs.dropFirst(), runs).map(+).sorted()
        guard let p = pairs.dropFirst(pairs.count / 10).first else { return nil }
        let narrow = pairs.filter { $0 <= p * 1.25 }
        return narrow.reduce(0, +) / Double(narrow.count) / 2
    }

    /// Where a scanline crosses 50% gray, in pixels with subpixel precision (pixel i spans i..<i+1).
    /// Hysteresis ignores wobble near the middle (resampling ripple, JPEG noise).
    static func crossings(_ line: [UInt8]) -> [Double] {
        guard var black = line.first.map({ $0 < 128 }) else { return [] }
        var out: [Double] = []
        for i in 1..<line.count where black ? line[i] > 160 : line[i] < 95 {
            var j = i
            while j > 1, (line[j - 1] < 128) != black { j -= 1 }
            let a = Double(line[j - 1]), b = Double(line[j])
            out.append(Double(j) - 0.5 + (a == b ? 0.5 : min(1, max(0, (127.5 - a) / (b - a)))))
            black.toggle()
        }
        return out
    }

    /// The phase (0..<period) that edges agree on, averaged around the circle so 0.95 and 0.05 meet at 0.
    static func circularMean(_ values: [Double], period: Double) -> Double {
        var s = 0.0, c = 0.0
        for v in values { let t = 2 * .pi * v / period; s += sin(t); c += cos(t) }
        let phase = atan2(s, c) / (2 * .pi) * period
        return phase < 0 ? phase + period : phase
    }

    static func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }

    static func render(_ page: SourcePage, _ region: CGRect, pixelsPerPoint k: CGFloat) -> GrayBitmap {
        GrayBitmap.render(width: max(1, Int((region.width * k).rounded(.up))), height: max(1, Int((region.height * k).rounded(.up)))) { ctx in
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -region.minX, y: -region.minY)
            page.draw(in: ctx)
        }
    }

    // MARK: Redrawing 2D codes

    /// The symbol Core Image generates from Vision's descriptor (the same codewords), trimmed to its modules.
    static func generated(_ d: CIBarcodeDescriptor) -> ModuleGrid? {
        guard let f = CIFilter(name: "CIBarcodeGenerator") else { return nil }
        f.setValue(d, forKey: "inputBarcodeDescriptor")
        guard let out = f.outputImage, out.extent.width < 1000, out.extent.height < 1000,
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        let b = GrayBitmap.render(width: cg.width, height: cg.height) { ctx in
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in 0..<b.height { for x in 0..<b.width where b[x, y] < 128 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        guard x1 >= x0 else { return nil }
        let cols = x1 - x0 + 1, rows = y1 - y0 + 1
        var g = ModuleGrid(cols: cols, rows: rows, bits: [Bool](repeating: false, count: cols * rows))
        for y in 0..<rows { for x in 0..<cols { g.bits[y * cols + x] = b[x0 + x, y1 - y] < 128 } }
        return g
    }

    /// The symbol's modules read off a sharp render of the page.
    static func sampled(_ g: CodeGeometry, grid: (cols: Int, rows: Int), on page: SourcePage) -> ModuleGrid {
        let k = max(2, min(8, 3000 / max(g.bounds.width, g.bounds.height)))
        let img = render(page, g.bounds, pixelsPerPoint: k)
        let cw = Double(img.width) / Double(grid.cols), ch = Double(img.height) / Double(grid.rows)
        var out = ModuleGrid(cols: grid.cols, rows: grid.rows, bits: [Bool](repeating: false, count: grid.cols * grid.rows))
        for y in 0..<grid.rows { for x in 0..<grid.cols {
            // Average the middle half of the cell.
            var sum = 0, n = 0
            let px0 = Int(cw * (Double(x) + 0.25)), px1 = max(px0 + 1, Int(cw * (Double(x) + 0.75)))
            let top = Double(grid.rows - 1 - y)
            let py0 = Int(ch * (top + 0.25)), py1 = max(py0 + 1, Int(ch * (top + 0.75)))
            for py in py0..<min(py1, img.height) { for px in px0..<min(px1, img.width) { sum += Int(img[px, py]); n += 1 } }
            out.bits[y * grid.cols + x] = n > 0 && sum / n < 128
        } }
        return out
    }

    /// The modules to redraw: Core Image's regeneration when it matches the page in some orientation,
    /// else the sampled grid if it decodes to the same payload on its own. Nil means leave the code as drawn.
    static func symbol(_ g: CodeGeometry, on page: SourcePage) -> ModuleGrid? {
        // PDF417 rows are taller than its modules are wide, so it isn't a square grid.
        guard !g.isLinear, !g.code.symbology.contains("PDF417"), let grid = g.grid else { return nil }
        let seen = sampled(g, grid: grid, on: page)
        if let d = g.code.descriptor, var gen = generated(d) {
            var best: (ModuleGrid, Double) = (gen, 0)
            for _ in 0..<2 {
                for _ in 0..<4 {
                    let a = gen.agreement(seen)
                    if a > best.1 { best = (gen, a) }
                    gen = gen.turned
                }
                gen = gen.mirrored
            }
            if best.1 >= 0.95 { return best.0 }
        }
        let check = BarcodeReader.read(seen.bitmap(px: 6))
        return check.contains { $0.payload == g.code.payload } ? seen : nil
    }

    /// Draws the symbol over the code on the label as whole-dot modules, centred where it was.
    /// Returns the module size in dots. `bitmap` is the label, `dots` dots per point.
    static func redraw(_ s: ModuleGrid, at g: CodeGeometry, into b: inout GrayBitmap, placement p: Placement, dots: CGFloat) -> Int {
        let t = p.transform
        let lr = g.bounds.applying(t)
        let d = CGRect(x: lr.minX * dots, y: lr.minY * dots, width: lr.width * dots, height: lr.height * dots)
        let (nu, nv) = p.rotated ? (s.rows, s.cols) : (s.cols, s.rows)
        let md = Double(d.width) / Double(nu)
        var k = md.rounded()
        // Growing eats into the quiet zone; allow at most half a module on each side.
        if k > md && Double(nu) * (k - md) / 2 > md { k = md.rounded(.down) }
        let n = max(1, Int(k))
        let ox = Int((d.midX - CGFloat(nu * n) / 2).rounded()), oy = Int((d.midY - CGFloat(nv * n) / 2).rounded())
        let white = d.union(CGRect(x: ox, y: oy, width: nu * n, height: nv * n)).insetBy(dx: -CGFloat(n), dy: -CGFloat(n))
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ v: UInt8) {
            for y in max(0, y0)..<min(b.height, max(0, y1)) {
                let row = b.height - 1 - y
                for x in max(0, x0)..<min(b.width, max(0, x1)) { b[x, row] = v }
            }
        }
        fill(Int(white.minX.rounded(.down)), Int(white.minY.rounded(.down)), Int(white.maxX.rounded(.up)), Int(white.maxY.rounded(.up)), 255)
        let back = t.inverted()
        for v in 0..<nv { for u in 0..<nu {
            // The page module under this cell's centre, via the original placement.
            let c = CGPoint(x: (d.minX + (CGFloat(u) + 0.5) * d.width / CGFloat(nu)) / dots,
                            y: (d.minY + (CGFloat(v) + 0.5) * d.height / CGFloat(nv)) / dots).applying(back)
            let i = min(s.cols - 1, max(0, Int((c.x - g.bounds.minX) / g.bounds.width * CGFloat(s.cols))))
            let j = min(s.rows - 1, max(0, Int((c.y - g.bounds.minY) / g.bounds.height * CGFloat(s.rows))))
            if s[i, j] { fill(ox + u * n, oy + v * n, ox + (u + 1) * n, oy + (v + 1) * n, 0) }
        } }
        return n
    }
}
