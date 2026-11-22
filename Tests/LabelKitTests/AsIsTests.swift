import CoreGraphics
import Foundation
import Testing
@testable import LabelKit

// Issue #8: "as is" prints the page exactly as designed. The page below stands in for the reported one
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

@Test func asIsKeepsTheWholePageWithItsMargins() {
    var o = LabelOptions()
    o.fit = .asIs
    o.nudgeMM = CGPoint(x: 2, y: 0)   // the MUNBYN in the report
    let label = LabelComposer.compose(marginPage(), o)
    #expect(label.fit == .asIs)
    #expect(!label.trimmed)
    #expect(label.crop.rect == label.page.bounds)
    #expect(label.scale <= 1)
    #expect(label.rotated, "landscape page on a portrait label turns")
    // The whole page, nudge included, lands on the 4x6 label: nothing is cut at the edges.
    let r = placed(label), target = CGRect(origin: .zero, size: o.size.points)
    #expect(target.insetBy(dx: -0.01, dy: -0.01).contains(r), "page lands at \(r)")
    // Only as far down as the nudge needs: 288 pt less 2 mm each side, across 305 pt.
    #expect(abs(label.scale - (288 - 4 * mm) / 305) < 0.002)
    #expect(label.placementSummary.hasPrefix("as-is, whole page, no trim"))
}

@Test func asIsMarginsStayWhiteOnTheBitmap() {
    var o = LabelOptions()
    o.fit = .asIs
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

@Test func asIsNeverScalesUp() {
    var o = LabelOptions()
    o.fit = .asIs
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

@Test func asIsPrintsALabelSizedPageOneToOne() {
    var o = LabelOptions()
    o.fit = .asIs
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

@Test func testLabelsStayOneToOneWhenThePrinterIsAsIs() {
    var o = LabelOptions()
    o.fit = .asIs
    o.nudgeMM = CGPoint(x: 2, y: 0)
    TestLabel.pattern.adjust(&o)
    #expect(o.fit == .fit)
}

@Test func asIsCodesOnlyShrinkToWholeDots() {
    var o = LabelOptions()
    o.fit = .asIs
    let label = LabelComposer.compose(codePage(), o)   // a 4x6 page: fits at 100% or just under
    #expect(label.scale <= 1)
    #expect(!label.trimmed)
    #expect(CGRect(origin: .zero, size: o.size.points).insetBy(dx: -0.01, dy: -0.01).contains(placed(label)))
}

@Test func defaultStillTrimsAndFills() {
    let label = LabelComposer.compose(marginPage(), LabelOptions())
    #expect(label.fit == .fit)
    #expect(label.trimmed)
    #expect(label.rotated)
    #expect(label.scale > 1.05, "trimmed to the frame and scaled up, as before: \(label.scale)")
}

@Test func asIsPreviewIsWhatPrints() throws {
    var o = LabelOptions()
    o.fit = .asIs
    o.nudgeMM = CGPoint(x: 2, y: -1)
    let label = LabelComposer.compose(marginPage(), o)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("as-is-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    // The PDF a label printer gets, read back at the printer's resolution, is the preview dot for dot.
    try LabelWriter.writePDF([label], size: o.size, to: url)
    let printed = try #require(try LabelRaster.bitmaps(pdf: url, dpi: o.dpi).first)
    #expect(printed.width == label.bitmap.width && printed.height == label.bitmap.height)
    let differ = zip(printed.pixels, label.bitmap.pixels).filter { $0 != $1 }.count
    #expect(differ == 0)
}

@Test func asIsNudgeMovesThePreview() {
    var o = LabelOptions()
    o.fit = .asIs
    let still = LabelComposer.compose(marginPage(), o)
    o.nudgeMM = CGPoint(x: 2, y: 0)
    let nudged = LabelComposer.compose(marginPage(), o)
    // The nudge shrinks the room a little, so compare centres: they move by the nudge (within the code-snap shift).
    #expect(abs(placed(nudged).midX - placed(still).midX - 2 * mm) < 0.6, "the preview moves by the nudge")
}

@Test func parsesAsIsSpellings() {
    for text in ["as-is", "AS-IS", "as is", "as_is", "asis", "actual"] { #expect(FitMode(parsing: text) == .asIs, "\(text)") }
    #expect(FitMode(parsing: "fit") == .fit)
    #expect(FitMode(parsing: "stretch") == nil)
    #expect(FitMode.asIs.title == "As is")
}
