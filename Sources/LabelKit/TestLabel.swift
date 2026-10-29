import CoreGraphics
import Foundation

/// The generated pages: the calibration label, the step wedge and the ink sample.
/// Used by the app (Printers > Print Test Label, Ink Modes), the CLI (test-label, step-wedge) and screenshots.
public enum TestLabel: String, CaseIterable, Sendable {
    /// Border 2 mm in, rulers and a QR code: offset and scale.
    case pattern
    /// Gray patches from 0 to 100 %: how a printer renders grays.
    case stepWedge
    /// The pattern plus a gray ramp, so each ink mode shows its character.
    case inkSample

    /// "MUNBYN ITPP941AP · 4 × 6 in"
    public static func title(printer: PrinterInfo?, size: LabelSize) -> String {
        "\(printer?.displayName ?? "Peel Good Inc.") · \(size.primary)"
    }

    public func page(size: LabelSize, title: String) -> SourcePage {
        switch self {
        case .pattern: TestPattern.page(size: size, title: title)
        case .stepWedge: TestPattern.stepWedge(size: size, title: title)
        case .inkSample: TestPattern.inkSample(size: size, title: title)
        }
    }

    /// The options a generated page prints with: as drawn (no crop, no turning). The pattern prints crisp;
    /// the wedge shows the printer's raw response, so photo ink and no tone correction unless the caller set them.
    public func adjust(_ o: inout LabelOptions, keepInk: Bool = false, keepToneGamma: Bool = false) {
        o.crop = .none
        o.rotation = .none
        switch self {
        case .pattern: if !keepInk { o.ink = .crisp }
        case .stepWedge:
            if !keepInk { o.ink = .photo }
            if !keepToneGamma { o.toneGamma = 1 }
        case .inkSample: break
        }
    }

    /// File name stem: "test-label-4x6", "step-wedge-4x6".
    public func fileStem(_ size: LabelSize) -> String {
        switch self {
        case .pattern: "test-label-\(size)"
        case .stepWedge: "step-wedge-\(size)"
        case .inkSample: "ink-sample-\(size)"
        }
    }

    /// Writes the page to a one-page PDF of the label's size.
    public func writePDF(size: LabelSize, title: String, to url: URL) throws {
        try page(size: size, title: title).writePDF(to: url)
    }
}

extension SourcePage {
    /// A one-page PDF of this page at its own size.
    public func writePDF(to url: URL) throws {
        var box = CGRect(origin: .zero, size: size)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw LabelWriter.WriteError.cannotCreate(url) }
        pdf.beginPDFPage(nil)
        draw(in: pdf)
        pdf.endPDFPage()
        pdf.closePDF()
    }
}

extension LabelWriter {
    /// The label PDF a printer gets: 1-bit for label printers, vectors for color and office printers.
    public static func write(_ labels: [ComposedLabel], size: LabelSize, forLabelPrinter: Bool, to url: URL) throws {
        if forLabelPrinter { try writePDF(labels, size: size, to: url) } else { try writeVectorPDF(labels, size: size, to: url) }
    }
}
