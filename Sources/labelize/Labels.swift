import CoreGraphics
import Foundation
import LabelizeCLI
import LabelKit

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
        var pdf: String
        var lp: [String]?
        var job: String?
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
        var dryRun: Bool
        var sent: Bool
        var outputFolder: String
        var files: [File]
    }

    enum Kind { case print, preview, testLabel, stepWedge }

    let ctx: Context
    let kind: Kind

    func run() throws -> ExitCode {
        let inv = ctx.inv
        let printers = Printers.all()
        let sends = kind != .preview && !inv.has("dry-run")
        let needsPrinter = kind != .preview
        let chosen = try ctx.choosePrinter(printers, required: needsPrinter)
        let printer = chosen?.0

        // The app's settings for this printer, then the command line on top.
        let fromApp = printer.map { ctx.defaults.options(for: $0.name) } ?? (LabelOptions(), [])
        var options = try Layout.apply(inv, to: fromApp.options)
        var fromAppKeys = fromApp.fromApp.filter { inv[$0] == nil }
        if let printer {
            guard let resolved = printer.resolve(options.size) else {
                throw CLIError("\(printer.name) can't take \(options.size.display) labels",
                               hint: "`\(ctx.tool) sizes \(printer.name)` lists the sizes it takes.", code: .printer)
            }
            options.size = resolved
        }
        let copies = try Layout.copies(inv)

        // Inputs: the files, or a generated test page.
        let outDir: URL
        if let out = inv["out"] {
            outDir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            outDir = FileManager.default.temporaryDirectory.appendingPathComponent("labelize", isDirectory: true)
                .appendingPathComponent(kind == .preview ? "preview" : "print", isDirectory: true)
        }
        do { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) } catch {
            throw CLIError("can't make the folder \(tilde(outDir.path))", hint: "\(error.localizedDescription)", code: .failure)
        }

        var inputs: [URL] = inv.arguments.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if kind == .testLabel || kind == .stepWedge {
            let model = printer?.model ?? "Peel Good Inc."
            let name = kind == .testLabel ? "test-label-\(options.size)" : "step-wedge-\(options.size)"
            let page = kind == .testLabel
                ? TestPattern.page(size: options.size, title: "\(model) · \(options.size) in")
                : StepWedge.page(size: options.size, title: "\(model) · \(options.size) in · ink \(options.ink.rawValue)")
            let url = outDir.appendingPathComponent("\(name).pdf")
            try writeSource(page, size: options.size, to: url)
            inputs = [url]
            options.crop = .none
            options.rotation = .none
            if kind == .testLabel { options.ink = .crisp; fromAppKeys.remove("ink"); fromAppKeys.remove("cutoff") }
        }
        for url in inputs where !FileManager.default.fileExists(atPath: url.path) {
            let nearby = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
            let near = Parser.closest(url.lastPathComponent, among: nearby)
            throw CLIError("no file at \(tilde(url.path))", hint: near.map { "Did you mean \($0)?" }, code: .input)
        }

        var report = Report(command: name, printer: printer?.name, printerModel: printer?.model, printerFrom: chosen?.1,
                            size: options.size.description, media: options.size.cupsMedia, ink: options.ink.rawValue,
                            cutoffPercent: Int((options.cutoff * 100).rounded()), nudgeMM: [options.nudgeMM.x, options.nudgeMM.y],
                            fromApp: fromAppKeys.sorted(), copies: copies, dryRun: inv.has("dry-run"), sent: false,
                            outputFolder: outDir.path, files: [])
        header(printer: printer, from: chosen?.1, options: options, fromApp: fromAppKeys, copies: copies)

        var failed = false
        for url in inputs {
            do {
                report.files.append(try process(url, options: options, printer: printer, outDir: outDir, copies: copies, sends: sends))
            } catch let e as CLIError {
                // Keep going with the other files; report this one.
                ctx.note("\(ctx.err.fail) \(e.message)" + (e.hint.map { "\n  \(ctx.err.dim($0))" } ?? ""))
                failed = true
                if inputs.count == 1 { throw ExitOnly(code: e.code) }
            }
        }
        report.sent = sends && !failed
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

    var name: String {
        switch kind {
        case .print: "print"
        case .preview: "preview"
        case .testLabel: "test-label"
        case .stepWedge: "step-wedge"
        }
    }

    private func header(printer: PrinterInfo?, from: String?, options: LabelOptions, fromApp: Set<String>, copies: Int) {
        let s = ctx.out
        var parts = [s.bold(options.size.display), "ink \(options.ink.rawValue)"]
        if options.cutoff != 0.5 { parts.append("cutoff \(Int((options.cutoff * 100).rounded()))%") }
        if options.nudgeMM != .zero { parts.append(String(format: "nudge %g,%g mm", options.nudgeMM.x, options.nudgeMM.y)) }
        if copies > 1 { parts.append("\(copies) copies") }
        let on = printer.map { " on \(s.bold($0.model)) \(s.dim("(\($0.name))"))" } ?? ""
        ctx.say("\(s.accent("●")) \(parts.joined(separator: " \(s.dot) "))\(on)")
        if ctx.verbose || (!fromApp.isEmpty && kind != .preview) {
            var notes: [String] = []
            if let from, from != "--printer" { notes.append("printer from \(from == "app" ? "the app" : from)") }
            if !fromApp.isEmpty { notes.append(fromApp.sorted().joined(separator: ", ") + " from the app's settings") }
            if !notes.isEmpty { ctx.say("  " + s.dim(notes.joined(separator: "; "))) }
        }
    }

    private func process(_ url: URL, options: LabelOptions, printer: PrinterInfo?, outDir: URL, copies: Int, sends: Bool) throws -> File {
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
            let readable = label.expectedCodes.count - label.missingCodes.count
            var entry = Page(page: i + 1, sourceInches: [round3(page.size.width / 72), round3(page.size.height / 72)],
                             crop: [c.minX, c.minY, c.width, c.height].map { round3($0 / 72) }, cropReason: label.crop.reason,
                             rotated: label.rotated, scalePercent: Int((label.scale * 100).rounded()), ink: label.ink.rawValue,
                             codes: label.expectedCodes.count, codesReadable: readable,
                             codeKinds: label.expectedCodes.map(\.symbology), warnings: label.warnings)
            if writesPreviews {
                let png = outDir.appendingPathComponent("\(base)-p\(i + 1).png")
                do { try LabelWriter.writePNG(label, to: png) } catch { throw CLIError("\(error)") }
                entry.png = png.path
            }
            file.pages.append(entry)

            var line = [label.crop.reason, "\(entry.scalePercent)%", "ink \(label.ink.rawValue)"]
            if label.rotated { line.insert("rotated", at: 1) }
            if !label.expectedCodes.isEmpty {
                let codes = "\(readable)/\(label.expectedCodes.count) code\(label.expectedCodes.count == 1 ? "" : "s") scan"
                line.append(readable == label.expectedCodes.count ? s.green(codes) : s.red(codes))
            }
            let mark = label.missingCodes.isEmpty ? s.ok : s.fail
            ctx.say("  \(mark) \(s.dim("page \(i + 1)"))  " + line.joined(separator: " \(s.dot) "))
            for w in label.warnings { ctx.say("    \(s.warn) \(s.yellow(w))") }
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
            if printer?.isLabelPrinter == false {
                try LabelWriter.writeVectorPDF(labels, size: options.size, to: pdf)
            } else {
                try LabelWriter.writePDF(labels, size: options.size, to: pdf)
            }
        } catch { throw CLIError("\(error)") }
        file.pdf = pdf.path

        if kind == .preview || (ctx.inv["out"] != nil && !sends && !ctx.inv.has("dry-run")) {
            ctx.say("  \(s.arrow) \(tilde(pdf.path))")
            for p in file.pages.compactMap(\.png) { ctx.say("    \(s.dim(tilde(p)))") }
        }
        guard let printer, kind != .preview else { return file }
        let args = LabelPrint.lpArguments(file: pdf, printer: printer.name, size: options.size, copies: copies)
        file.lp = ["lp"] + args
        if sends {
            do {
                let id = try LabelPrint.send(file: pdf, printer: printer.name, size: options.size, copies: copies)
                file.job = id
                ctx.say("  \(s.ok) \(s.green("Sent to \(printer.model)")) \(s.dim(id))")
            } catch {
                throw CLIError("printing failed on \(printer.name): \(error)",
                               hint: "`\(ctx.tool) doctor` checks the printer and CUPS.", code: .printer)
            }
        } else {
            let shown = (["lp"] + args).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
            ctx.say("  \(s.arrow) \(s.dim("dry run, would run:")) \(shown)")
        }
        return file
    }

    private func writeSource(_ page: SourcePage, size: LabelSize, to url: URL) throws {
        var box = CGRect(origin: .zero, size: size.points)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CLIError("can't write \(tilde(url.path))") }
        pdf.beginPDFPage(nil)
        page.draw(in: pdf)
        pdf.endPDFPage()
        pdf.closePDF()
    }
}

/// An error already reported; only the exit code is left.
struct ExitOnly: Error { var code: ExitCode }

private func round3(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
