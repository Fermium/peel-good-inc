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

/// Runs a command-line tool (lp, lpadmin, lpstat) and returns what it printed.
public enum Command {
    public struct Failed: Error, CustomStringConvertible, LocalizedError {
        public let tool: String
        /// stdout and stderr, trimmed.
        public let output: String
        public var description: String { output.isEmpty ? "\(tool) failed" : output }
        public var errorDescription: String? { description }
    }

    @discardableResult
    public static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe would otherwise block the tool forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw Failed(tool: (tool as NSString).lastPathComponent, output: output) }
        return output
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
    /// once it has printed. `tuning` (darkness and speed) only reaches a Zebra; other printers print
    /// as their driver is set.
    @discardableResult
    public static func send(file: URL, printer: PrinterInfo, size: LabelSize, copies: Int = 1, tuning: ZPL.Tuning = .init()) throws -> String {
        if printer.speaksZPL { return try send(zplJob(file: file, printer: printer, copies: copies, tuning: tuning), to: printer) }
        do {
            return try Command.run("/usr/bin/lp", lpArguments(file: file, printer: printer.name, size: size, copies: copies))
        } catch let e as Command.Failed {
            throw Failed(description: "lp failed: \(e.output)")
        }
    }

    /// A label PDF as the ZPL a Zebra gets: rendered at the resolution the labels were composed at,
    /// one graphic per label, ^LL only when the printer reports continuous media.
    public struct ZPLJob: Sendable {
        public var data: Data
        /// Labels printed in all, copies included.
        public var labels: Int
        /// Sent once the labels have printed, to put back the darkness and speed the job changed.
        public var restore: Data?

        public init(data: Data, labels: Int, restore: Data? = nil) {
            self.data = data
            self.labels = labels
            self.restore = restore
        }
    }

    public static func zplJob(file: URL, printer: PrinterInfo, copies: Int, tuning: ZPL.Tuning = .init()) throws -> ZPLJob {
        guard let first = printer.zebraLink, let dpi = printer.dpi else { throw Failed(description: "\(printer.name) doesn't take ZPL") }
        let bitmaps = try LabelRaster.bitmaps(pdf: file, dpi: dpi)
        var options = ZPL.Options(copies: copies)
        options.tuning = tuning
        // On the connection the job goes to, waiting for its turn: this decides ^LL, and a speed
        // change needs the speeds to put back afterwards (without them, no speed is sent).
        let link = (try? Zebra.route(printer.zebraLinks)) ?? first
        let read = try? Zebra.holding(link) { held -> (Zebra.Setup?, [String: String]) in
            let setup = try Zebra.setup(held)
            let diagnostic = tuning.speed != nil && setup != nil ? (try? Zebra.headDiagnostic(held)) ?? [:] : [:]
            return (setup, diagnostic)
        }
        options.labelLength = read?.0?.isContinuous ?? false
        if let setup = read?.0 {
            let config = Zebra.Config(setup, diagnostic: read?.1 ?? [:])
            if let print = config.speed, let slew = config.slew, let backfeed = config.backfeed {
                options.printerSpeeds = ZPL.Speeds(print: print, slew: slew, backfeed: backfeed)
            }
        }
        return ZPLJob(data: ZPL.job(bitmaps, options: options), labels: bitmaps.count * max(1, copies), restore: ZPL.restore(options))
    }

    /// Sends a ZPL job and waits while the printer works through it: it acknowledges nothing else.
    @discardableResult
    public static func send(_ job: ZPLJob, to printer: PrinterInfo) throws -> String {
        guard printer.speaksZPL else { throw Failed(description: "\(printer.name) doesn't take ZPL") }
        do {
            let link = try Zebra.route(printer.zebraLinks)
            try Zebra.holding(link) { held in
                // Once the labels are sent, darkness and speed go back whatever happens to them (queued
                // behind them if the printer stopped), so the next app's labels don't print with Peel Good's.
                var sent = false
                defer { if sent, let restore = job.restore { try? held.write(restore, timeout: 10) } }
                try Zebra.send(job.data, to: held)
                sent = true
                try Zebra.waitUntilPrinted(held, timeout: 15 + 3 * Double(job.labels))
            }
            return "\(job.data.count) bytes of ZPL, printed on \(printer.displayName) (\(link.label))"
        } catch let e as Zebra.Failed {
            throw Failed(description: e.description)
        }
    }
}
