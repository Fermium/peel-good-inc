import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum LabelWriter {
    public enum WriteError: Error, CustomStringConvertible {
        case cannotCreate(URL)
        public var description: String {
            switch self { case .cannotCreate(let url): "can't write \(url.path)" }
        }
    }

    /// One PDF page per label, each the exact label size, holding the 1-bit image edge to edge.
    public static func writePDF(_ labels: [ComposedLabel], size: LabelSize, to url: URL) throws {
        var media = CGRect(origin: .zero, size: size.points)
        guard let pdf = CGContext(url as CFURL, mediaBox: &media, nil) else { throw WriteError.cannotCreate(url) }
        for label in labels {
            pdf.beginPDFPage(nil)
            pdf.interpolationQuality = .none
            if let image = label.bitmap.oneBitImage() { pdf.draw(image, in: media) }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    /// One PDF page per label with the cropped source drawn as vectors, for color or photo printers.
    public static func writeVectorPDF(_ labels: [ComposedLabel], size: LabelSize, to url: URL) throws {
        var media = CGRect(origin: .zero, size: size.points)
        guard let pdf = CGContext(url as CFURL, mediaBox: &media, nil) else { throw WriteError.cannotCreate(url) }
        for label in labels {
            pdf.beginPDFPage(nil)
            pdf.saveGState()
            label.placement.apply(to: pdf)
            label.page.draw(in: pdf)
            pdf.restoreGState()
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    public static func writePNG(_ label: ComposedLabel, to url: URL) throws {
        guard let image = label.bitmap.cgImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw WriteError.cannotCreate(url) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw WriteError.cannotCreate(url) }
    }
}

/// Label PDFs back to dots, with the Mac's own PDF renderer.
public enum LabelRaster {
    /// Each page at `dpi`, sized as the composer sizes labels, so a 1-bit label PDF written at the same
    /// resolution comes back dot for dot.
    public static func bitmaps(pdf url: URL, dpi: Double) throws -> [GrayBitmap] {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw LabelPrint.Failed(description: "can't read \(url.lastPathComponent)") }
        let dots = CGFloat(dpi) / 72
        return (1...doc.numberOfPages).compactMap { doc.page(at: $0) }.map { page in
            let box = page.getBoxRect(.mediaBox)
            return GrayBitmap.render(width: Int((box.width * dots).rounded()), height: Int((box.height * dots).rounded())) { ctx in
                ctx.interpolationQuality = .none
                ctx.setShouldAntialias(false)
                ctx.scaleBy(x: dots, y: dots)
                ctx.translateBy(x: -box.minX, y: -box.minY)
                ctx.drawPDFPage(page)
            }
        }
    }
}

public enum LabelPrint {
    public struct Failed: Error, CustomStringConvertible {
        public let description: String
    }

    /// `lp` arguments that print the file 1:1 on the given media, with no dialog.
    public static func lpArguments(file: URL, printer: String, size: LabelSize, copies: Int) -> [String] {
        ["-d", printer, "-o", "media=\(size.cupsMedia)", "-o", "print-scaling=none", "-n", String(copies), file.path]
    }

    /// Sends the job and returns lp's output (the job id), or a summary for a Zebra on the network
    /// once it has printed.
    @discardableResult
    public static func send(file: URL, printer: PrinterInfo, size: LabelSize, copies: Int = 1) throws -> String {
        if printer.zebraHost != nil { return try send(zplJob(file: file, printer: printer, copies: copies), to: printer) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
        process.arguments = lpArguments(file: file, printer: printer.name, size: size, copies: copies)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe would otherwise block lp forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw Failed(description: "lp failed: \(output)") }
        return output
    }

    /// A label PDF as the ZPL a Zebra gets: rendered at the resolution the labels were composed at,
    /// one graphic per label, ^LL only when the printer reports continuous media.
    public struct ZPLJob: Sendable {
        public var data: Data
        /// Labels printed in all, copies included.
        public var labels: Int
    }

    public static func zplJob(file: URL, printer: PrinterInfo, copies: Int) throws -> ZPLJob {
        guard let host = printer.zebraHost, let dpi = printer.dpi else { throw Failed(description: "\(printer.name) doesn't take ZPL") }
        let bitmaps = try LabelRaster.bitmaps(pdf: file, dpi: dpi)
        var options = ZPL.Options(copies: copies)
        options.labelLength = ((try? Zebra.setup(host)) ?? nil)?.isContinuous ?? false
        return ZPLJob(data: ZPL.job(bitmaps, options: options), labels: bitmaps.count * max(1, copies))
    }

    /// Sends a ZPL job and waits while the printer works through it: it acknowledges nothing else.
    @discardableResult
    public static func send(_ job: ZPLJob, to printer: PrinterInfo) throws -> String {
        guard let host = printer.zebraHost else { throw Failed(description: "\(printer.name) doesn't take ZPL") }
        do {
            try Zebra.send(job.data, to: host)
            try Zebra.waitUntilPrinted(host, timeout: 15 + 3 * Double(job.labels))
            return "\(job.data.count) bytes of ZPL, printed on \(printer.displayName) at \(host)"
        } catch let e as Zebra.Failed {
            throw Failed(description: e.description)
        }
    }
}
