import AppKit
import LabelKit
import PeelGoodCore
import PeelGoodShared
import Synchronization

/// "Peel Good Inc." as a printer every app can print to: an IPP Everywhere printer on 127.0.0.1 that
/// takes PDFs, and the CUPS queue pointing at it (`lpadmin -m everywhere`, so CUPS builds the driver
/// from our attributes and passes the PDF through). Jobs go through the rules like any other file.
final class VirtualPrinter: Sendable {
    static let host = "127.0.0.1"
    static let port: UInt16 = 47312
    static var uri: String { "ipp://\(host):\(port)/ipp/print" }
    static let name = AppIdentity.appName

    /// A fresh folder for each received document (Intake's scratch folders by default).
    let folder: @Sendable () -> URL
    let received: @Sendable (_ file: URL, _ title: String, _ media: String?) -> Void
    private let state = Mutex(State())

    private struct State {
        var nextID = 1
        var jobs: [Int: Job] = [:]
    }

    struct Job: Sendable {
        var id: Int
        var name: String
        var user: String
        var completed = Date()
    }

    init(folder: @escaping @Sendable () -> URL = { Intake.scratchFolder() },
         received: @escaping @Sendable (_ file: URL, _ title: String, _ media: String?) -> Void) {
        self.folder = folder
        self.received = received
    }

    // MARK: Operations

    enum Operation: UInt16, CaseIterable {
        case printJob = 0x0002, validateJob = 0x0004, cancelJob = 0x0008, getJobAttributes = 0x0009
        case getJobs = 0x000A, getPrinterAttributes = 0x000B
    }

    enum Status: UInt16 {
        case ok = 0x0000, badRequest = 0x0400, notFound = 0x0406, documentFormatNotSupported = 0x040A
        case operationNotSupported = 0x0501, internalError = 0x0500
    }

    func handle(_ request: IPPMessage) -> IPPMessage {
        var groups = [IPPGroup(tag: IPPTag.operation, attributes: [
            IPPAttribute("attributes-charset", .charset("utf-8")),
            IPPAttribute("attributes-natural-language", .language("en")),
        ])]
        let status: Status
        switch Operation(rawValue: request.code) {
        case .getPrinterAttributes:
            groups.append(IPPGroup(tag: IPPTag.printer, attributes: Self.printerAttributes(queued: 0)))
            status = .ok
        case .validateJob:
            status = Self.takes(format: request.string("document-format")) ? .ok : .documentFormatNotSupported
        case .printJob:
            let result = printJob(request, groups)
            status = result.0
            groups = result.1
        case .getJobAttributes:
            if let id = request.int("job-id"), let job = state.withLock({ $0.jobs[id] }) {
                groups.append(IPPGroup(tag: IPPTag.job, attributes: Self.jobAttributes(job)))
                status = .ok
            } else {
                status = .notFound
            }
        case .getJobs:
            let jobs = request.string("which-jobs") == "completed" ? state.withLock { Array($0.jobs.values) } : []
            groups += jobs.sorted { $0.id < $1.id }.map { IPPGroup(tag: IPPTag.job, attributes: Self.jobAttributes($0)) }
            status = .ok
        case .cancelJob:
            status = .ok // every job is already done
        case nil:
            status = .operationNotSupported
        }
        return IPPMessage(version: request.version, code: status.rawValue, requestID: request.requestID, groups: groups)
    }

    private func printJob(_ request: IPPMessage, _ groups: [IPPGroup]) -> (Status, [IPPGroup]) {
        guard Intake.format(of: request.data)?.type == .pdf else { return (.documentFormatNotSupported, groups) }
        let title = Self.title(fromJobName: request.string("job-name") ?? "")
        let job = state.withLock { s -> Job in
            let job = Job(id: s.nextID, name: title, user: request.string("requesting-user-name") ?? "")
            s.nextID += 1
            s.jobs[job.id] = job
            if s.jobs.count > 50, let oldest = s.jobs.keys.min() { s.jobs[oldest] = nil }
            return job
        }
        do {
            let folder = folder()
            var file = folder.appendingPathComponent(Self.fileName(title))
            // A name the file system still refuses: keep the document, under a plain name.
            if (try? request.data.write(to: file)) == nil {
                file = folder.appendingPathComponent(Self.fileName("Printed document"))
                try request.data.write(to: file)
            }
            received(file, title, request.string("media") ?? Self.mediaName(in: request))
        } catch {
            return (.internalError, groups)
        }
        return (.ok, groups + [IPPGroup(tag: IPPTag.job, attributes: Self.jobAttributes(job))])
    }

    /// Only PDF: macOS turns whatever is printed into PDF before it reaches a printer like this one.
    static func takes(format: String?) -> Bool {
        format == nil || format == "application/octet-stream" || Intake.format(mimeType: format)?.type == .pdf
    }

    /// The document's title, "Printed document" when there's none. The CUPS `ipp` backend sends
    /// "775 - Invoice", with its own job number first.
    static func title(fromJobName name: String) -> String {
        var title = name
        if let r = title.range(of: #"^\d+ - "#, options: .regularExpression) { title = String(title[r.upperBound...]) }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Printed document" : title
    }

    /// "Invoice 123.pdf" from a title, safe as a file name: no separators or control characters, and
    /// at most 200 bytes of UTF-8 (file names are limited to 255 bytes, not characters).
    static func fileName(_ title: String) -> String {
        var name = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.hasPrefix(".") { name = "_" + name }
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        var short = ""
        for c in name where short.utf8.count + String(c).utf8.count <= 200 { short.append(c) }
        return (short.isEmpty ? "Printed document" : short) + ".pdf"
    }

    /// The media-size-name inside media-col, when the job sent a collection instead of `media`.
    private static func mediaName(in request: IPPMessage) -> String? {
        guard case .collection(let members)? = request.attribute("media-col")?.values.first else { return nil }
        return members.first { $0.name == "media-size-name" }?.values.first?.string
    }

    // MARK: Attributes

    static func jobAttributes(_ job: Job) -> [IPPAttribute] {
        [
            IPPAttribute("job-id", .integer(Int32(job.id))),
            IPPAttribute("job-uri", .uri("\(uri)/\(job.id)")),
            IPPAttribute("job-name", .name(job.name)),
            IPPAttribute("job-originating-user-name", .name(job.user.isEmpty ? "anonymous" : job.user)),
            IPPAttribute("job-state", .enumeration(9)), // completed: the app has the document
            IPPAttribute("job-state-reasons", .keyword("job-completed-successfully")),
            IPPAttribute("job-impressions-completed", .integer(1)),
            IPPAttribute("time-at-completed", .integer(Int32(job.completed.timeIntervalSince1970.truncatingRemainder(dividingBy: 1e9)))),
        ]
    }

    /// The label sizes the Print dialog offers: the standard rolls, as PWG media names.
    static var sizes: [LabelSize] { SizeCatalog.standard }

    /// "oe_4x6-label_4x6in", or "om_100x150mm_100x150mm" for metric rolls. `LabelSize(pwgMedia:)` reads them back.
    static func mediaName(_ size: LabelSize) -> String {
        let d = size.description
        return size.isMetric ? "om_\(d)_\(d)" : "oe_\(d)-label_\(d)in"
    }

    private static func mediaCol(_ size: LabelSize) -> IPPValue { .collection(mediaColMembers(size)) }

    private static func mediaColMembers(_ size: LabelSize) -> [IPPAttribute] {
        func hundredthsMM(_ inches: Double) -> IPPValue { .integer(Int32((inches * 2540).rounded())) }
        return [
            IPPAttribute("media-size", .collection([
                IPPAttribute("x-dimension", hundredthsMM(size.width)),
                IPPAttribute("y-dimension", hundredthsMM(size.height)),
            ])),
            IPPAttribute("media-size-name", .keyword(mediaName(size))),
            IPPAttribute("media-top-margin", .integer(0)),
            IPPAttribute("media-bottom-margin", .integer(0)),
            IPPAttribute("media-left-margin", .integer(0)),
            IPPAttribute("media-right-margin", .integer(0)),
            IPPAttribute("media-source", .keyword("auto")),
            IPPAttribute("media-type", .keyword("labels")),
        ]
    }

    static func printerAttributes(queued: Int) -> [IPPAttribute] {
        let sizes = sizes, fourBySix = sizes.first { $0 == .fourBySix } ?? sizes[0]
        return [
            IPPAttribute("printer-uri-supported", .uri(uri)),
            IPPAttribute("uri-security-supported", .keyword("none")),
            IPPAttribute("uri-authentication-supported", .keyword("none")),
            IPPAttribute("printer-name", .name(name)),
            IPPAttribute("printer-info", .text(name)),
            IPPAttribute("printer-location", .text("This Mac")),
            IPPAttribute("printer-make-and-model", .text("\(name) Label Printer")),
            IPPAttribute("printer-device-id", .text("MFG:\(name);MDL:Label Printer;CMD:PDF;CLS:PRINTER;")),
            IPPAttribute("printer-uuid", .uri("urn:uuid:7f0c4a52-5e1d-4c55-9f3a-5045454c474f")),
            IPPAttribute("printer-state", .enumeration(3)),
            IPPAttribute("printer-state-reasons", .keyword("none")),
            IPPAttribute("printer-is-accepting-jobs", .boolean(true)),
            IPPAttribute("printer-up-time", .integer(Int32(ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 1e9)))),
            IPPAttribute("queued-job-count", .integer(Int32(queued))),
            IPPAttribute("ipp-versions-supported", [.keyword("1.1"), .keyword("2.0")]),
            IPPAttribute("ipp-features-supported", .keyword("ipp-everywhere")),
            IPPAttribute("operations-supported", Operation.allCases.map { .enumeration(Int32($0.rawValue)) }),
            IPPAttribute("charset-configured", .charset("utf-8")),
            IPPAttribute("charset-supported", .charset("utf-8")),
            IPPAttribute("natural-language-configured", .language("en")),
            IPPAttribute("generated-natural-language-supported", .language("en")),
            IPPAttribute("document-format-default", .mimeType("application/pdf")),
            IPPAttribute("document-format-supported", .mimeType("application/pdf")),
            IPPAttribute("document-format-preferred", .mimeType("application/pdf")),
            IPPAttribute("compression-supported", .keyword("none")),
            IPPAttribute("pdl-override-supported", .keyword("attempted")),
            IPPAttribute("multiple-document-jobs-supported", .boolean(false)),
            IPPAttribute("color-supported", .boolean(false)),
            IPPAttribute("print-color-mode-supported", .keyword("monochrome")),
            IPPAttribute("print-color-mode-default", .keyword("monochrome")),
            // One copy: copies come from the rules, so the Print dialog shouldn't offer a choice we'd ignore.
            IPPAttribute("copies-supported", .range(1, 1)),
            IPPAttribute("copies-default", .integer(1)),
            IPPAttribute("sides-supported", .keyword("one-sided")),
            IPPAttribute("sides-default", .keyword("one-sided")),
            IPPAttribute("print-quality-supported", [.enumeration(4)]),
            IPPAttribute("print-quality-default", .enumeration(4)),
            IPPAttribute("printer-resolution-supported", .resolution(203, 203)),
            IPPAttribute("printer-resolution-default", .resolution(203, 203)),
            IPPAttribute("media-supported", sizes.map { .keyword(mediaName($0)) }),
            IPPAttribute("media-ready", .keyword(mediaName(fourBySix))),
            IPPAttribute("media-default", .keyword(mediaName(fourBySix))),
            IPPAttribute("media-col-database", sizes.map(mediaCol)),
            IPPAttribute("media-col-ready", mediaCol(fourBySix)),
            IPPAttribute("media-col-default", mediaCol(fourBySix)),
            IPPAttribute("media-col-supported", mediaColMembers(fourBySix).map { .keyword($0.name) }),
            IPPAttribute("media-top-margin-supported", .integer(0)),
            IPPAttribute("media-bottom-margin-supported", .integer(0)),
            IPPAttribute("media-left-margin-supported", .integer(0)),
            IPPAttribute("media-right-margin-supported", .integer(0)),
            IPPAttribute("media-type-supported", .keyword("labels")),
            IPPAttribute("media-source-supported", .keyword("auto")),
            IPPAttribute("job-creation-attributes-supported", ["media", "media-col", "print-color-mode"].map { .keyword($0) }),
            IPPAttribute("which-jobs-supported", [.keyword("completed"), .keyword("not-completed")]),
            IPPAttribute("job-ids-supported", .boolean(true)),
        ]
    }
}

// MARK: The queue

/// The CUPS queue that makes the printer show up in every Print dialog.
enum PrintQueue {
    static let name = Printers.virtualQueue

    /// The queue exists and points at our printer.
    static func isRegistered() -> Bool {
        (try? Command.run("/usr/bin/lpstat", ["-v", name]))?.contains(VirtualPrinter.uri) == true
    }

    /// Adds (or refreshes) the queue. The printer must be listening: CUPS asks it what it can do.
    static func register() throws {
        try Command.run("/usr/sbin/lpadmin", ["-p", name, "-D", VirtualPrinter.name, "-L", "This Mac", "-v", VirtualPrinter.uri,
                                              "-m", "everywhere", "-o", "printer-is-shared=false", "-o", "printer-error-policy=retry-job", "-E"])
    }

    static func unregister() throws {
        guard (try? Command.run("/usr/bin/lpstat", ["-v", name])) != nil else { return }
        try PrinterRemoval.removeFromMac(name)
    }
}

// MARK: The app's side

/// Starts and stops the printer and its queue with the setting, and hands received jobs to the app.
/// Starting and stopping run one after another, so flipping the switch quickly can't interleave them.
@MainActor
final class VirtualPrinterController {
    static let shared = VirtualPrinterController()

    /// Set by the app: prints a received document through the rules.
    var onDocument: (URL, _ title: String) -> Void = { _, _ in }
    private var server: IPPServer?
    private var last: Task<Void, Never>?

    /// Listens and makes sure the queue exists. `done` gets the error, if any; after an error nothing is left running.
    func start(done: @escaping @MainActor (Error?) -> Void = { _ in }) {
        enqueue {
            do {
                try await self.listen()
                if !(await Task.detached { PrintQueue.isRegistered() }.value) {
                    try await Task.detached { try PrintQueue.register() }.value
                    Log.notice(.app, "printer: added the “\(VirtualPrinter.name)” queue")
                }
                done(nil)
            } catch {
                Log.error(.app, "printer: couldn't start: \(error.localizedDescription)")
                self.server?.stop()
                self.server = nil
                done(error)
            }
        }
    }

    /// Removes the queue, then stops listening. If the queue can't be removed, the printer keeps running
    /// so the queue still works.
    func stop(done: @escaping @MainActor (Error?) -> Void = { _ in }) {
        enqueue {
            do {
                try await Task.detached { try PrintQueue.unregister() }.value
                Log.notice(.app, "printer: removed the “\(VirtualPrinter.name)” queue")
                self.server?.stop()
                self.server = nil
                done(nil)
            } catch {
                Log.error(.app, "printer: couldn't remove the queue: \(error.localizedDescription)")
                done(error)
            }
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = last
        last = Task {
            await previous?.value
            await operation()
        }
    }

    /// Starts the IPP server unless it's already running.
    private func listen() async throws {
        guard server == nil else { return }
        let printer = VirtualPrinter { file, title, media in
            Task { @MainActor in
                Log.notice(.intake, "print dialog: “\(title)”\(media.map { " on \($0)" } ?? "") → \(file.lastPathComponent)")
                VirtualPrinterController.shared.onDocument(file, title)
            }
        }
        let server = IPPServer(host: VirtualPrinter.host, port: VirtualPrinter.port) { printer.handle($0) }
        self.server = server
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            server.start { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        Log.info(.app, "printer: listening on \(VirtualPrinter.uri)")
    }
}
