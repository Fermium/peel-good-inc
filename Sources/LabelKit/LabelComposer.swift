import CoreGraphics
import Foundation

public enum FitMode: String, CaseIterable, Sendable { case fit, fill }
public enum RotationMode: String, CaseIterable, Sendable { case auto, none, cw, ccw }
public enum InkMode: String, CaseIterable, Sendable {
    case auto
    /// Hard black/white cutoff: sharp text and barcodes.
    case crisp
    /// Error diffusion with dot-gain compensation: grays and photos.
    case photo
    /// Clustered-dot screen: big flat grays, steady across printer heat.
    case halftone

    /// Converts grays to dots rather than a hard cutoff.
    public var dithers: Bool { self == .photo || self == .halftone }
}

public struct LabelOptions: Sendable {
    public var size: LabelSize = .fourBySix
    public var fit: FitMode = .fit
    public var crop: CropMode = .auto
    public var paddingMM: Double = 2
    public var rotation: RotationMode = .auto
    public var ink: InkMode = .auto
    /// 0...1, the gray level below which a pixel prints black. In Photo and Halftone it shifts
    /// the midtones instead: above 0.5 prints darker.
    public var cutoff: Double = 0.5
    /// The printer's dot gain: a requested coverage c prints about c^toneGamma dark.
    /// 1 turns compensation off. Measure it with the step wedge (docs/CALIBRATION.md).
    public var toneGamma: Double = Dither.defaultGamma
    /// In Photo and Halftone, threshold solid text and lines on gray and give them a white halo.
    public var protectText = true
    public var dpi: Double = 200
    /// Shift in millimetres; positive x moves right, positive y moves down.
    public var nudgeMM: CGPoint = .zero
    /// Fit codes to the dot grid: scale so the main code's module is whole dots, align it to the dots,
    /// keep quiet zones, prefer bars along the feed, and redraw 2D codes as whole-dot modules.
    public var snapCodes = true

    public init() {}
}

/// Where the cropped page lands on the label.
public struct Placement: Sendable {
    public var crop: CGRect
    public var rotated: Bool
    public var counterClockwise: Bool
    public var scale: CGFloat
    /// Shift in points, PDF orientation (+y up).
    public var offset: CGPoint
    public var target: CGSize

    /// Page coordinates to label coordinates (points, origin bottom-left).
    public var transform: CGAffineTransform {
        CGAffineTransform(translationX: target.width / 2 + offset.x, y: target.height / 2 + offset.y)
            .scaledBy(x: scale, y: scale)
            .rotated(by: rotated ? (counterClockwise ? .pi / 2 : -.pi / 2) : 0)
            .translatedBy(x: -crop.midX, y: -crop.midY)
    }

    /// Maps page coordinates onto a label-sized context (in points) and clips to the crop.
    public func apply(to ctx: CGContext) {
        ctx.concatenate(transform)
        ctx.clip(to: crop)
    }
}

public struct ComposedLabel {
    /// The source page, for vector output to printers that aren't 1-bit.
    public let page: SourcePage
    public let placement: Placement
    /// The label as it will print: 0 or 255 per pixel at the printer's resolution.
    public let bitmap: GrayBitmap
    public let ink: InkMode
    /// Share of the drawing that is smooth gray (drives the auto ink choice).
    public let smoothGray: Double
    public let crop: CropResult
    public let rotated: Bool
    public let scale: CGFloat
    /// Lines or gaps exactly one printer dot wide.
    public let oneDotFeatures: Int
    /// Codes found inside the crop on the source page.
    public let expectedCodes: [Barcode]
    /// Codes that still decode from the finished 1-bit label.
    public let scannableCodes: [Barcode]
    /// How each expected code lands on the dot grid, with its print-time severity.
    public let codeReports: [CodeReport]
    /// Codes and their quiet zones in bitmap pixels (row 0 at the top). Photo and Halftone
    /// threshold these exactly like Crisp.
    public let codeAreas: [CGRect]
    public let warnings: [String]

    public var missingCodes: [Barcode] {
        expectedCodes.filter { e in !scannableCodes.contains { $0.payload == e.payload } }
    }
}

public enum LabelComposer {
    /// Above this share of smooth gray, auto ink switches to photo.
    static let photoThreshold = 0.04
    /// Above this share of perfectly flat gray (among smooth gray), auto picks halftone over photo.
    static let flatThreshold = 0.7

    public static func compose(_ page: SourcePage, _ o: LabelOptions) -> ComposedLabel {
        let label = compose(page, o, redraw: true)
        // A redrawn code that no longer scans means the redraw went wrong: fall back to the drawing as is.
        let broken = label.missingCodes.contains { m in label.codeReports.contains { $0.payload == m.payload && $0.redrawn } }
        guard broken else { return label }
        let plain = compose(page, o, redraw: false)
        return plain.missingCodes.count < label.missingCodes.count ? plain : label
    }

    static func compose(_ page: SourcePage, _ o: LabelOptions, redraw: Bool) -> ComposedLabel {
        let mm: CGFloat = 72 / 25.4
        let dots = CGFloat(o.dpi) / 72
        var crop = Cropper.crop(page, mode: o.crop, padding: CGFloat(o.paddingMM) * mm, target: o.size)
        let expected = crop.barcodes.filter { crop.rect.intersects($0.rect) }
        let geometry = expected.compactMap { CodeFit.measure($0, on: page) }
        let primary = o.snapCodes ? CodeFit.primary(geometry) : nil
        if o.snapCodes && !geometry.isEmpty { crop.rect = CodeFit.withQuietZones(crop.rect, geometry, page: page.bounds) }
        let c = crop.rect
        let target = o.size.points

        let straight = min(target.width / c.width, target.height / c.height)
        let turned = min(target.width / c.height, target.height / c.width)
        var rotated: Bool = switch o.rotation {
        case .none: false
        case .cw, .ccw: true
        case .auto: turned > straight * 1.05
        }
        // Near a tie, turn so 1D bars run along the feed (picket fence): each bar edge then sits on
        // fixed head elements, while bars across the feed blur with paper stepping and heat build-up.
        if o.rotation == .auto, let p = primary, p.isLinear, max(straight, turned) <= min(straight, turned) * 1.1 {
            rotated = !p.scanAlongX
        }
        let (cw, ch) = rotated ? (c.height, c.width) : (c.width, c.height)
        var scale = o.fit == .fit ? min(target.width / cw, target.height / ch) : max(target.width / cw, target.height / ch)
        if let p = primary {
            // Scaling up is fine while the ink (with its padding) still fits; white margins may go.
            let content = geometry.reduce(crop.ink) { $0.union($1.bounds) }
                .insetBy(dx: -CGFloat(o.paddingMM) * mm, dy: -CGFloat(o.paddingMM) * mm).intersection(c)
            let limit = o.fit == .fit
                ? max(scale, CodeFit.fitLimit(content: content, crop: c, rotated: rotated, target: target, margin: 1 / dots))
                : .infinity
            scale = CodeFit.snappedScale(scale, module: p.narrow, dotsPerPoint: dots, limit: limit,
                                         floor: CGFloat(p.isLinear ? CodeFit.minLinear : CodeFit.minGrid))
        }

        var placement = Placement(crop: c, rotated: rotated, counterClockwise: o.rotation == .ccw, scale: scale,
                                  offset: CGPoint(x: o.nudgeMM.x * mm, y: -o.nudgeMM.y * mm), target: target)
        if let p = primary { placement.offset = CodeFit.snappedOffset(placement, point: p.origin, dotsPerPoint: dots) }
        var bitmap = GrayBitmap.render(
            width: Int((target.width * dots).rounded()), height: Int((target.height * dots).rounded())
        ) { ctx in
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: dots, y: dots)
            placement.apply(to: ctx)
            page.draw(in: ctx)
        }
        let smoothGray = smoothGrayShare(bitmap)

        // 2D codes inside the crop become whole-dot modules. 1D codes never are: re-encoding them
        // can drop characters carriers rely on (GS1 FNC1), and the scale already fits the main one.
        var redrawnDots: [String: Int] = [:]
        if o.snapCodes && redraw {
            for g in geometry where !g.isLinear && c.contains(g.bounds) {
                guard let symbol = CodeFit.symbol(g, on: page) else { continue }
                redrawnDots[g.code.payload] = CodeFit.redraw(symbol, at: g, into: &bitmap, placement: placement, dots: dots)
            }
        }

        let level = UInt8(o.cutoff * 255)
        let codeAreas = codeRects(expected: expected, geometry: geometry, placement: placement, dots: dots, height: bitmap.height)
        let gray = bitmap
        func convert(_ ink: InkMode) -> (GrayBitmap, [Barcode]) {
            var b = gray
            if ink.dithers {
                dither(&b, ink: ink, options: o, codes: codeAreas)
            } else {
                threshold(&b, level: level)
            }
            return (b, expected.isEmpty ? [] : BarcodeReader.read(b))
        }
        func scanCount(_ found: [Barcode]) -> Int { expected.filter { e in found.contains { $0.payload == e.payload } }.count }

        // Codes need hard edges, so auto picks crisp whenever the page has any.
        var ink: InkMode = o.ink != .auto ? o.ink : (expected.isEmpty && smoothGray > photoThreshold ? .photo : .crisp)
        // Mostly flat grays (banners, backgrounds) print more evenly as a clustered halftone.
        if o.ink == .auto, ink == .photo, flatGrayShare(bitmap) > flatThreshold { ink = .halftone }
        var (finished, scannable) = convert(ink)
        // In auto, if a code breaks, try the other conversion and keep whichever scans more.
        if o.ink == .auto, scanCount(scannable) < expected.count {
            let other: InkMode = ink == .crisp ? .photo : .crisp
            let (alt, altCodes) = convert(other)
            if scanCount(altCodes) > scanCount(scannable) { (ink, finished, scannable) = (other, alt, altCodes) }
        }
        bitmap = finished

        // Judge codes by their module in dots before trusting Vision, which reads the ideal bitmap.
        let reports = geometry.map { g in
            let n = redrawnDots[g.code.payload]
            return CodeFit.report(g, moduleDots: n.map(Double.init) ?? Double(g.narrow * scale * dots), rotated: rotated,
                                  redrawn: n != nil, placed: CGSize(width: cw * scale, height: ch * scale), dpi: o.dpi)
        }

        let thin = ink == .crisp ? oneDotFeatures(bitmap) : 0
        var warnings: [String] = []
        for code in expected where !scannable.contains(where: { $0.payload == code.payload })
            && !reports.contains(where: { $0.payload == code.payload && $0.severity == .error }) {
            warnings.append("\(code.symbology) won't scan at this size. Use a bigger label.")
        }
        warnings += reports.compactMap(\.message)
        if scale < 0.5 && !page.isRaster {
            warnings.append("Shrunk to \(Int(scale * 100))%. Small text may be hard to read.")
        }

        return ComposedLabel(page: page, placement: placement, bitmap: bitmap, ink: ink, smoothGray: smoothGray, crop: crop, rotated: rotated,
                             scale: scale, oneDotFeatures: thin, expectedCodes: expected,
                             scannableCodes: scannable, codeReports: reports, codeAreas: codeAreas, warnings: warnings)
    }

    /// Mid-gray pixels whose neighbours are also mid-gray, as a share of all non-white pixels.
    /// Antialiased edges of text and barcodes touch black or white, so they don't count.
    static func smoothGrayShare(_ b: GrayBitmap) -> Double {
        func mid(_ v: UInt8) -> Bool { v > 40 && v < 215 }
        var ink = 0, smooth = 0
        for y in 1..<(b.height - 1) {
            for x in 1..<(b.width - 1) {
                let v = b[x, y]
                guard v < 250 else { continue }
                ink += 1
                if mid(v) && mid(b[x - 1, y]) && mid(b[x + 1, y]) && mid(b[x, y - 1]) && mid(b[x, y + 1]) {
                    smooth += 1
                }
            }
        }
        return ink == 0 ? 0 : Double(smooth) / Double(ink)
    }

    /// Of the smooth mid-gray pixels, the share that equals its neighbours 8 dots away (within one level).
    /// Flat fills score near 1; photos (texture) and gradients (steady change) score low.
    static func flatGrayShare(_ b: GrayBitmap) -> Double {
        func mid(_ v: UInt8) -> Bool { v > 40 && v < 215 }
        let d = 8
        var smooth = 0, flat = 0
        for y in stride(from: 0, to: b.height - d, by: 2) {
            for x in stride(from: 0, to: b.width - d, by: 2) {
                let v = b[x, y]
                guard mid(v), mid(b[x + d, y]), mid(b[x, y + d]) else { continue }
                smooth += 1
                if abs(Int(v) - Int(b[x + d, y])) <= 1 && abs(Int(v) - Int(b[x, y + d])) <= 1 { flat += 1 }
            }
        }
        return smooth == 0 ? 0 : Double(flat) / Double(smooth)
    }

    static func threshold(_ b: inout GrayBitmap, level: UInt8) {
        for i in b.pixels.indices { b.pixels[i] = b.pixels[i] < level ? 0 : 255 }
    }

    /// Photo or halftone, keeping codes and (optionally) solid text on the crisp threshold.
    static func dither(_ b: inout GrayBitmap, ink: InkMode, options o: LabelOptions, codes: [CGRect]) {
        let level = UInt8(o.cutoff * 255)
        let mask = Dither.mask(b, level: level, codes: codes, text: o.protectText)
        let lut = Dither.toneLUT(gamma: o.toneGamma, cutoff: o.cutoff)
        if ink == .halftone { Dither.halftone(&b, lut: lut, mask: mask) } else { Dither.floydSteinberg(&b, lut: lut, mask: mask) }
    }

    /// Codes on the label in bitmap pixels (row 0 at the top), with their quiet zones.
    static func codeRects(expected: [Barcode], geometry: [CodeGeometry], placement p: Placement, dots: CGFloat, height: Int) -> [CGRect] {
        let t = p.transform
        func toBitmap(_ r: CGRect) -> CGRect {
            let l = r.applying(t)
            return CGRect(x: l.minX * dots, y: CGFloat(height) - l.maxY * dots, width: l.width * dots, height: l.height * dots)
        }
        var rects: [CGRect] = []
        for g in geometry {
            let m = g.narrow
            // 1D: a generous quiet zone along the scan (dither texture next to the bars reads as
            // bars to some scanners), four modules across. 2D: four modules all round.
            let (qx, qy): (CGFloat, CGFloat) = g.isLinear ? (g.scanAlongX ? (15 * m, 4 * m) : (4 * m, 15 * m)) : (4 * m, 4 * m)
            rects.append(toBitmap(g.bounds.insetBy(dx: -qx, dy: -qy)).insetBy(dx: -1, dy: -1))
        }
        // Vision's box as a backstop (and the only box for codes that couldn't be measured).
        for c in expected {
            let pad = max(c.rect.width, c.rect.height) * 0.05
            rects.append(toBitmap(c.rect.insetBy(dx: -pad, dy: -pad)))
        }
        return rects
    }

    /// Counts black or white runs exactly one dot long, bounded by the other colour, in both directions.
    static func oneDotFeatures(_ b: GrayBitmap) -> Int {
        var count = 0
        for y in 0..<b.height {
            for x in 1..<(b.width - 1) where b[x, y] != b[x - 1, y] && b[x, y] != b[x + 1, y] { count += 1 }
        }
        for x in 0..<b.width {
            for y in 1..<(b.height - 1) where b[x, y] != b[x, y - 1] && b[x, y] != b[x, y + 1] { count += 1 }
        }
        return count
    }
}
