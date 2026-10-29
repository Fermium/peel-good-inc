import AppKit
import LabelKit
import LabelizeCore

/// Shows a print job the way a drop is shown: the popover with its countdown, or the preview
/// with Print and Cancel. `AppDelegate` is the real one; tests use a stand-in.
@MainActor
protocol JobPresenter: AnyObject {
    /// Shows the job and starts it. The job reports how it ended through `onOutcome`.
    func present(_ job: PrintJob)
}

/// What a print will do, decided once for drops, the menu, watched folders, the API and MCP.
struct JobPlan {
    var files: [URL]
    var printer: PrinterInfo
    var options: LabelOptions
    var copies: Int
    /// The rule's action (Ask only for watched folders; see `RuleBook.decide`).
    var action: RuleAction
    /// Wait for Print in the preview instead of counting down.
    var review: Bool
    var decision: RuleDecision?
    /// The matching rule's name, "Everything else", or nil for reprints and test labels.
    var rule: String? { decision?.ruleName }
}

/// The steps every print shares, whether the file was dropped or arrived over the API:
/// pick the rule, build the job, and do what a print does afterwards.
@MainActor
enum JobFlow {
    /// The first file's matching rule, with its printer, options, copies and action.
    static func decide(_ files: [URL], trigger: RuleTrigger, store: Store, engine: RuleEngine,
                       forcedPrinter: PrinterInfo? = nil) async -> RuleDecision? {
        guard let first = files.first else { return nil }
        let needsCodes = engine.needsCodes, needsText = engine.needsText
        let context = await Task.detached { RuleContext.inspect(first, trigger: trigger, detectCodes: needsCodes, readText: needsText) }.value
        let decision = engine.decide(context, printers: store.eligiblePrinters, current: store.printer,
                                     defaults: { [store] in store.options(for: $0) }, forcedPrinter: forcedPrinter,
                                     unattended: store.newFilesAction)
        if let d = decision {
            Log.info(.rules, "\(first.lastPathComponent): rule \"\(d.rule.name)\" → \(d.printer.name), \(d.options.size), \(d.action.rawValue), \(d.copies) cop\(d.copies == 1 ? "y" : "ies")")
            for note in d.notes { Log.warning(.rules, note) }
        }
        return decision
    }

    /// The rule's decision with the request's options on top: the one plan for every way a file arrives.
    /// - Parameters:
    ///   - overrides: size, fit and ink asked for (API, MCP); they win over the rule's.
    ///   - copies: copies asked for; else the rule's.
    ///   - review: show the preview whatever the rule says (⌥ on drop).
    ///   - action: replaces the rule's action (a notification's Print or Preview button).
    /// - Returns: nil when there's no printer.
    static func plan(_ files: [URL], trigger: RuleTrigger, store: Store, engine: RuleEngine, forcedPrinter: PrinterInfo? = nil,
                     overrides: OptionOverrides = OptionOverrides(), copies: Int? = nil, review: Bool = false,
                     action: RuleAction? = nil) async throws -> JobPlan? {
        guard let d = await decide(files, trigger: trigger, store: store, engine: engine, forcedPrinter: forcedPrinter) else { return nil }
        let options = try overrides.apply(to: d.options, on: d.printer)
        let action = action ?? d.action
        return JobPlan(files: files, printer: d.printer, options: options, copies: try copies.map { try OptionOverrides.copies($0) } ?? d.copies,
                       action: action, review: review || store.alwaysReview || action != .print, decision: d)
    }

    /// Reprint Last Label: the saved label PDF is already label-sized, so it prints 1:1 on the same printer
    /// (or the default one, if that's gone).
    static func reprintPlan(store: Store, copies: Int? = nil, review: Bool = false) throws -> JobPlan? {
        guard let last = store.lastPrint, let printer = store.resolver.find(last.printer) ?? store.printer else { return nil }
        var options = store.options(for: printer)
        options.size = printer.resolve(last.size) ?? last.size
        options.crop = .none
        options.nudgeMM = .zero
        return JobPlan(files: [last.file], printer: printer, options: options, copies: try OptionOverrides.copies(copies),
                       action: .print, review: review || store.alwaysReview, decision: nil)
    }

    /// A generated test page for a printer at its size. Doesn't change the default printer.
    static func testLabelPlan(_ kind: TestLabel = .pattern, printer: PrinterInfo, store: Store, review: Bool) -> JobPlan? {
        var options = store.options(for: printer)
        let size = options.size
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(kind.fileStem(size)).pdf")
        do { try kind.writePDF(size: size, title: TestLabel.title(printer: printer, size: size), to: url) } catch {
            Log.error(.job, "couldn't write the test label: \(error)")
            return nil
        }
        kind.adjust(&options)
        return JobPlan(files: [url], printer: printer, options: options, copies: 1, action: .print, review: review || store.alwaysReview, decision: nil)
    }

    /// A job with the app's after-print steps: remember it for reprinting, play the sound,
    /// tag (see `RuleTag`) and rename, move or trash the originals.
    /// Temporary copies (uploads, clipboard, reprints) are never tagged or moved.
    static func makeJob(_ plan: JobPlan, store: Store) -> PrintJob {
        let job = PrintJob(files: plan.files, printer: plan.printer, options: plan.options, reviewFirst: plan.review, countdownSeconds: store.countdown)
        job.copies = plan.copies
        job.notes = plan.decision?.notes ?? []
        let tag = (plan.decision?.tag ?? .general).resolve(store.settings)
        job.onSent = { [weak job] url in
            guard let job else { return }
            store.lastPrint = Store.LastPrint(file: url, printer: job.printer.name, size: job.options.size)
            Sounds.play(Sounds.sent, if: store.playSounds)
            AfterPrint.apply(to: job.files, store: store, tag: tag)
            History.prune(keepingDays: store.historyDays)
        }
        return job
    }
}
