import CoreGraphics
import Foundation
import LabelizeCLI
import LabelizeCore
import LabelKit
import PeelGoodShared

/// print, preview, test-label and step-wedge: compose labels, write them, maybe send them.
struct LabelRun {
    struct Page: Encodable {
        var page: Int
        var sourceInches: [Double]
        var crop: [Double]
        var cropReason: String
        var rotated: Bool
        var scalePercent: Int
        var ink: String
        var codes: Int
        var codesReadable: Int
        var codeKinds: [String]
        var warnings: [String]
        var png: String?
    }

    struct File: Encodable {
        var input: String
        var pages: [Page]
        /// This file's labels on their own.
        var pdf: String
    }

    struct Report: Encodable {
        var command: String
        var printer: String?
        var printerModel: String?
        var printerFrom: String?
        var size: String
        var media: String
        var ink: String
        var cutoffPercent: Int
        var nudgeMM: [Double]
        var fromApp: [String]
        var copies: Int
        /// The app's rule that matched the first file, when rules were applied.
        var rule: String?
        var notes: [String]
        var dryRun: Bool
        var sent: Bool
        var outputFolder: String
        var files: [File]
        /// Every label of every file, in order: the one PDF that is sent (or would be), as the app sends a drop.
        var pdf: String?
        var lp: [String]?
        var job: String?
        /// The copy saved to History, when it was sent.
        var history: String?
    }

    enum Kind { case print, preview, testLabel, stepWedge }

    let ctx: Context
    let kind: Kind

    func run() throws -> ExitCode {
        let inv = ctx.inv
        let printers = Printers.all()
        let sends = kind != .preview && !inv.has("dry-run")
        let needsPrinter = kind != .preview
        var chosen = try ctx.choosePrinter(printers, required: needsPrinter)

        let outDir: URL
        if let out = inv["out"] {
            outDir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            outDir = FileManager.default.temporaryDirectory.appendingPathComponent("peelgood", isDirectory: true)
                .appendingPathComponent(kind == .preview ? "preview" : "print", isDirectory: true)
        }
        do { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) } catch {
            throw CLIError("can't make the folder \(tilde(outDir.path))", hint: "\(error.localizedDescription)", code: .failure)
        }

        var inputs: [URL] = inv.arguments.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        for url in inputs where !FileManager.default.fileExists(atPath: url.path) {
            let nearby = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
            let near = Parser.closest(url.lastPathComponent, among: nearby)
            throw CLIError("no file at \(tilde(url.path))", hint: near.map { "Did you mean \($0)?" }, code: .input)
        }

        // The app's rules pick printer, size, fit, ink and copies for the first file, as for a drop, and the same
        // way for preview, so it shows what print will do. --printer wins over the rule's printer, like a printer
        // tile does in the app.
        var notes: [String] = []
        let decision = kind == .print || kind == .preview ? decideByRules(inputs, printers: printers, chosen: chosen?.0) : nil
        if let d = decision {
            if ctx.requestedPrinter == nil, d.printer.name != chosen?.0.name { chosen = (d.printer, "rule “\(d.ruleName)”") }
            notes += d.notes
            if sends, d.action != .print {
                notes.append("“\(d.ruleName)” shows the preview in the app; \(ctx.tool) prints right away.")
            }
        }
        let printer = chosen?.0

        // The app's settings for this printer (or the rule's options), then the command line on top.
        let saved = printer.map { ctx.defaults.options(for: $0) }
        if let note = saved?.note, inv["size"] == nil, decision == nil || decision?.options.size == saved?.options.size { notes.append(note) }
        var options = try Layout.apply(inv, to: decision?.options ?? saved?.options ?? LabelOptions(), on: printer, tool: ctx.tool)
        let given = try Layout.overrides(inv).given
        var fromAppKeys = (saved?.saved ?? []).subtracting(given)
        var copies = try Layout.copies(inv)
        if inv["copies"] == nil, let d = decision { copies = d.copies }

        // Generated test pages print as drawn.
        let generated: TestLabel? = switch kind {
        case .testLabel: .pattern
        case .stepWedge: .stepWedge
        default: nil
        }
        if let generated {
            let url = outDir.appendingPathComponent("\(generated.fileStem(options.size)).pdf")
            do { try generated.writePDF(size: options.size, title: TestLabel.title(printer: printer, size: options.size), to: url) } catch {
                throw CLIError("can't write \(tilde(url.path))")
            }
            inputs = [url]
            generated.adjust(&options, keepInk: generated == .stepWedge && inv["ink"] != nil, keepToneGamma: inv["tone-gamma"] != nil)
            if generated == .pattern { fromAppKeys.subtract(["ink", "cutoff"]) }
            if generated == .stepWedge, inv["ink"] == nil { fromAppKeys.remove("ink") }
            fromAppKeys.remove("toneGamma")
        }

        var report = Report(command: name, printer: printer?.name, printerModel: printer?.displayName, printerFrom: chosen?.1,
                            size: options.size.description, media: options.size.cupsMedia, ink: options.ink.rawValue,
                            cutoffPercent: Int((options.cutoff * 100).rounded()), nudgeMM: [options.nudgeMM.x, options.nudgeMM.y],
                            fromApp: fromAppKeys.sorted(), copies: copies, rule: decision?.ruleName, notes: notes,
                            dryRun: inv.has("dry-run"), sent: false, outputFolder: outDir.path, files: [])
        header(printer: printer, from: chosen?.1, options: options, fromApp: fromAppKeys, copies: copies,
               rule: decision.flatMap { $0.isFallback ? nil : $0.ruleName })
        for note in notes { ctx.say("  \(ctx.out.warn) \(ctx.out.yellow(note))") }

        var failed = false
        var labels: [ComposedLabel] = []
        for url in inputs {
            do {
                let (file, composed) = try process(url, options: options, printer: printer, outDir: outDir, sends: sends)
                report.files.append(file)
                labels += composed
            } catch let e as CLIError {
                // Report every file that can't be read, then stop: like a drop in the app, the files print together or not at all.
                ctx.note("\(ctx.err.fail) \(e.message)" + (e.hint.map { "\n  \(ctx.err.dim($0))" } ?? ""))
                failed = true
                if inputs.count == 1 { throw ExitOnly(code: e.code) }
            }
        }
        if let printer, kind != .preview {
            if failed {
                if sends { ctx.note("\(ctx.err.fail) nothing sent: every file has to be readable") }
            } else {
                try send(labels, inputs: inputs, report: &report, printer: printer, options: options, outDir: outDir,
                         copies: copies, sends: sends)
            }
        }
        report.sent = sends && !failed && report.job != nil
        if ctx.json { ctx.emit(report) }
        // Only when asked: --open shows the PDFs in Preview.
        if kind == .preview, inv.has("open"), !report.files.isEmpty {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", "Preview"] + report.files.map(\.pdf)
            try? open.run()
        }
        return failed ? .failure : .ok
    }

    /// The rule book, when rules apply: --rules, or rules.json exists; never with --no-rules. Read only.
    private func decideByRules(_ inputs: [URL], printers: [PrinterInfo], chosen: PrinterInfo?) -> RuleDecision? {
        let inv = ctx.inv
        guard !inv.has("no-rules"), let first = inputs.first else { return nil }
        guard let book = RuleBook.load(from: AppPaths.rulesFile, setAsideBroken: false) else {
            if inv.has("rules") { ctx.note("\(ctx.err.warn) no rules to apply in \(tilde(AppPaths.rulesFile.path))") }
            return nil
        }
        let resolver = ctx.resolver(printers)
        let context = RuleContext.inspect(first, trigger: .cli, detectCodes: book.needsCodes, readText: book.needsText)
        return book.decide(context, printers: resolver.eligible, current: chosen,
                           defaults: { ctx.defaults.options(for: $0).options },
                           forcedPrinter: ctx.requestedPrinter != nil ? chosen : nil, unattended: ctx.defaults.newFilesAction)
    }

    /// Saves the sent PDF to History and makes it Reprint Last Label, like the app does, unless --no-history.
    /// Reprint Last Label is the one setting the command line writes.
    private func record(_ pdf: URL, source: URL, printer: PrinterInfo, size: LabelSize) -> URL? {
        guard !ctx.inv.has("no-history") else { return nil }
        do {
            let saved = try History.save(pdf, source: source, in: ctx.historyFolder)
            let writer = AppSettings.system(environment: ctx.environment, writable: true)
            if writer.isWritable { writer.lastPrint = AppSettings.LastPrint(file: saved, printer: printer.name, size: size) }
            History.prune(keepingDays: ctx.defaults.historyDays, in: ctx.historyFolder)
            return saved
        } catch {
            ctx.note("\(ctx.err.warn) couldn't save to History: \(error.localizedDescription)")
            return nil
        }
    }

    var name: String {
        switch kind {
        case .print: "print"
        case .preview: "preview"
        case .testLabel: "test-label"
        case .stepWedge: "step-wedge"
        }
    }

    private func header(printer: PrinterInfo?, from: String?, options: LabelOptions, fromApp: Set<String>, copies: Int, rule: String?) {
        let s = ctx.out
        var parts = [s.bold(options.size.primary), "ink \(options.ink.rawValue)"]
        if options.cutoff != 0.5 { parts.append("cutoff \(Int((options.cutoff * 100).rounded()))%") }
        if options.nudgeMM != .zero { parts.append(String(format: "nudge %g,%g mm", options.nudgeMM.x, options.nudgeMM.y)) }
        if copies > 1 { parts.append("\(copies) copies") }
        let on = printer.map { " on \(s.bold($0.displayName)) \(s.dim("(\($0.name))"))" } ?? ""
        ctx.say("\(s.accent("●")) \(parts.joined(separator: " \(s.dot) "))\(on)")
        if ctx.verbose || rule != nil || (!fromApp.isEmpty && kind != .preview) {
            var notes: [String] = []
            if let rule, from != "rule “\(rule)”" { notes.append("rule “\(rule)”") }
            if let from, from != "--printer" { notes.append("printer from \(from == "app" ? "the app" : from)") }
            if !fromApp.isEmpty { notes.append(fromApp.sorted().joined(separator: ", ") + " from the app's settings") }
            if !notes.isEmpty { ctx.say("  " + s.dim(notes.joined(separator: "; "))) }
        }
    }

    /// Composes one file's pages and writes its own label PDF (and PNGs for previews). Doesn't send.
    private func process(_ url: URL, options: LabelOptions, printer: PrinterInfo?, outDir: URL, sends: Bool) throws -> (File, [ComposedLabel]) {
        let s = ctx.out
        let pages: [SourcePage]
        do { pages = try DocumentLoader.load(url) } catch {
            throw CLIError("\(error)", hint: "Peel Good reads PDF, SVG, PNG, JPEG, HEIC and TIFF.", code: .input)
        }
        let base = url.deletingPathExtension().lastPathComponent
        var file = File(input: url.path, pages: [], pdf: "")
        var labels: [ComposedLabel] = []
        let writesPreviews = kind == .preview || ctx.inv["out"] != nil && kind == .print && ctx.inv.legacyHint != nil

        ctx.say("\(s.bold(url.lastPathComponent)) \(s.dim("\(pages.count) page\(pages.count == 1 ? "" : "s")"))")
        for (i, page) in pages.enumerated() {
            let label = LabelComposer.compose(page, options)
            labels.append(label)
            let c = label.crop.rect
            let counts = label.codeCounts, readable = counts.verified
            let warnings = label.reportableWarnings
            var entry = Page(page: i + 1, sourceInches: [round3(page.size.width / 72), round3(page.size.height / 72)],
                             crop: [c.minX, c.minY, c.width, c.height].map { round3($0 / 72) }, cropReason: label.crop.reason,
                             rotated: label.rotated, scalePercent: Int((label.scale * 100).rounded()), ink: label.ink.rawValue,
                             codes: counts.expected, codesReadable: readable,
                             codeKinds: label.expectedCodes.map(\.symbology), warnings: warnings)
            if writesPreviews {
                let png = outDir.appendingPathComponent("\(base)-p\(i + 1).png")
                do { try LabelWriter.writePNG(label, to: png) } catch { throw CLIError("\(error)") }
                entry.png = png.path
            }
            file.pages.append(entry)

            var line = [label.crop.reason, "\(entry.scalePercent)%", "ink \(label.ink.rawValue)"]
            if label.rotated { line.insert("rotated", at: 1) }
            if counts.expected > 0 {
                let codes = "\(readable)/\(counts.expected) code\(counts.expected == 1 ? "" : "s") scan"
                line.append(counts.missing.isEmpty ? s.green(codes) : s.red(codes))
            }
            let mark = counts.missing.isEmpty ? s.ok : s.fail
            ctx.say("  \(mark) \(s.dim("page \(i + 1)"))  " + line.joined(separator: " \(s.dot) "))
            for w in warnings { ctx.say("    \(s.warn) \(s.yellow(w))") }
            if ctx.verbose {
                ctx.say(s.dim("    page \(inches(page.size.width))x\(inches(page.size.height)) in, crop \(inches(c.width))x\(inches(c.height)) at (\(inches(c.minX)), \(inches(c.minY)))"))
                ctx.say(s.dim("    smooth gray \(String(format: "%.1f", label.smoothGray * 100))%, 1-dot features \(label.oneDotFeatures)"))
                for d in CodeAnalysis.analyze(label, dpi: options.dpi) {
                    let hist = d.runs.sorted { $0.key < $1.key }.prefix(12).map { "\($0.key):\($0.value)" }.joined(separator: " ")
                    ctx.say(s.dim("    \(d.symbology) \(d.picketFence ? "picket" : "ladder") · module ≈ \(String(format: "%.2f", d.moduleDots)) dots · runs \(hist)"))
                }
                for r in label.codeReports {
                    ctx.say(s.dim("    \(r.symbology) fit · \(String(format: "%.2f", r.moduleDots)) dots/module\(r.redrawn ? ", redrawn" : "") · \(r.severity)"))
                }
            }
        }

        let pdf = outDir.appendingPathComponent("\(base).label.pdf")
        do {
            try LabelWriter.write(labels, size: options.size, forLabelPrinter: printer?.isLabelPrinter != false, to: pdf)
        } catch { throw CLIError("\(error)") }
        file.pdf = pdf.path

        if kind == .preview || (ctx.inv["out"] != nil && !sends && !ctx.inv.has("dry-run")) {
            ctx.say("  \(s.arrow) \(tilde(pdf.path))")
            for p in file.pages.compactMap(\.png) { ctx.say("    \(s.dim(tilde(p)))") }
        }
        return (file, labels)
    }

    /// Writes every label into one PDF and sends it once with the copies, then saves it to History once,
    /// with the first file as its source: what the app does with a drop of several files.
    private func send(_ labels: [ComposedLabel], inputs: [URL], report: inout Report, printer: PrinterInfo, options: LabelOptions,
                      outDir: URL, copies: Int, sends: Bool) throws {
        let s = ctx.out
        guard let first = inputs.first, !labels.isEmpty else { return }
        let base = first.deletingPathExtension().lastPathComponent
        let pdf: URL
        if inputs.count == 1, let own = report.files.first?.pdf {
            pdf = URL(fileURLWithPath: own)
        } else {
            pdf = outDir.appendingPathComponent("\(base) and \(inputs.count - 1) more.label.pdf")
            do {
                try LabelWriter.write(labels, size: options.size, forLabelPrinter: printer.isLabelPrinter, to: pdf)
            } catch { throw CLIError("\(error)") }
        }
        report.pdf = pdf.path
        let args = LabelPrint.lpArguments(file: pdf, printer: printer.name, size: options.size, copies: copies)
        report.lp = ["lp"] + args
        let what = "\(labels.count) label\(labels.count == 1 ? "" : "s")"
        if sends {
            do {
                let id = try LabelPrint.send(file: pdf, printer: printer.name, size: options.size, copies: copies)
                report.job = id
                ctx.say("\(s.ok) \(s.green("Sent \(what) to \(printer.displayName)")) \(s.dim(id))")
                if let saved = record(pdf, source: first, printer: printer, size: options.size) {
                    report.history = saved.path
                    if ctx.verbose { ctx.say(s.dim("  saved to History: \(tilde(saved.path))")) }
                }
            } catch {
                throw CLIError("printing failed on \(printer.name): \(error)",
                               hint: "`\(ctx.tool) doctor` checks the printer and CUPS.", code: .printer)
            }
        } else {
            let shown = (["lp"] + args).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
            ctx.say("\(s.arrow) \(s.dim("dry run, \(what), would run:")) \(shown)")
        }
    }
}

/// An error already reported; only the exit code is left.
struct ExitOnly: Error { var code: ExitCode }

private func round3(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
