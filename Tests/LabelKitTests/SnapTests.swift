import CoreGraphics
import Foundation
import Testing
@testable import LabelKit

// Issue #15: snapping a barcode to the dot grid shrank a CN22/CN23 customs form from ~104% to 87%.
// Issue #12: Fill label pushed a page that was already full past the label's edge by the printer nudge.
// The pages below stand in for the reported ones, so real customer documents stay out of the repo.

/// A 4x6 customs form: 286 x 431 pt, a frame 14 pt in from the edges, a Code128 at the top whose
/// bars are 0.83 pt, which is 2.4 dots once Fill label enlarges the form to ~104%.
func customsForm() -> SourcePage {
    let bars = codeImage("CICode128BarcodeGenerator", "LO446460477GB")
    return SourcePage(size: CGSize(width: 286, height: 431)) { ctx in
        ctx.interpolationQuality = .none
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 14.5, y: 14.5, width: 286 - 29, height: 431 - 29))
        ctx.setFillColor(gray: 0, alpha: 1)
        for y in stride(from: 60.0, to: 330, by: 30) { ctx.fill(CGRect(x: 24, y: y, width: 200, height: 8)) }
        let w = CGFloat(bars.width) * 0.83
        ctx.draw(bars, in: CGRect(x: 24, y: 350, width: w, height: 50))
    }
}

@Test func snappingNeverShrinksTheLabelByMoreThanFivePercent() {
    var o = LabelOptions()
    o.crop = .content
    o.snapCodes = false
    let plain = LabelComposer.compose(customsForm(), o)
    o.snapCodes = true
    let snapped = LabelComposer.compose(customsForm(), o)
    #expect(plain.scale > 1.02, "trimmed and enlarged: \(plain.scale)")
    #expect(snapped.scale >= plain.scale * CodeFit.maxShrink, "snapped \(snapped.scale) vs unsnapped \(plain.scale)")
    #expect(snapped.missingCodes.isEmpty, "the code still scans")
    #expect(snapped.clip.isEmpty)
}

@Test func snappingStillUsesWholeDotsWithinFivePercent() {
    // 0.73 pt bars: 2.03 dots at 100%, so 2 dots costs about 1.5%.
    var o = LabelOptions()
    o.crop = .none
    let label = LabelComposer.compose(codePage(module: 0.73), o)
    let bars = label.codeReports.first { $0.symbology == "Code128" }!
    #expect(abs(bars.moduleDots - bars.moduleDots.rounded()) < 1e-9)
    o.snapCodes = false
    #expect(label.scale >= LabelComposer.compose(codePage(module: 0.73), o).scale * CodeFit.maxShrink)
}

/// A page whose ink runs to 1 pt from each edge, like a Click & Drop label trimmed out of an A4 despatch note.
func fullPage() -> SourcePage {
    SourcePage(size: CGSize(width: 288, height: 432)) { ctx in
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 1, y: 1, width: 286, height: 3))
        ctx.fill(CGRect(x: 1, y: 428, width: 286, height: 3))
        ctx.fill(CGRect(x: 1, y: 1, width: 3, height: 430))
        ctx.fill(CGRect(x: 284, y: 1, width: 3, height: 430))
        ctx.fill(CGRect(x: 40, y: 200, width: 200, height: 30))
    }
}

@Test func fillKeepsAFullPageOnTheLabelAfterTheNudge() {
    var o = LabelOptions()
    o.nudgeMM = CGPoint(x: 2, y: 0)
    let label = LabelComposer.compose(fullPage(), o)
    let ink = label.crop.ink.applying(label.placement.transform)
    #expect(ink.minX >= -0.01 && ink.maxX <= 288.01, "ink on the label: \(ink)")
    #expect(label.clip.isEmpty, "\(label.clip)")
    #expect(label.scale < 1, "shrunk just enough for the 2 mm nudge: \(label.scale)")
    #expect(label.scale > 0.95)
}

@Test func fillIgnoresANudgeThePaddingAbsorbs() {
    // The frame is 14 pt in: with 2 mm padding, a 2 mm nudge only moves white padding off the edge.
    var o = LabelOptions()
    o.crop = .content
    o.snapCodes = false
    let still = LabelComposer.compose(customsForm(), o)
    o.nudgeMM = CGPoint(x: 2, y: 0)
    let nudged = LabelComposer.compose(customsForm(), o)
    #expect(abs(nudged.scale - still.scale) < 1e-6)
    #expect(nudged.clip.isEmpty)
}
