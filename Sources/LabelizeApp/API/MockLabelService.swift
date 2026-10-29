import CoreGraphics
import Foundation
import LabelizeCore

/// A `LabelService` with two made-up printers that never prints. For tests and `-apiMock`.
@MainActor
final class MockLabelService: LabelService {
    private(set) var printed: [(files: [URL], request: APIPrintRequest)] = []
    private var recent: [APIJob] = []

    let mockPrinters: [APIPrinter] = [
        APIPrinter(name: "Mock_Label_Printer", displayName: "Mock Label Printer", model: "Mock 4in Thermal", isDefault: true,
                   isLabelPrinter: true, state: "idle", size: "4x6", fit: "fit", ink: "auto"),
        APIPrinter(name: "Mock_Office_Printer", displayName: "Mock Office Printer", model: "Mock Laser", isDefault: false,
                   isLabelPrinter: false, state: "idle", size: "4x6", fit: "fit", ink: "auto"),
    ]

    func printers() -> [APIPrinter] { mockPrinters }

    func sizes(printer: String) throws -> [APISize] {
        guard let p = find(printer) else { throw APIError.notFound("Printer \(printer) not found.", code: "printer_not_found") }
        return [(4, 6), (4, 4), (2, 1)].map { w, h in
            let s = "\(w)x\(h)"
            return APISize(size: s, display: "\(w) × \(h) in", widthInches: Double(w), heightInches: Double(h),
                           source: "printer", supported: true, reason: nil, current: s == p.size)
        }
    }

    func print(files: [URL], request: APIPrintRequest, source: String) async throws -> APIJob {
        guard !files.isEmpty else { throw APIError.badRequest("No file to print.", code: "no_file") }
        let p = try printer(for: request)
        let copies = try AppConfigurator.option { try OptionOverrides.copies(request.copies) }
        printed.append((files, request))
        let job = APIJob(id: UUID().uuidString, created: Date(), source: source, status: .printed,
                         files: files.map(\.lastPathComponent), printer: p.name, size: request.size ?? p.size, copies: copies,
                         labels: files.count, codesFound: 1, codesVerified: 1, codesMissing: [], warnings: [],
                         savedPDF: nil, printerJobID: "mock-\(recent.count + 1)", error: nil)
        recent.insert(job, at: 0)
        Log.info(.api, "mock: printed \(files.map(\.lastPathComponent).joined(separator: ", ")) on \(p.name)")
        return job
    }

    func preview(files: [URL], request: APIPrintRequest) async throws -> APIPreview {
        guard !files.isEmpty else { throw APIError.badRequest("No file to preview.", code: "no_file") }
        let p = try printer(for: request)
        let images = files.indices.map { i in
            APILabelPreview(APILabelInfo(index: i, ink: "crisp", scalePercent: 100, rotated: false, codes: [
                APICode(symbology: "QR", payload: "MOCK-\(i + 1)", scannable: true, severity: "ok", message: nil),
            ], warnings: []), width: 200, height: 300, png: Self.placeholderPNG())
        }
        return APIPreview(printer: p.name, size: request.size ?? p.size, rule: "Everything else", copies: 1, action: "countdown", labels: images.count, codesFound: images.count,
                          codesVerified: images.count, codesMissing: [], warnings: [], images: images)
    }

    func printClipboard(request: APIPrintRequest) async throws -> APIJob {
        try await print(files: [URL(fileURLWithPath: "/tmp/Clipboard.png")], request: request, source: APIJob.Source.clipboard)
    }

    func reprintLast(copies: Int?) async throws -> APIJob {
        guard let last = recent.first else { throw APIError.notFound("Nothing printed yet.", code: "no_last_print") }
        return try await print(files: [URL(fileURLWithPath: "/tmp/\(last.files.first ?? "label").label.pdf")],
                               request: APIPrintRequest(printer: last.printer, size: last.size, copies: copies), source: APIJob.Source.reprint)
    }

    func jobs() -> [APIJob] { recent }

    private func find(_ name: String) -> APIPrinter? {
        mockPrinters.first { $0.name == name || $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func printer(for r: APIPrintRequest) throws -> APIPrinter {
        guard let name = r.printer else { return mockPrinters[0] }
        guard let p = find(name) else { throw APIError.notFound("Printer \(name) not found.", code: "printer_not_found") }
        return p
    }

    /// A white 200×300 image with a black border.
    static func placeholderPNG() -> Data {
        let ctx = CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(6)
        ctx.stroke(CGRect(x: 10, y: 10, width: 180, height: 280))
        return ctx.makeImage().flatMap(AppLabelService.pngData) ?? Data()
    }
}
