import AppKit
import LabelKit

/// One drop: compose every page, optionally wait for review, count down, print.
@MainActor
final class PrintJob: ObservableObject {
    enum Phase: Equatable { case composing, review, countdown, printing, done, failed(String) }

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
    private var countdown: Task<Void, Never>?

    init(files: [URL], printer: PrinterInfo, options: LabelOptions, reviewFirst: Bool, countdownSeconds: Double) {
        self.files = files
        self.printer = printer
        self.options = options
        self.reviewFirst = reviewFirst
        self.countdownSeconds = countdownSeconds
    }

    var title: String {
        let n = labels.count
        return "\(n) label\(n == 1 ? "" : "s") · \(options.size.display)"
    }

    var codeSummary: String? {
        let expected = labels.reduce(0) { $0 + $1.expectedCodes.count }
        guard expected > 0 else { return nil }
        let missing = labels.reduce(0) { $0 + $1.missingCodes.count }
        return missing == 0 ? "\(expected)/\(expected) codes scan" : "\(missing) of \(expected) codes won't scan"
    }

    /// Problems worth showing: everything except cautions about codes that should still scan.
    var warnings: [String] {
        let cautions = Set(labels.flatMap(\.codeReports).filter { $0.severity == .caution }.compactMap(\.message))
        return notes + Array(Set(labels.flatMap(\.warnings)).subtracting(cautions)).sorted()
    }

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
            let codes = labels.reduce(0) { $0 + $1.expectedCodes.count }, missing = labels.reduce(0) { $0 + $1.missingCodes.count }
            Log.info(.job, "composed \(labels.count) label(s) at \(options.size), \(codes) code(s), \(missing) unreadable")
            for w in Set(labels.flatMap(\.warnings)) { Log.warning(.job, w) }
            if labels.isEmpty {
                Log.error(.job, "nothing to print in \(files.map(\.lastPathComponent).joined(separator: ", "))")
                phase = .failed("Nothing to print")
            }
        } catch {
            Log.error(.job, "couldn't read \(files.map(\.lastPathComponent).joined(separator: ", ")): \(error)")
            phase = .failed("\(error)")
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
        onFinish()
    }

    func send() async {
        phase = .printing
        let name = files.first?.deletingPathExtension().lastPathComponent ?? "label"
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = Store.historyFolder.appendingPathComponent("\(stamp) \(name).label.pdf")
        let labels = labels, printer = printer, size = options.size, copies = copies
        do {
            try await Task.detached {
                if printer.isLabelPrinter {
                    try LabelWriter.writePDF(labels, size: size, to: url)
                } else {
                    try LabelWriter.writeVectorPDF(labels, size: size, to: url)
                }
                let id = try LabelPrint.send(file: url, printer: printer.name, size: size, copies: copies)
                Log.notice(.print, "sent \(labels.count) label(s) to \(printer.name) (media \(size.cupsMedia)): \(id)")
            }.value
            phase = .done
            onSent(url)
            try? await Task.sleep(for: .seconds(1.4))
            onFinish()
        } catch {
            Log.error(.print, "print failed on \(printer.name): \(error)")
            phase = .failed("\(error)")
        }
    }
}
