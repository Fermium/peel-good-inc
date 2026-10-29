import AppKit
import ImageIO
import LabelKit
import UniformTypeIdentifiers

/// The real `LabelService`. Prints go through the same flow as a drop: the rules (trigger "From another app",
/// with the request's printer, size, fit, ink and copies on top), then the popover with its countdown, or the
/// preview when "Ask first" is set or the rule says preview or ask. Each call waits for the outcome
/// (printed, cancelled, failed) up to `waitLimit`, then returns status waiting; `jobs()` shows how it ended.
@MainActor
final class AppLabelService: LabelService {
    typealias Sender = @Sendable (_ file: URL, _ printer: String, _ size: LabelSize, _ copies: Int) throws -> String

    let store: Store
    /// Swappable so tests and `-apiDryRun` never reach a printer.
    var sender: Sender
    /// Shows jobs (the app's popover). Without one, jobs run headless, which only tests do.
    weak var presenter: JobPresenter?
    var rules: RuleEngine = .shared
    var waitLimit: Duration = .seconds(120)
    private var recent: [APIJob] = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
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
        return try await run(files, plan: try await plan(files, request), source: source)
    }

    func preview(files: [URL], request: APIPrintRequest) async throws -> APIPreview {
        guard !files.isEmpty else { throw APIError.badRequest("No file to preview.", code: "no_file") }
        let plan = try await plan(files, request)
        let printer = plan.printer, options = plan.options
        let labels = try await Self.compose(files, options)
        let images = try await Task.detached(priority: .userInitiated) {
            try labels.enumerated().map { i, label in
                guard let image = label.bitmap.cgImage(), let png = Self.pngData(image) else {
                    throw APIError.failed("Couldn't render label \(i + 1).", code: "render_failed")
                }
                return APILabelPreview(index: i, width: image.width, height: image.height, png: png,
                                       ink: label.ink.rawValue, scalePercent: Self.percent(label), rotated: label.rotated,
                                       codes: Self.codes(label), warnings: label.warnings)
            }
        }.value
        let summary = Self.summary(labels)
        return APIPreview(printer: printer.name, size: options.size.description, rule: plan.rule, copies: plan.copies,
                          action: plan.review ? "review" : "countdown", labels: labels.count,
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
        let plan = Plan(printer: printer, options: options, copies: try Self.copies(copies), review: store.alwaysReview, decision: nil)
        return try await run([last.file], plan: plan, source: APIJob.Source.reprint)
    }

    func jobs() -> [APIJob] { recent }

    /// Lets the app add jobs that didn't come through the API (drops, menu), if wanted.
    func record(_ job: APIJob) {
        recent.insert(job, at: 0)
        if recent.count > Self.maxJobs { recent.removeLast(recent.count - Self.maxJobs) }
    }

    // MARK: Printing

    struct Plan {
        var printer: PrinterInfo
        var options: LabelOptions
        var copies: Int
        /// Wait for Print in the preview instead of counting down.
        var review: Bool
        var decision: RuleDecision?
        /// The matching rule's name, "Everything else", or nil for reprints.
        var rule: String? { decision.map { $0.isFallback ? "Everything else" : $0.rule.displayName } }
    }

    /// The rule for the first file, with the request's options on top. A rule without an action
    /// counts down like a drop; "Ask first", or a rule that previews or asks, waits for Print.
    func plan(_ files: [URL], _ r: APIPrintRequest) async throws -> Plan {
        store.refresh()
        let forced = try r.printer.map { try findPrinter($0) }
        guard let d = await JobFlow.decide(files, trigger: .api, store: store, engine: rules, forcedPrinter: forced) else {
            throw APIError.notFound("No label printer found.", code: "no_printer")
        }
        let options = try Self.override(d.options, with: r, on: d.printer)
        let copies = try r.copies.map { try Self.copies($0) } ?? d.copies
        let action = d.rule.outcome.action ?? .print
        return Plan(printer: d.printer, options: options, copies: copies, review: store.alwaysReview || action != .print, decision: d)
    }

    private func run(_ files: [URL], plan: Plan, source: String) async throws -> APIJob {
        let job = JobFlow.makeJob(files, printer: plan.printer, options: plan.options, review: plan.review,
                                  decision: plan.decision, copies: plan.copies, store: store)
        job.sender = sender
        let id = UUID().uuidString
        record(APIJob(id: id, created: Date(), source: source, status: .waiting, files: files.map(\.lastPathComponent),
                      printer: plan.printer.name, size: plan.options.size.description, copies: plan.copies, labels: 0,
                      codesFound: 0, codesVerified: 0, codesMissing: [], warnings: [], rule: plan.rule,
                      action: plan.review ? "review" : "countdown"))
        Log.info(.api, "\(source) job \(id): \(files.map(\.lastPathComponent).joined(separator: ", ")) on \(plan.printer.name) at \(plan.options.size), \(plan.copies) copies, rule \(plan.rule ?? "none"), \(plan.review ? "waiting for Print" : "countdown \(store.countdown)s")")
        job.onOutcome = { [weak self, weak job] outcome in
            guard let self, let job else { return }
            self.finished(id, job, outcome)
        }
        if let presenter { presenter.present(job) } else { job.start() }

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if job.outcome != nil { return done.resume() }
            waiters[id] = done
            let limit = waitLimit
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                self?.waiters.removeValue(forKey: id)?.resume()
            }
        }
        if job.outcome == nil && !job.labels.isEmpty { fill(id, from: job) }   // still waiting: report what's composed so far
        guard let result = recent.first(where: { $0.id == id }) else { throw APIError.failed("Job \(id) went missing.", code: "internal") }
        if result.status == .failed {
            if result.labels == 0 && job.labels.isEmpty { throw APIError.unprocessable(result.error ?? "Nothing to print.", code: "unreadable") }
            throw APIError.failed(result.error ?? "Printing failed.")
        }
        if result.status == .waiting { Log.info(.api, "job \(id) still waiting after \(waitLimit); jobs shows how it ends") }
        return result
    }

    /// Labels, codes and per-label details from the job, once it has composed.
    private func fill(_ id: String, from job: PrintJob) {
        guard let i = recent.firstIndex(where: { $0.id == id }) else { return }
        var r = recent[i]
        let summary = Self.summary(job.labels)
        r.labels = job.labels.count
        r.codesFound = summary.found
        r.codesVerified = summary.verified
        r.codesMissing = summary.missing
        r.warnings = job.notes + summary.warnings
        r.labelDetails = job.labels.enumerated().map { Self.detail($1, index: $0) }
        r.printer = job.printer.name
        r.size = job.options.size.description
        recent[i] = r
    }

    private func finished(_ id: String, _ job: PrintJob, _ outcome: PrintJob.Outcome) {
        fill(id, from: job)
        guard let i = recent.firstIndex(where: { $0.id == id }) else { return }
        var r = recent[i]
        switch outcome {
        case .printed(let file, let printerJobID):
            r.status = .printed
            r.savedPDF = file.path
            r.printerJobID = printerJobID
        case .cancelled:
            r.status = .cancelled
        case .failed(let message):
            r.status = .failed
            r.error = message
        }
        recent[i] = r
        Log.info(.api, "job \(id) \(r.status.rawValue)")
        waiters.removeValue(forKey: id)?.resume()
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

    /// The request's size, fit and ink on top of the rule's (or the printer's) options.
    static func override(_ base: LabelOptions, with r: APIPrintRequest, on printer: PrinterInfo) throws -> LabelOptions {
        var o = base
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
            guard let ink = InkMode(rawValue: text.lowercased()) else { throw APIError.badRequest("Ink must be auto, crisp, photo or halftone.", code: "invalid_ink") }
            o.ink = ink
        }
        return o
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

    /// How one label came out: the ink actually used, its scale, rotation and codes.
    nonisolated static func detail(_ label: ComposedLabel, index: Int) -> APILabelInfo {
        APILabelInfo(index: index, ink: label.ink.rawValue, scalePercent: percent(label), rotated: label.rotated,
                     codes: codes(label), warnings: label.warnings)
    }

    nonisolated static func percent(_ label: ComposedLabel) -> Double { (Double(label.scale) * 1000).rounded() / 10 }

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
