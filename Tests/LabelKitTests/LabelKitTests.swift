import CoreGraphics
import CoreImage
import Testing
@testable import LabelKit

let munbyn = PrinterInfo(
    name: "MUNBYN",
    presets: [
        LabelSize(width: 4, height: 6, mediaName: "na_index-4x6_4x6in"),
        LabelSize(width: 2.25, height: 1.25, mediaName: "custom_2.25x1.25in_2.25x1.25in"),
    ],
    customMin: LabelSize(width: 2, height: 1.25),
    customMax: LabelSize(width: 4, height: 8)
)

@Test func parsesSizes() {
    #expect(LabelSize(parsing: "4x6") == LabelSize(width: 4, height: 6))
    #expect(LabelSize(parsing: "2.25x1.25in") == LabelSize(width: 2.25, height: 1.25))
    #expect(LabelSize(parsing: "101.6x152.4mm") == LabelSize(width: 4, height: 6))
    #expect(LabelSize(parsing: "4 by 6") == nil)
    #expect(LabelSize(width: 4, height: 2).cupsMedia == "custom_4x2in_4x2in")
}

@Test func resolvesPresetsAndCustomSizes() {
    #expect(munbyn.isLabelPrinter)
    #expect(munbyn.resolve(.fourBySix)?.cupsMedia == "na_index-4x6_4x6in")
    #expect(munbyn.resolve(LabelSize(width: 4, height: 3))?.cupsMedia == "custom_4x3in_4x3in")
    #expect(munbyn.resolve(LabelSize(width: 1, height: 1)) == nil)
}

@Test func catalogMarksSizesBelowMinimum() {
    let entries = SizeCatalog.entries(for: munbyn)
    let oneByOne = entries.first { $0.size == LabelSize(width: 1, height: 1) }
    #expect(oneByOne?.isSupported == false)
    #expect(entries.first { $0.size == LabelSize(width: 4, height: 2) }?.isSupported == true)
    #expect(entries.filter { $0.size == .fourBySix }.count == 1)
}

/// A Letter page with a bordered 4x6 label top-left and a text-like block below it.
func letterPage(labelLandscape: Bool = false) -> SourcePage {
    SourcePage(size: CGSize(width: 612, height: 792)) { ctx in
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(2)
        let label = labelLandscape ? CGRect(x: 36, y: 400, width: 432, height: 288) : CGRect(x: 36, y: 324, width: 288, height: 432)
        ctx.stroke(label)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(label.insetBy(dx: 40, dy: 120))
        for line in 0..<8 { ctx.fill(CGRect(x: 36, y: 60 + CGFloat(line) * 14, width: 540, height: 6)) }
    }
}

@Test func findsLabelOnLetterPage() {
    var o = LabelOptions()
    o.paddingMM = 0
    let label = LabelComposer.compose(letterPage(), o)
    #expect(abs(label.crop.rect.minX - 35) < 4)
    #expect(abs(label.crop.rect.width - 290) < 6)
    #expect(abs(label.crop.rect.height - 434) < 6)
    #expect(!label.rotated)
}

@Test func rotatesLandscapeLabel() {
    let label = LabelComposer.compose(letterPage(labelLandscape: true), LabelOptions())
    #expect(label.rotated)
    #expect(label.scale > 0.9)
}

@Test func outputIsLabelSizedAndOneBit() {
    var o = LabelOptions()
    o.size = LabelSize(width: 2.25, height: 1.25)
    let label = LabelComposer.compose(letterPage(), o)
    #expect(label.bitmap.width == 450 && label.bitmap.height == 250)
    #expect(label.bitmap.pixels.allSatisfy { $0 == 0 || $0 == 255 })
}

@Test func picksPhotoForGradients() {
    let gradient = SourcePage(size: CGSize(width: 288, height: 432)) { ctx in
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                           colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 432), options: [])
    }
    #expect(LabelComposer.compose(gradient, LabelOptions()).ink == .photo)
    #expect(LabelComposer.compose(letterPage(), LabelOptions()).ink == .crisp)
}

// MARK: Dot-grid fit

let dpp: CGFloat = 200.0 / 72

@Test func snapsScaleToWholeDots() {
    // A module 3.62 dots wide at this scale rounds up to 4 when there's room, down to 3 when not.
    let module = 3.62 / dpp
    #expect(abs(CodeFit.snappedScale(1, module: module, dotsPerPoint: dpp) * module * dpp - 4) < 1e-9)
    #expect(abs(CodeFit.snappedScale(1, module: module, dotsPerPoint: dpp, limit: 1.05) * module * dpp - 3) < 1e-9)
    // 3.3 is nearest to 3 even with room to grow.
    #expect(abs(CodeFit.snappedScale(1, module: 3.3 / dpp, dotsPerPoint: dpp) * 3.3 - 3) < 1e-9)
    // Never shrinks a code below the floor, nor the label by more than a third.
    #expect(CodeFit.snappedScale(1, module: 1.4 / dpp, dotsPerPoint: dpp, limit: 1, floor: 2) == 1)
    #expect(CodeFit.snappedScale(1, module: 1.9 / dpp, dotsPerPoint: dpp, limit: 1) == 1)
    #expect(abs(CodeFit.snappedScale(1, module: 2.9 / dpp, dotsPerPoint: dpp, limit: 1) * 2.9 - 2) < 1e-9)
}

@Test func fitLimitKeepsContentOnLabel() {
    // 200 pt of content centred in a 300 pt crop may grow to fill a 288 pt label: 1.44×.
    let crop = CGRect(x: 0, y: 0, width: 300, height: 300), content = crop.insetBy(dx: 50, dy: 50)
    #expect(abs(CodeFit.fitLimit(content: content, crop: crop, rotated: false, target: CGSize(width: 288, height: 432), margin: 0) - 1.44) < 1e-9)
}

@Test func snapsOffsetOntoDotBoundary() {
    var p = Placement(crop: CGRect(x: 13.3, y: 7.1, width: 287.4, height: 421.9), rotated: true, counterClockwise: false,
                      scale: 0.937, offset: CGPoint(x: 0.21, y: -0.4), target: CGSize(width: 288, height: 432))
    let edge = CGPoint(x: 101.234, y: 250.777)
    p.offset = CodeFit.snappedOffset(p, point: edge, dotsPerPoint: dpp)
    let q = edge.applying(p.transform)
    #expect(abs(q.x * dpp - (q.x * dpp).rounded()) < 1e-6)
    #expect(abs(q.y * dpp - (q.y * dpp).rounded()) < 1e-6)
}

@Test func minimumModuleRules() {
    #expect(CodeFit.severity(moduleDots: 1.4, linear: true) == .error)
    #expect(CodeFit.severity(moduleDots: 2, linear: true) == .caution)
    #expect(CodeFit.severity(moduleDots: 3, linear: true) == .ok)
    #expect(CodeFit.severity(moduleDots: 2.9, linear: false) == .error)
    #expect(CodeFit.severity(moduleDots: 3, linear: false) == .caution)
    #expect(CodeFit.severity(moduleDots: 4, linear: false) == .ok)
}

@Test func findsSubpixelEdges() {
    // White, then black from 3.25 to 6.5: pixel 3 is 25% white, pixel 6 half black.
    let line: [UInt8] = [255, 255, 255, 64, 0, 0, 128, 255, 255]
    let c = CodeFit.crossings(line)
    #expect(c.count == 2)
    #expect(abs(c[0] - 3.25) < 0.15 && abs(c[1] - 6.5) < 0.15)
    #expect(abs(CodeFit.wholeModule([1, 1, 2, 1, 3, 1, 4, 2, 1, 1, 2, 3].map { $0 * 1.7 })! - 1.7) < 1e-6)
}

@Test func moduleGridTurnsAndMatches() {
    let g = ModuleGrid(cols: 3, rows: 2, bits: [true, false, false, true, true, false])
    #expect(g.turned.turned.turned.turned == g)
    #expect(g.turned.cols == 2 && g.turned.rows == 3)
    #expect(g.agreement(g.mirrored) < 1 && g.agreement(g) == 1)
}

func codeImage(_ filter: String, _ message: String) -> CGImage {
    let f = CIFilter(name: filter)!
    f.setValue(Data(message.utf8), forKey: "inputMessage")
    if filter == "CICode128BarcodeGenerator" { f.setValue(0, forKey: "inputQuietSpace") }
    return CIContext().createCGImage(f.outputImage!, from: f.outputImage!.extent)!
}

/// A 4x6 page with a Code128 at a 0.83 pt module (2.3 dots) and a QR beside it, optionally turned a quarter.
func codePage(size: CGSize = CGSize(width: 288, height: 432), turned: Bool = false, module: CGFloat = 0.83) -> SourcePage {
    let bars = codeImage("CICode128BarcodeGenerator", "1Z999AA10123456784")
    let qr = codeImage("CIQRCodeGenerator", "https://track.example/1Z999AA10123456784")
    return SourcePage(size: size) { ctx in
        ctx.interpolationQuality = .none
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 10, y: 10, width: size.width - 20, height: 4))
        let w = CGFloat(bars.width) * module
        if turned {
            ctx.saveGState()
            ctx.translateBy(x: size.width / 2 + 30, y: (size.height - w) / 2)
            ctx.rotate(by: .pi / 2)
            ctx.draw(bars, in: CGRect(x: 0, y: 0, width: w, height: 60))
            ctx.restoreGState()
        } else {
            ctx.draw(bars, in: CGRect(x: (size.width - w) / 2, y: size.height / 2, width: w, height: 60))
        }
        ctx.draw(qr, in: CGRect(x: 30.3, y: 40.7, width: 71.3, height: 71.3))
    }
}

@Test func fitsCodesToDotGrid() {
    let label = LabelComposer.compose(codePage(), LabelOptions())
    #expect(label.missingCodes.isEmpty)
    let bars = label.codeReports.first { $0.symbology == "Code128" }!
    #expect(bars.moduleDots == bars.moduleDots.rounded() && !bars.redrawn)
    let qr = label.codeReports.first { $0.symbology == "QR" }!
    #expect(qr.redrawn && qr.moduleDots == qr.moduleDots.rounded())
    // Every bar and space is a whole number of modules.
    let n = Int(bars.moduleDots)
    let runs = CodeAnalysis.analyze(label).first { $0.symbology == "Code128" }!.runs
    #expect(runs.keys.allSatisfy { $0 % n == 0 })

    var off = LabelOptions()
    off.snapCodes = false
    let plain = LabelComposer.compose(codePage(), off)
    #expect(plain.codeReports.allSatisfy { !$0.redrawn })
    #expect(plain.placement.scale == min(288 / plain.crop.rect.width, 432 / plain.crop.rect.height))
}

@Test func prefersPicketFenceOnNearTie() {
    // A square page fits a 4x6 label equally either way; bars lying flat would print as a ladder.
    let page = codePage(size: CGSize(width: 300, height: 300), turned: true)
    var o = LabelOptions()
    o.crop = .none
    let label = LabelComposer.compose(page, o)
    #expect(label.rotated)
    #expect(label.codeReports.first { $0.symbology == "Code128" }?.picketFence == true)
    o.snapCodes = false
    #expect(!LabelComposer.compose(page, o).rotated)
}

@Test func warnsWhenBarsAreTooThin() {
    var o = LabelOptions()
    o.size = LabelSize(width: 2, height: 1.25)
    let label = LabelComposer.compose(codePage(), o)
    let bars = label.codeReports.first { $0.symbology == "Code128" }
    #expect(bars?.severity == .error)
    #expect(label.warnings.contains { $0.contains("Code128") && $0.contains("too small to scan") })
}

@Test func picksHalftoneForFlatGrays() {
    let flat = SourcePage(size: CGSize(width: 288, height: 432)) { ctx in
        ctx.setFillColor(gray: 0.55, alpha: 1)
        ctx.fill(CGRect(x: 20, y: 60, width: 248, height: 300))
        ctx.setFillColor(gray: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 20, y: 370, width: 248, height: 40))
    }
    #expect(LabelComposer.compose(flat, LabelOptions()).ink == .halftone)
}
