import AppKit
import ImageIO
import LabelKit
import LabelizeCore
import UniformTypeIdentifiers

/// The real `LabelService`. Prints go through the same flow as a drop (`JobFlow.plan`): the rules (trigger
/// "From another app", or "From the clipboard" for the clipboard, with the request's printer, size, fit, ink and
/// copies on top), then the popover with its countdown, or the preview when Before printing is "Show preview" or
/// the rule's action says preview or ask. Each call waits for the outcome
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
        try await print(files: files, request: request, source: source, trigger: .api)
    }

    func print(files: [URL], request: APIPrintRequest, source: String, trigger: RuleTrigger) async throws -> APIJob {
        guard !files.isEmpty else { throw APIError.badRequest("No file to print.", code: "no_file") }
        return try await run(files, plan: try await plan(files, request, trigger: trigger), source: source)
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
                return APILabelPreview(Self.detail(label, index: i), width: image.width, height: image.height, png: png)
            }
        }.value
        let counts = labels.codeCounts
        return APIPreview(printer: printer.name, size: options.size.description, rule: plan.rule, copies: plan.copies,
                          action: plan.review ? "review" : "countdown", labels: labels.count,
                          codesFound: counts.expected, codesVerified: counts.verified, codesMissing: counts.missing,
                          warnings: (plan.decision?.notes ?? []) + labels.reportableWarnings, images: images)
    }

    func printClipboard(request: APIPrintRequest) async throws -> APIJob {
        let files = await Intake.files(from: .general, name: "Clipboard")
        guard !files.isEmpty else { throw APIError.unprocessable("Nothing printable on the clipboard.", code: "clipboard_empty") }
        return try await print(files: files, request: request, source: APIJob.Source.clipboard, trigger: .clipboard)
    }

    /// The saved label PDF is already label-sized, so it prints 1:1 (same as Reprint Last Label).
    func reprintLast(copies: Int?) async throws -> APIJob {
        store.refresh()
        guard let last = store.lastPrint else { throw APIError.notFound("Nothing printed yet.", code: "no_last_print") }
        let plan: JobPlan?
        do { plan = try JobFlow.reprintPlan(store: store, copies: copies) } catch let e as OptionError { throw APIError(e) }
        guard let plan else { throw APIError.notFound("Printer \(last.printer) not found.", code: "printer_not_found") }
        return try await run(plan.files, plan: plan, source: APIJob.Source.reprint)
    }

    func jobs() -> [APIJob] { recent }

    /// Adds a job to the list `jobs()` returns (newest first, at most `maxJobs`).
    func record(_ job: APIJob) {
        recent.insert(job, at: 0)
        if recent.count > Self.maxJobs { recent.removeLast(recent.count - Self.maxJobs) }
    }

    // MARK: Printing

    /// The rule for the first file, with the request's options on top (`JobFlow.plan`). The rule's action decides:
    /// none counts down like a drop; Show preview or Ask (Ask is the preview for files handed over) waits for Print.
    func plan(_ files: [URL], _ r: APIPrintRequest, trigger: RuleTrigger = .api) async throws -> JobPlan {
        store.refresh()
        let r = r.normalized   // an empty printer means "not given": the rule's printer, else the default
        let forced = try r.printer.map { try findPrinter($0) }
        do {
            guard let plan = try await JobFlow.plan(files, trigger: trigger, store: store, engine: rules, forcedPrinter: forced,
                                                    overrides: r.overrides, copies: r.copies) else {
                throw APIError.notFound("No label printer found.", code: "no_printer")
            }
            return plan
        } catch let e as OptionError {
            throw APIError(e)
        }
    }

    private func run(_ files: [URL], plan: JobPlan, source: String) async throws -> APIJob {
        let job = JobFlow.makeJob(plan, store: store)
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
        let counts = job.labels.codeCounts
        r.labels = job.labels.count
        r.codesFound = counts.expected
        r.codesVerified = counts.verified
        r.codesMissing = counts.missing
        r.warnings = job.warnings
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

    /// A printer by queue or display name (`PrinterResolver.match`, hidden ones included), or the default.
    func findPrinter(_ name: String?) throws -> PrinterInfo {
        guard let name, !name.isEmpty else {
            guard let p = store.printer else { throw APIError.notFound("No label printer found.", code: "no_printer") }
            return p
        }
        guard let p = store.resolver.find(name) else { throw APIError.notFound("Printer \(name) not found.", code: "printer_not_found") }
        return p
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
                     codes: codes(label), warnings: label.reportableWarnings)
    }

    nonisolated static func percent(_ label: ComposedLabel) -> Double { (Double(label.scale) * 1000).rounded() / 10 }

    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
