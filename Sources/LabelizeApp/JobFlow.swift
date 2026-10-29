import AppKit
import LabelKit

/// Shows a print job the way a drop is shown: the popover with its countdown, or the preview
/// with Print and Cancel. `AppDelegate` is the real one; tests use a stand-in.
@MainActor
protocol JobPresenter: AnyObject {
    /// Shows the job and starts it. The job reports how it ended through `onOutcome`.
    func present(_ job: PrintJob)
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

    /// A job with the app's after-print steps: remember it for reprinting, play the sound,
    /// tag (the rule's tag, else General > After Printing) and rename, move or trash the originals.
    /// Temporary copies (uploads, clipboard, reprints) are never tagged or moved.
    static func makeJob(_ files: [URL], printer: PrinterInfo, options: LabelOptions, review: Bool,
                        decision: RuleDecision?, copies: Int? = nil, store: Store) -> PrintJob {
        let job = PrintJob(files: files, printer: printer, options: options, reviewFirst: review, countdownSeconds: store.countdown)
        job.copies = copies ?? decision?.copies ?? 1
        job.notes = decision?.notes ?? []
        job.onSent = { [weak job] url in
            guard let job else { return }
            store.lastPrint = Store.LastPrint(file: url, printer: job.printer.name, size: job.options.size)
            Sounds.play(Sounds.sent, if: store.playSounds)
            // A rule's own tag replaces the general one; "Everything else" follows General.
            let ruleTag = decision?.isFallback == false ? decision?.tag : nil
            AfterPrint.apply(to: job.files, store: store, tag: ruleTag == nil)
            if let tag = ruleTag {
                for file in job.files where AfterPrint.isUserFile(file) { tag.apply(to: file) }
            }
            History.prune(keepingDays: store.historyDays)
        }
        return job
    }
}
