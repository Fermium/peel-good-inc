import CoreGraphics
import Foundation
import Testing
@testable import LabelKit

// MARK: Helpers

/// A flat patch of one 8-bit gray.
func flat(_ v: UInt8, size: Int = 96) -> GrayBitmap {
    GrayBitmap(width: size, height: size, pixels: Array(repeating: v, count: size * size))
}

func dithered(_ b: GrayBitmap, _ ink: InkMode, gamma: Double = Dither.defaultGamma) -> GrayBitmap {
    var o = LabelOptions()
    o.toneGamma = gamma
    var out = b
    LabelComposer.dither(&out, ink: ink, options: o, codes: [])
    return out
}

func blackShare(_ b: GrayBitmap) -> Double { Double(b.pixels.filter { $0 == 0 }.count) / Double(b.pixels.count) }

/// The old Photo mode (Atkinson on sRGB code values), kept here to compare against.
func legacyAtkinson(_ b: GrayBitmap) -> GrayBitmap {
    var b = b
    let w = b.width, h = b.height
    var buf = b.pixels.map(Float.init)
    for y in 0..<h {
        for x in 0..<w {
            let old = buf[y * w + x]
            let new: Float = old < 127.5 ? 0 : 255
            buf[y * w + x] = new
            let err = (old - new) / 8
            for (dx, dy) in [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)] {
                let nx = x + dx, ny = y + dy
                if nx >= 0, nx < w, ny < h { buf[ny * w + nx] += err }
            }
        }
    }
    b.pixels = buf.map { $0 < 128 ? 0 : 255 }
    return b
}

/// Simple thermal print model (the dither bench's nominal one): every black dot burns a disk of
/// `radius` dot pitches, overlapping its neighbours; black reflects `black`, paper 1. Returns mean reflectance of the patch centre.
func printedReflectance(_ b: GrayBitmap, radius: Double = 0.66, black: Double = 0.06) -> Double {
    let s = 5, margin = 8
    let w = b.width * s, h = b.height * s
    var ink = [Bool](repeating: false, count: w * h)
    let r = radius * Double(s), n = Int(r.rounded(.up))
    for y in 0..<b.height {
        for x in 0..<b.width where b[x, y] == 0 {
            let cx = Double(x * s + s / 2), cy = Double(y * s + s / 2)
            for py in max(0, Int(cy) - n)...min(h - 1, Int(cy) + n) {
                for px in max(0, Int(cx) - n)...min(w - 1, Int(cx) + n) {
                    let dx = Double(px) - cx, dy = Double(py) - cy
                    if dx * dx + dy * dy <= r * r { ink[py * w + px] = true }
                }
            }
        }
    }
    var sum = 0.0, count = 0
    for py in (margin * s)..<(h - margin * s) {
        for px in (margin * s)..<(w - margin * s) { sum += ink[py * w + px] ? black : 1; count += 1 }
    }
    return sum / Double(count)
}

func lstar(_ y: Double) -> Double { y > 0.008856 ? 116 * cbrt(y) - 16 : 903.3 * y }

/// What a gray should print as: its linear light, scaled between thermal black and paper.
func targetReflectance(_ v: UInt8, black: Double = 0.06) -> Double { black + (1 - black) * Dither.linear[Int(v)] }

let ramp: [UInt8] = stride(from: 24, through: 232, by: 16).map(UInt8.init)

// MARK: Tone

@Test func photoToneMatchesAfterDotGain() {
    var newErr = 0.0, oldErr = 0.0
    for v in ramp {
        let target = lstar(targetReflectance(v))
        newErr += abs(lstar(printedReflectance(dithered(flat(v), .photo))) - target)
        oldErr += abs(lstar(printedReflectance(legacyAtkinson(flat(v)))) - target)
    }
    newErr /= Double(ramp.count); oldErr /= Double(ramp.count)
    #expect(newErr < 2.5, "mean ΔL* \(newErr)")
    #expect(newErr < oldErr / 2, "new \(newErr) vs old \(oldErr)")
}

@Test func halftoneToneMatchesAfterDotGain() {
    var err = 0.0
    for v in ramp {
        err += abs(lstar(printedReflectance(dithered(flat(v), .halftone))) - lstar(targetReflectance(v)))
    }
    #expect(err / Double(ramp.count) < 3, "mean ΔL* \(err / Double(ramp.count))")
}

@Test func toneLUTEndsAndCutoffBias() {
    let lut = Dither.toneLUT(gamma: 0.65)
    #expect(lut[0] == 1 && lut[255] == 0)
    #expect(zip(lut, lut.dropFirst()).allSatisfy { $0 >= $1 })
    // Linear light plus gain: mid gray asks for more than half coverage.
    #expect(lut[128] > 0.6 && lut[128] < 0.75)
    #expect(Dither.toneLUT(gamma: 0.65, cutoff: 0.6)[128] > lut[128])
    #expect(Dither.toneLUT(gamma: 0.65, cutoff: 0.4)[128] < lut[128])
    // The wedge's grays request exactly their coverage with compensation off.
    let raw = Dither.toneLUT(gamma: 1)
    for c in TestPattern.wedgeSteps {
        let v = Int((TestPattern.wedgeGray(c) * 255).rounded())
        #expect(abs(Double(raw[v]) - c) < 0.02)
    }
}

// MARK: Dots

@Test func photoLeavesNoIsolatedDotsOnFlatGrays() {
    for v in stride(from: 8, through: 248, by: 8).map(UInt8.init) {
        let b = dithered(flat(v, size: 128), .photo)
        #expect(Dither.isolatedDots(b) == 0, "gray \(v)")
    }
    // The old mode left plenty in light grays.
    #expect(Dither.isolatedDots(legacyAtkinson(flat(200, size: 128))) > 100)
}

@Test func halftoneCoverageIsMonotonic() {
    let shares = (0...255).map { blackShare(dithered(flat(UInt8($0), size: 36), .halftone)) }
    #expect(zip(shares, shares.dropFirst()).allSatisfy { $0 >= $1 })
    #expect(shares[0] == 1 && shares[255] == 0)
    let (t, th) = Dither.screen()
    #expect(t == 6 && Set(th).count == 36)
}

@Test func errorDoesNotCrossMasks() {
    // A fixed white block in a mid gray: the rows right after it look like the rows far from it.
    var b = flat(128, size: 120)
    var m = Dither.Mask(width: 120, height: 120)
    for y in 0..<60 { for x in 0..<120 { m.fix(y * 120 + x, to: 255) } }
    Dither.floydSteinberg(&b, lut: Dither.toneLUT(gamma: 0.65), mask: m)
    #expect(b.pixels[0..<(60 * 120)].allSatisfy { $0 == 255 })
    let near = blackShare(GrayBitmap(width: 120, height: 10, pixels: Array(b.pixels[(60 * 120)..<(70 * 120)])))
    let far = blackShare(GrayBitmap(width: 120, height: 10, pixels: Array(b.pixels[(100 * 120)..<(110 * 120)])))
    #expect(abs(near - far) < 0.08, "near \(near) far \(far)")
}

// MARK: Codes and text

/// Codes on a gray gradient background, so the dither has something to do around them.
func codesOnGray() -> SourcePage {
    let inner = codePage()
    return SourcePage(size: CGSize(width: 288, height: 432)) { ctx in
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                           colors: [CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0.9, alpha: 1)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 288, y: 0), options: [])
        inner.draw(in: ctx)
    }
}

func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name)
}

@Test(arguments: [InkMode.photo, .halftone])
func codesStillScanWhenDithered(_ ink: InkMode) throws {
    var pages = [codePage(), codesOnGray()]
    // Generated by `swift run make-fixtures`; checked when present.
    for name in ["letter-usps.pdf", "letter-ups-landscape.pdf", "amazon-return.png", "two-labels.pdf"]
    where FileManager.default.fileExists(atPath: fixture(name).path) {
        pages += try DocumentLoader.load(fixture(name))
    }
    var o = LabelOptions()
    o.ink = ink
    for (i, page) in pages.enumerated() {
        let label = LabelComposer.compose(page, o)
        #expect(label.ink == ink)
        #expect(!label.expectedCodes.isEmpty, "page \(i)")
        #expect(label.missingCodes.isEmpty, "page \(i): \(label.missingCodes.map(\.symbology))")
    }
}

@Test(arguments: [InkMode.photo, .halftone])
func codeAreasMatchCrispExactly(_ ink: InkMode) {
    for (gray, page) in [(false, codePage()), (true, codesOnGray())] {
        var o = LabelOptions()
        o.ink = .crisp
        let crisp = LabelComposer.compose(page, o)
        o.ink = ink
        let other = LabelComposer.compose(page, o)
        #expect(!other.codeAreas.isEmpty)
        #expect(other.codeAreas == crisp.codeAreas)
        let b = other.bitmap, c = crisp.bitmap
        var checked = 0, differ = 0
        for r in other.codeAreas {
            let x0 = max(0, Int(r.minX.rounded(.down))), x1 = min(b.width, Int(r.maxX.rounded(.up)))
            let y0 = max(0, Int(r.minY.rounded(.down))), y1 = min(b.height, Int(r.maxY.rounded(.up)))
            for y in y0..<y1 { for x in x0..<x1 { checked += 1; if b[x, y] != c[x, y] { differ += 1 } } }
        }
        #expect(checked > 10_000)
        #expect(differ == 0)
        // Outside the codes the gray background really is dithered.
        if gray { #expect(b.pixels != c.pixels) }
    }
}

@Test func textOnGrayIsThresholdedWithHalo() {
    // Black bars like text strokes on a 50% gray.
    var b = flat(160, size: 80)
    for y in 30..<50 { for x in 20..<24 { b[x, y] = 0 } }
    let out = dithered(b, .photo)
    for y in 30..<50 {
        for x in 20..<24 { #expect(out[x, y] == 0) }
        #expect(out[19, y] == 255 && out[24, y] == 255)
    }
    // Big dark shapes (photo shadows) are left to the dither: no halo around them.
    var big = flat(160, size: 120)
    for y in 10..<110 { for x in 10..<110 { big[x, y] = 30 } }
    let m = Dither.mask(big, level: 128, codes: [], text: true)
    #expect(m.count == 0)
}

@Test func autoStillPicksCrispForCodesAndPhotoForGrays() {
    #expect(LabelComposer.compose(codesOnGray(), LabelOptions()).ink == .crisp)
    let gradient = SourcePage(size: CGSize(width: 288, height: 432)) { ctx in
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                           colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 432), options: [])
    }
    #expect(LabelComposer.compose(gradient, LabelOptions()).ink == .photo)
}

@Test func stepWedgeHasElevenPatches() {
    let page = TestPattern.stepWedge(size: .fourBySix)
    var o = LabelOptions()
    o.crop = .none
    o.ink = .photo
    o.toneGamma = 1
    o.protectText = false
    let label = LabelComposer.compose(page, o)
    #expect(TestPattern.wedgeSteps.count == 11)
    #expect(label.bitmap.pixels.allSatisfy { $0 == 0 || $0 == 255 })
    // Darker overall than white, lighter than solid.
    let share = blackShare(label.bitmap)
    #expect(share > 0.2 && share < 0.8)
}
