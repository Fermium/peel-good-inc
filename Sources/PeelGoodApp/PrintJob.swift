import AppKit
import LabelKit
import PeelGoodCore

/// One drop: compose every page, optionally wait for review, count down, print.
@MainActor
final class PrintJob: ObservableObject {
    enum Phase: Equatable { case composing, review, countdown, printing, done, failed(String) }

    /// How the job ended, for callers that wait on it (the API).
    enum Outcome: Equatable {
        case printed(file: URL, printerJobID: String)
        case cancelled
        case failed(String)
    }

    typealias Sender = @Sendable (_ file: URL, _ printer: PrinterInfo, _ size: LabelSize, _ copies: Int) throws -> String

    @Published var phase: Phase = .composing
    @Published var labels: [ComposedLabel] = []
    @Published var previews: [NSImage] = []
    @Published var progress = 0.0
    @Published var options: LabelOptions
    @Published var printer: PrinterInfo

    let files: [URL]
    let reviewFirst: Bool
    /// Seconds to wait (cancellable) before printing; 0 prints as soon as the labels are ready.
    let countdownSeconds: Double
    /// Copies of the whole set of labels.
    var copies = 1
    /// Notes from the matching rule (e.g. its printer isn't connected), shown with the warnings.
    var notes: [String] = []
    var onFinish: () -> Void = {}
    /// Called with the saved PDF once the printer has accepted the job.
    var onSent: (URL) -> Void = { _ in }
    /// Called once, when the job prints, is cancelled or fails.
    var onOutcome: (Outcome) -> Void = { _ in }
    /// Hands the saved PDF to the print system. Swapped in tests and dry runs.
    var sender: Sender = PrintJob.defaultSender

    static let liveSender: Sender = { file, printer, size, copies in
        try LabelPrint.send(file: file, printer: printer, size: size, copies: copies)
    }

    /// Logs instead of printing: `-dryRunPrinting` for the whole app, `-apiDryRun` for API and MCP jobs.
    static let dryRunSender: Sender = { file, printer, size, copies in
        Log.notice(.print, "dry run: would send \(file.lastPathComponent) to \(printer.name) at \(size), \(copies) copies")
        return "dry-run"
    }

    static var isDryRun: Bool { ProcessInfo.processInfo.arguments.contains("-dryRunPrinting") }
    static var defaultSender: Sender { isDryRun ? dryRunSender : liveSender }
    private(set) var outcome: Outcome?
    private var countdown: Task<Void, Never>?

    private func finish(_ o: Outcome) {
        guard outcome == nil else { return }
        outcome = o
        onOutcome(o)
    }

    init(files: [URL], printer: PrinterInfo, options: LabelOptions, reviewFirst: Bool, countdownSeconds: Double) {
        self.files = files
        self.printer = printer
        self.options = options
        self.reviewFirst = reviewFirst
        self.countdownSeconds = countdownSeconds
    }

    /// Waiting for Print, Cancel or Close: it can't go on or end by itself.
    var awaitsAnswer: Bool {
        switch phase {
        case .composing, .review: reviewFirst
        case .failed: true
        default: false
        }
    }

    var title: String {
        let n = labels.count
        return "\(n) label\(n == 1 ? "" : "s") · \(options.size.display)"
    }

    var codeSummary: String? {
        let counts = labels.codeCounts, expected = counts.expected, missing = counts.missing.count
        guard expected > 0 else { return nil }
        return missing == 0 ? "\(expected)/\(expected) codes scan" : "\(missing) of \(expected) codes won't scan"
    }

    /// Problems worth showing: everything except cautions about codes that should still scan.
    var warnings: [String] { notes + labels.reportableWarnings }

    func start() {
        Task {
            await compose()
            guard phase == .composing else { return }
            if reviewFirst { phase = .review } else { beginCountdown() }
        }
    }

    /// Re-composes after a change in review.
    func update(_ change: (inout LabelOptions) -> Void) {
        change(&options)
        Task {
            phase = .composing
            await compose()
            if phase == .composing { phase = .review }
        }
    }

    private func compose() async {
        let files = files, options = options
        do {
            let labels = try await Task.detached(priority: .userInitiated) {
                try Self.composeAll(files, options)
            }.value
            self.labels = labels
            self.previews = labels.compactMap { l in
                l.bitmap.cgImage().map { NSImage(cgImage: $0, size: l.placement.target) }
            }
            let counts = labels.codeCounts
            Log.info(.job, "composed \(labels.count) label(s) at \(options.size), \(counts.expected) code(s), \(counts.missing.count) unreadable")
            for w in labels.reportableWarnings { Log.warning(.job, w) }
            if labels.isEmpty {
                Log.error(.job, "nothing to print in \(files.map(\.lastPathComponent).joined(separator: ", "))")
                phase = .failed("Nothing to print")
                finish(.failed("Nothing to print"))
            }
        } catch {
            Log.error(.job, "couldn't read \(files.map(\.lastPathComponent).joined(separator: ", ")): \(error)")
            phase = .failed("\(error)")
            finish(.failed("\(error)"))
        }
    }

    /// Every page of every file becomes a label, in order.
    nonisolated static func composeAll(_ files: [URL], _ o: LabelOptions) throws -> [ComposedLabel] {
        try files.flatMap { try DocumentLoader.load($0).map { LabelComposer.compose($0, o) } }
    }

    func beginCountdown() {
        guard countdownSeconds > 0 else {
            Task { await send() }
            return
        }
        phase = .countdown
        progress = 0
        countdown = Task {
            let steps = 30
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(countdownSeconds / Double(steps)))
                if Task.isCancelled { return }
                progress = Double(i) / Double(steps)
            }
            await send()
        }
    }

    func cancel() {
        Log.info(.job, "cancelled")
        countdown?.cancel()
        finish(.cancelled)
        onFinish()
    }

    func send() async {
        phase = .printing
        guard outcome == nil else { return }
        let url = History.folder.appendingPathComponent(History.fileName(for: files.first))
        let labels = labels, printer = printer, size = options.size, copies = copies, sender = sender
        do {
            let id = try await Task.detached {
                try LabelWriter.write(labels, size: size, forLabelPrinter: printer.isLabelPrinter, to: url)
                let id = try sender(url, printer, size, copies)
                Log.notice(.print, "sent \(labels.count) label(s) to \(printer.name) (media \(size.cupsMedia)): \(id)")
                return id
            }.value
            phase = .done
            onSent(url)
            finish(.printed(file: url, printerJobID: id))
            try? await Task.sleep(for: .seconds(1.4))
            onFinish()
        } catch {
            Log.error(.print, "print failed on \(printer.name): \(error)")
            phase = .failed("\(error)")
            finish(.failed("\(error)"))
        }
    }
}
