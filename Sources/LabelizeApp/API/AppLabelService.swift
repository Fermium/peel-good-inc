import AppKit
import ImageIO
import LabelKit
import UniformTypeIdentifiers

/// The real `LabelService`: composes with LabelKit, keeps a copy in the history folder,
/// sends it with `lp`, then does what a drop does after printing (last print, sound, tag/move).
/// API prints go straight to the printer: no popover, no countdown.
@MainActor
final class AppLabelService: LabelService {
    typealias Sender = @Sendable (_ file: URL, _ printer: String, _ size: LabelSize, _ copies: Int) throws -> String

    let store: Store
    /// Swappable so tests and `-apiDryRun` never reach a printer.
    var sender: Sender
    private var recent: [APIJob] = []
    nonisolated static let maxJobs = 50
    nonisolated static let maxCopies = 100

    init(store: Store, sender: Sender? = nil) {
        self.store = store
        self.sender = sender ?? { file, printer, size, copies in
            try LabelPrint.send(file: file, printer: printer, size: size, copies: copies)
        }
    }

    /// A sender that only logs. Used by `-apiDryRun`.
    static let dryRunSender: Sender = { file, printer, size, copies in
        Log.notice(.api, "dry run: would send \(file.lastPathComponent) to \(printer) at \(size), \(copies) copies")
        return "dry-run"
    }

    // MARK: LabelService

    func printers() -> [APIPrinter] {
        store.refresh()
        let current = store.printer?.name
        return store.eligiblePrinters.map { p in
            APIPrinter(name: p.name, displayName: p.displayName, model: p.makeAndModel, isDefault: p.name == current,
                       isLabelPrinter: p.isLabelPrinter, state: p.state.rawValue, size: store.size(for: p).description,
                       fit: store.fit(for: p).rawValue, ink: store.ink(for: p).rawValue)
        }
    }

    func sizes(printer name: String) throws -> [APISize] {
        store.refresh()
        let p = try findPrinter(name)
        let current = store.size(for: p)
        return SizeCatalog.entries(for: p).map { e in
            APISize(size: e.size.description, display: e.size.display, widthInches: e.size.width, heightInches: e.size.height,
                    source: e.source.rawValue, supported: e.isSupported, reason: e.unsupportedReason, current: e.size == current)
        }
    }

    func print(files: [URL], request: APIPrintRequest, source: String) async throws -> APIJob {
        guard !files.isEmpty else { throw APIError.badRequest("No file to print.", code: "no_file") }
        let (printer, options) = try resolve(request)
        let copies = try Self.copies(request.copies)
        return try await send(files, printer: printer, options: options, copies: copies, source: source)
    }

    func preview(files: [URL], request: APIPrintRequest) async throws -> APIPreview {
        guard !files.isEmpty else { throw APIError.badRequest("No file to preview.", code: "no_file") }
        let (printer, options) = try resolve(request)
        let labels = try await Self.compose(files, options)
        let images = try await Task.detached(priority: .userInitiated) {
            try labels.enumerated().map { i, label in
                guard let image = label.bitmap.cgImage(), let png = Self.pngData(image) else {
                    throw APIError.failed("Couldn't render label \(i + 1).", code: "render_failed")
                }
                return APILabelPreview(index: i, width: image.width, height: image.height, png: png,
                                       codes: Self.codes(label), warnings: label.warnings)
            }
        }.value
        let summary = Self.summary(labels)
        return APIPreview(printer: printer.name, size: options.size.description, labels: labels.count,
                          codesFound: summary.found, codesVerified: summary.verified, codesMissing: summary.missing,
                          warnings: summary.warnings, images: images)
    }

    func printClipboard(request: APIPrintRequest) async throws -> APIJob {
        let files = await Intake.files(from: .general, name: "Clipboard")
        guard !files.isEmpty else { throw APIError.unprocessable("Nothing printable on the clipboard.", code: "clipboard_empty") }
        return try await print(files: files, request: request, source: APIJob.Source.clipboard)
    }

    /// The saved label PDF is already label-sized, so it prints 1:1 (same as Reprint Last Label).
    func reprintLast(copies: Int?) async throws -> APIJob {
        store.refresh()
        guard let last = store.lastPrint else { throw APIError.notFound("Nothing printed yet.", code: "no_last_print") }
        guard let printer = store.printers.first(where: { $0.name == last.printer }) ?? store.printer else {
            throw APIError.notFound("Printer \(last.printer) not found.", code: "printer_not_found")
        }
        var options = store.options(for: printer)
        options.size = printer.resolve(last.size) ?? last.size
        options.crop = .none
        options.nudgeMM = .zero
        return try await send([last.file], printer: printer, options: options, copies: try Self.copies(copies), source: APIJob.Source.reprint)
    }

    func jobs() -> [APIJob] { recent }

    /// Lets the app add jobs that didn't come through the API (drops, menu), if wanted.
    func record(_ job: APIJob) {
        recent.insert(job, at: 0)
        if recent.count > Self.maxJobs { recent.removeLast(recent.count - Self.maxJobs) }
    }

    // MARK: Printing

    private func send(_ files: [URL], printer: PrinterInfo, options: LabelOptions, copies: Int, source: String) async throws -> APIJob {
        Log.info(.api, "\(source) job: \(files.map(\.lastPathComponent).joined(separator: ", ")) on \(printer.name) at \(options.size), \(copies) copies")
        let labels = try await Self.compose(files, options)
        let summary = Self.summary(labels)
        var job = APIJob(id: UUID().uuidString, created: Date(), source: source, status: .failed,
                         files: files.map(\.lastPathComponent), printer: printer.name, size: options.size.description,
                         copies: copies, labels: labels.count, codesFound: summary.found, codesVerified: summary.verified,
                         codesMissing: summary.missing, warnings: summary.warnings)
        guard !labels.isEmpty else {
            job.error = "Nothing to print."
            record(job)
            throw APIError.unprocessable("Nothing to print.", code: "empty")
        }

        let name = files.first?.deletingPathExtension().lastPathComponent ?? "label"
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = Store.historyFolder.appendingPathComponent("\(stamp) \(name).label.pdf")
        let size = options.size, sender = sender
        do {
            let id = try await Task.detached(priority: .userInitiated) {
                if printer.isLabelPrinter {
                    try LabelWriter.writePDF(labels, size: size, to: url)
                } else {
                    try LabelWriter.writeVectorPDF(labels, size: size, to: url)
                }
                return try sender(url, printer.name, size, copies)
            }.value
            Log.notice(.print, "API sent \(labels.count) label(s) × \(copies) to \(printer.name) (media \(size.cupsMedia)): \(id)")
            job.status = .printed
            job.savedPDF = url.path
            job.printerJobID = id
            record(job)
            store.lastPrint = Store.LastPrint(file: url, printer: printer.name, size: size)
            Sounds.play(Sounds.sent, if: store.playSounds)
            // Only files already on this Mac (MCP, with permission) get tagged or moved; uploads are temporary copies.
            if source == APIJob.Source.localFile { AfterPrint.apply(to: files, store: store) }
            History.prune(keepingDays: store.historyDays)
            return job
        } catch {
            Log.error(.print, "API print failed on \(printer.name): \(error)")
            job.error = "\(error)"
            record(job)
            throw APIError.failed("\(error)")
        }
    }

    /// Every page of every file becomes a label, in order.
    private static func compose(_ files: [URL], _ options: LabelOptions) async throws -> [ComposedLabel] {
        do {
            return try await Task.detached(priority: .userInitiated) { try PrintJob.composeAll(files, options) }.value
        } catch {
            throw APIError.unprocessable("\(error)", code: "unreadable")
        }
    }

    // MARK: Resolving options

    func findPrinter(_ name: String?) throws -> PrinterInfo {
        guard let name, !name.isEmpty else {
            guard let p = store.printer else { throw APIError.notFound("No label printer found.", code: "no_printer") }
            return p
        }
        let all = store.eligiblePrinters + store.printers
        if let p = all.first(where: { $0.name == name }) { return p }
        if let p = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) {
            return p
        }
        throw APIError.notFound("Printer \(name) not found.", code: "printer_not_found")
    }

    func resolve(_ r: APIPrintRequest) throws -> (PrinterInfo, LabelOptions) {
        store.refresh()
        let printer = try findPrinter(r.printer)
        var o = store.options(for: printer)
        if let text = r.size {
            guard let wanted = LabelSize(parsing: text) else {
                throw APIError.badRequest("Size \(text) isn't valid. Use a size like 4x6 or 100x150mm.", code: "invalid_size")
            }
            guard let size = printer.resolve(wanted) else {
                let reason = SizeCatalog.entries(for: printer).first { $0.size == wanted }?.unsupportedReason
                throw APIError.unprocessable("\(printer.displayName) can't print \(wanted) labels\(reason.map { ": \($0)" } ?? "").", code: "unsupported_size")
            }
            o.size = size
        }
        if let text = r.fit {
            guard let fit = FitMode(rawValue: text.lowercased()) else { throw APIError.badRequest("Fit must be fit or fill.", code: "invalid_fit") }
            o.fit = fit
        }
        if let text = r.ink {
            guard let ink = InkMode(rawValue: text.lowercased()) else { throw APIError.badRequest("Ink must be auto, crisp or photo.", code: "invalid_ink") }
            o.ink = ink
        }
        return (printer, o)
    }

    static func copies(_ n: Int?) throws -> Int {
        let n = n ?? 1
        guard (1...maxCopies).contains(n) else { throw APIError.badRequest("Copies must be 1 to \(maxCopies).", code: "invalid_copies") }
        return n
    }

    // MARK: Reports

    nonisolated static func codes(_ label: ComposedLabel) -> [APICode] {
        label.expectedCodes.map { code in
            let report = label.codeReports.first { $0.payload == code.payload }
            return APICode(symbology: code.symbology, payload: code.payload,
                           scannable: label.scannableCodes.contains { $0.payload == code.payload },
                           severity: report?.severity.description, message: report?.message)
        }
    }

    nonisolated static func summary(_ labels: [ComposedLabel]) -> (found: Int, verified: Int, missing: [String], warnings: [String]) {
        let found = labels.reduce(0) { $0 + $1.expectedCodes.count }
        let missing = labels.flatMap(\.missingCodes).map(\.payload)
        let warnings = Array(Set(labels.flatMap(\.warnings))).sorted()
        return (found, found - missing.count, missing, warnings)
    }

    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
