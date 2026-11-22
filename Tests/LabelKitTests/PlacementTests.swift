import CoreGraphics
import Foundation
import Testing
@testable import LabelKit

// Issue #8: Fit page prints the whole page as designed; Direct prints it at physical size. The page below stands in for the reported one
// (449 x 305 pt, landscape, white margins round a bordered design), so the real label stays out of the repo.

/// 449 x 305 pt with ~40 pt of white margin round a bordered block and two bars of "text".
func marginPage() -> SourcePage {
    SourcePage(size: CGSize(width: 449, height: 305)) { ctx in
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(3)
        ctx.stroke(CGRect(x: 40, y: 30, width: 369, height: 245))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 70, y: 180, width: 300, height: 60))
        ctx.fill(CGRect(x: 70, y: 80, width: 200, height: 20))
    }
}

let mm: CGFloat = 72 / 25.4

/// The page's corners on the label, in label points (origin bottom-left).
func placed(_ label: ComposedLabel) -> CGRect { label.page.bounds.applying(label.placement.transform) }

@Test func fitPageKeepsTheWholePageWithItsMargins() {
    var o = LabelOptions()
    o.fit = .fitPage
    o.nudgeMM = CGPoint(x: 2, y: 0)   // the MUNBYN in the report
    let label = LabelComposer.compose(marginPage(), o)
    #expect(label.fit == .fitPage)
    #expect(!label.trimmed)
    #expect(label.crop.rect == label.page.bounds)
    #expect(label.scale <= 1)
    #expect(label.rotated, "landscape page on a portrait label turns")
    // The whole page, nudge included, lands on the 4x6 label: nothing is cut at the edges.
    let r = placed(label), target = CGRect(origin: .zero, size: o.size.points)
    #expect(target.insetBy(dx: -0.01, dy: -0.01).contains(r), "page lands at \(r)")
    // Only as far down as the nudge needs: 288 pt less 2 mm each side, across 305 pt.
    #expect(abs(label.scale - (288 - 4 * mm) / 305) < 0.002)
    #expect(label.placementSummary.hasPrefix("fit-page, whole page, no trim"))
}

@Test func fitPageMarginsStayWhiteOnTheBitmap() {
    var o = LabelOptions()
    o.fit = .fitPage
    let label = LabelComposer.compose(marginPage(), o)
    let dots = CGFloat(o.dpi) / 72
    // The page's margin (outside the frame) maps to bitmap pixels that are white.
    let frame = CGRect(x: 40, y: 30, width: 369, height: 245).insetBy(dx: -4, dy: -4).applying(label.placement.transform)
    let b = label.bitmap
    var inkOutside = 0
    for y in 0..<b.height {
        for x in 0..<b.width where b[x, y] == 0 {
            let p = CGPoint(x: (CGFloat(x) + 0.5) / dots, y: CGFloat(b.height - y) / dots)
            if !frame.contains(p) { inkOutside += 1 }
        }
    }
    #expect(inkOutside == 0)
}

@Test func fitPageNeverScalesUp() {
    var o = LabelOptions()
    o.fit = .fitPage
    let small = SourcePage(size: CGSize(width: 144, height: 72)) { ctx in
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 30))
    }
    let label = LabelComposer.compose(small, o)
    #expect(label.scale == 1)
    #expect(!label.rotated, "a page that fits isn't turned")
    let r = placed(label)
    #expect(abs(r.midX - 144) < 0.01 && abs(r.midY - 216) < 0.01, "centred: \(r)")
}

@Test func fitPagePrintsALabelSizedPageOneToOne() {
    var o = LabelOptions()
    o.fit = .fitPage
    let page = SourcePage(size: CGSize(width: 288, height: 432)) { ctx in
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 288, height: 4))
        ctx.fill(CGRect(x: 60, y: 200, width: 160, height: 40))
    }
    let label = LabelComposer.compose(page, o)
    #expect(label.scale == 1)
    #expect(!label.rotated)
    #expect(!label.trimmed)
    #expect(placed(label) == CGRect(x: 0, y: 0, width: 288, height: 432))
}

@Test func testLabelsStayOneToOneWhenThePrinterIsFitPage() {
    var o = LabelOptions()
    o.fit = .fitPage
    o.nudgeMM = CGPoint(x: 2, y: 0)
    TestLabel.pattern.adjust(&o)
    #expect(o.fit == .fill)
}

@Test func fitPageCodesOnlyShrinkToWholeDots() {
    var o = LabelOptions()
    o.fit = .fitPage
    let label = LabelComposer.compose(codePage(), o)   // a 4x6 page: fits at 100% or just under
    #expect(label.scale <= 1)
    #expect(!label.trimmed)
    #expect(CGRect(origin: .zero, size: o.size.points).insetBy(dx: -0.01, dy: -0.01).contains(placed(label)))
}

@Test func defaultStillTrimsAndFills() {
    let label = LabelComposer.compose(marginPage(), LabelOptions())
    #expect(label.fit == .fill)
    #expect(label.clip.isEmpty)
    #expect(label.trimmed)
    #expect(label.rotated)
    #expect(label.scale > 1.05, "trimmed to the frame and scaled up, as before: \(label.scale)")
}

@Test func fitPagePreviewIsWhatPrints() throws {
    var o = LabelOptions()
    o.fit = .fitPage
    o.nudgeMM = CGPoint(x: 2, y: -1)
    let label = LabelComposer.compose(marginPage(), o)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fit-page-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    // The PDF a label printer gets, read back at the printer's resolution, is the preview dot for dot.
    try LabelWriter.writePDF([label], size: o.size, to: url)
    let printed = try #require(try LabelRaster.bitmaps(pdf: url, dpi: o.dpi).first)
    #expect(printed.width == label.bitmap.width && printed.height == label.bitmap.height)
    let differ = zip(printed.pixels, label.bitmap.pixels).filter { $0 != $1 }.count
    #expect(differ == 0)
}

@Test func fitPageNudgeMovesThePreview() {
    var o = LabelOptions()
    o.fit = .fitPage
    let still = LabelComposer.compose(marginPage(), o)
    o.nudgeMM = CGPoint(x: 2, y: 0)
    let nudged = LabelComposer.compose(marginPage(), o)
    // The nudge shrinks the room a little, so compare centres: they move by the nudge (within the code-snap shift).
    #expect(abs(placed(nudged).midX - placed(still).midX - 2 * mm) < 0.6, "the preview moves by the nudge")
}

@Test func parsesPlacementNames() {
    for text in ["fit-page", "Fit Page", "as-is", "AS-IS", "as is", "as_is", "asis", "actual"] { #expect(FitMode(parsing: text) == .fitPage, "\(text)") }
    #expect(FitMode(parsing: "fill") == .fill)
    #expect(FitMode(parsing: "fit") == .fill, "0.5.4's fit is a quiet alias")
    #expect(FitMode(parsing: "direct") == .direct)
    #expect(FitMode(parsing: "cover") == .cover)
    #expect(FitMode(parsing: "stretch") == nil)
    #expect(FitMode(legacy: "fill") == .cover && FitMode(legacy: "fit") == .fill)
    #expect(FitMode.allCases.map(\.title) == ["Fill label", "Fit page", "Direct", "Cover"])
}

@Test func coverStillCovers() {
    var o = LabelOptions()
    o.fit = .cover
    let label = LabelComposer.compose(marginPage(), o)
    #expect(label.trimmed)
    #expect(!label.clip.isEmpty, "cover cuts off what overflows: \(label.clip)")
}

// MARK: Direct: physical size, 1:1

@Test func directPrintsAtPhysicalSize() {
    var o = LabelOptions()
    o.fit = .direct
    let label = LabelComposer.compose(marginPage(), o)
    #expect(label.fit == .direct)
    #expect(label.scale == 1, "no auto-scaling")
    #expect(!label.trimmed)
    #expect(label.rotated, "landscape page on a portrait label turns to match")
    // 449 x 305 pt is 158.4 x 107.6 mm; turned, that's 107.6 mm across a 101.6 mm label and 158.4 mm down a 152.4 mm one.
    let r = placed(label)
    #expect(abs(Double(r.width) * 25.4 / 72 - 107.6) < 0.05 && abs(Double(r.height) * 25.4 / 72 - 158.4) < 0.05, "\(r)")
    #expect(abs(r.midX - 144) < 0.2 && abs(r.midY - 216) < 0.2, "centred")
    #expect(label.clip == Clip(left: 3.0, right: 3.0, top: 3.0, bottom: 3.0))
    #expect(label.placementSummary == "direct, whole page, no trim, 100.0%, turned clockwise, clipped 3.0 mm left/right, 3.0 mm top/bottom")
}

@Test func directClipFollowsTheNudge() {
    var o = LabelOptions()
    o.fit = .direct
    o.nudgeMM = CGPoint(x: 2, y: 0)   // the MUNBYN: 2 mm right
    let label = LabelComposer.compose(marginPage(), o)
    #expect(label.scale == 1)
    #expect(label.clip == Clip(left: 1.0, right: 5.0, top: 3.0, bottom: 3.0), "\(label.clip)")
    #expect(label.clip.description == "1.0 mm left, 5.0 mm right, 3.0 mm top/bottom")
}

@Test func directScaleResizesIt() {
    var o = LabelOptions()
    o.fit = .direct
    o.scalePercent = 94
    let label = LabelComposer.compose(marginPage(), o)
    #expect(abs(label.scale - 0.94) < 1e-9)
    #expect(abs(Double(placed(label).width) * 25.4 / 72 - 107.6 * 0.94) < 0.05)
    #expect(label.clip.isEmpty, "94% of 107.6 x 158.4 mm (101.1 x 148.9) fits on 101.6 x 152.4 mm: \(label.clip)")
    o.scalePercent = 105
    #expect(abs(LabelComposer.compose(marginPage(), o).scale - 1.05) < 1e-9)
}

@Test func directKeepsOrientationWhenAsked() {
    var o = LabelOptions()
    o.fit = .direct
    o.rotation = .none
    let label = LabelComposer.compose(marginPage(), o)
    #expect(!label.rotated)
    #expect(label.scale == 1)
    // 158.4 mm across a 101.6 mm label: 28.4 mm off each side.
    #expect(label.clip.left == 28.4 && label.clip.right == 28.4)
}

@Test func directWarnsOnlyWhenTheDesignIsCut() {
    var o = LabelOptions()
    o.fit = .direct
    // The repro-sized page clips only white margin (the frame sits 40 pt in): no warning.
    #expect(!LabelComposer.compose(marginPage(), o).warnings.contains { $0.contains("cut off") })
    o.rotation = .none   // now the frame itself runs off the sides
    let w = LabelComposer.compose(marginPage(), o).warnings
    #expect(w.contains { $0.contains("cut off") }, "\(w)")
}

@Test func directPreviewIsWhatPrints() throws {
    var o = LabelOptions()
    o.fit = .direct
    o.nudgeMM = CGPoint(x: 2, y: -1)
    let label = LabelComposer.compose(marginPage(), o)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try LabelWriter.writePDF([label], size: o.size, to: url)
    let printed = try #require(try LabelRaster.bitmaps(pdf: url, dpi: o.dpi).first)
    #expect(zip(printed.pixels, label.bitmap.pixels).filter { $0 != $1 }.count == 0, "clipping and nudge included")
}

@Test func directCodesKeepTheirSize() {
    var o = LabelOptions()
    o.fit = .direct
    let label = LabelComposer.compose(codePage(), o)   // a 4x6 page with a Code128 and a QR
    #expect(label.scale == 1, "no snapping to whole dots in direct")
    #expect(label.clip.isEmpty)
}
