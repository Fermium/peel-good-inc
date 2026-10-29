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

public enum LabelPrint {
    public struct Failed: Error, CustomStringConvertible {
        public let description: String
    }

    /// `lp` arguments that print the file 1:1 on the given media, with no dialog.
    public static func lpArguments(file: URL, printer: String, size: LabelSize, copies: Int) -> [String] {
        ["-d", printer, "-o", "media=\(size.cupsMedia)", "-o", "print-scaling=none", "-n", String(copies), file.path]
    }

    /// Sends the job and returns lp's output (the job id).
    @discardableResult
    public static func send(file: URL, printer: String, size: LabelSize, copies: Int = 1) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
        process.arguments = lpArguments(file: file, printer: printer, size: size, copies: copies)
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
}
