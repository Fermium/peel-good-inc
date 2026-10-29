import CoreGraphics
import Foundation
import LabelKit

let usage = """
usage: labelize [options] <file.pdf|svg|png|jpg>...
       labelize --list-printers
       labelize --list-sizes [--printer NAME]

  --printer NAME     printer queue (default: your label printer)
  --size WxH         label size in inches, or e.g. 100x150mm (default 4x6)
  --fit fit|fill     fit shows everything; fill covers the label (default fit)
  --crop auto|content|none   (default auto: find the label or code on the page)
  --pad MM           padding around the crop (default 2)
  --rotate auto|none|cw|ccw  (default auto)
  --ink auto|crisp|photo     (default auto)
  --cutoff 0-100     black/white cutoff in percent (default 50)
  --nudge X,Y        shift in mm, +x right, +y down
  --no-snap          don't fit codes to the printer's dot grid
  --test-label       use a calibration pattern as the input
  --copies N
  --out DIR          output folder (default ./out)
  --print            send to the printer
  --dry-run          show the print command without sending
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("labelize: \(message)\n".utf8))
    exit(1)
}

func inches(_ v: CGFloat) -> String { String(format: "%.2f", v / 72) }

var options = LabelOptions()
var files: [URL] = []
var printerName: String?
var copies = 1
var outDir = URL(fileURLWithPath: "out")
var shouldPrint = false
var dryRun = false
var listPrinters = false
var listSizes = false
var testLabel = false

var args = CommandLine.arguments.dropFirst()
func value(_ flag: String) -> String {
    guard let v = args.popFirst() else { fail("\(flag) needs a value") }
    return v
}
func number(_ flag: String) -> Double {
    guard let n = Double(value(flag)) else { fail("\(flag) needs a number") }
    return n
}
func choice<T: RawRepresentable & CaseIterable>(_ flag: String, _: T.Type) -> T where T.RawValue == String {
    let v = value(flag)
    guard let c = T(rawValue: v) else { fail("\(flag) must be one of \(T.allCases.map(\.rawValue).joined(separator: "|"))") }
    return c
}

while let arg = args.popFirst() {
    switch arg {
    case "-h", "--help": print(usage); exit(0)
    case "--list-printers": listPrinters = true
    case "--list-sizes": listSizes = true
    case "--printer": printerName = value(arg)
    case "--size":
        let v = value(arg)
        guard let size = LabelSize(parsing: v) else { fail("can't read size \(v)") }
        options.size = size
    case "--fit": options.fit = choice(arg, FitMode.self)
    case "--crop": options.crop = choice(arg, CropMode.self)
    case "--rotate": options.rotation = choice(arg, RotationMode.self)
    case "--ink": options.ink = choice(arg, InkMode.self)
    case "--pad": options.paddingMM = number(arg)
    case "--cutoff": options.cutoff = number(arg) / 100
    case "--nudge":
        let parts = value(arg).split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { fail("--nudge needs X,Y") }
        options.nudgeMM = CGPoint(x: parts[0], y: parts[1])
    case "--no-snap": options.snapCodes = false
    case "--copies": copies = max(1, Int(number(arg)))
    case "--out": outDir = URL(fileURLWithPath: value(arg))
    case "--print": shouldPrint = true
    case "--dry-run": dryRun = true
    case "--test-label": testLabel = true
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)\n\n\(usage)") }
        files.append(URL(fileURLWithPath: arg))
    }
}

let printers = Printers.all()
func selectedPrinter() -> PrinterInfo? {
    if let printerName {
        guard let p = printers.first(where: { $0.name == printerName }) else {
            fail("no printer named \(printerName). Try --list-printers.")
        }
        return p
    }
    return Printers.defaultLabelPrinter(in: printers)
}

if listPrinters {
    for p in printers {
        let tags = [p.isDefault ? "default" : nil, p.isLabelPrinter ? "label printer" : nil].compactMap { $0 }
        print("\(p.name)  [\(p.state.rawValue)]  \(p.makeAndModel)\(tags.isEmpty ? "" : "  (\(tags.joined(separator: ", ")))")")
    }
    exit(0)
}

if listSizes {
    guard let p = selectedPrinter() else { fail("no label printer found. Pass --printer.") }
    print("\(p.name)")
    if let lo = p.customMin, let hi = p.customMax { print("custom range \(lo) to \(hi) in") }
    for e in SizeCatalog.entries(for: p) {
        let mark = e.isSupported ? "✓" : "✗"
        let detail = e.unsupportedReason ?? (e.source == .printer ? "preset \(e.size.cupsMedia)" : "custom \(e.size.cupsMedia)")
        print("  \(mark) \(e.size.description.padding(toLength: 10, withPad: " ", startingAt: 0)) \(detail)")
    }
    exit(0)
}

guard !files.isEmpty || testLabel else { print(usage); exit(1) }

// Resolve the size against the printer so presets use the printer's own media name.
let printer = selectedPrinter()
if let printer {
    guard let resolved = printer.resolve(options.size) else {
        fail("\(printer.name) can't print \(options.size). Try --list-sizes.")
    }
    options.size = resolved
} else if shouldPrint || dryRun {
    fail("no label printer found. Pass --printer.")
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

if testLabel {
    let url = outDir.appendingPathComponent("test-\(options.size).pdf")
    let page = TestPattern.page(size: options.size, title: "\(printer?.makeAndModel.replacingOccurrences(of: "-AirPrint", with: "") ?? "Labelize") · \(options.size) in")
    var box = CGRect(origin: .zero, size: options.size.points)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { fail("can't write \(url.path)") }
    ctx.beginPDFPage(nil)
    page.draw(in: ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    files.insert(url, at: 0)
    options.crop = .none
    options.ink = .crisp
}

for file in files {
    let pages: [SourcePage]
    do { pages = try DocumentLoader.load(file) } catch { fail("\(error)") }

    let base = file.deletingPathExtension().lastPathComponent
    print("\(file.lastPathComponent): \(pages.count) page(s) → \(options.size) in")
    var labels: [ComposedLabel] = []
    for (i, page) in pages.enumerated() {
        let label = LabelComposer.compose(page, options)
        let c = label.crop.rect
        labels.append(label)
        print("  page \(i + 1): \(inches(page.size.width))x\(inches(page.size.height)) in, crop \(inches(c.width))x\(inches(c.height)) at (\(inches(c.minX)), \(inches(c.minY))): \(label.crop.reason)")
        print("          \(label.rotated ? "rotated, " : "")scale \(Int((label.scale * 100).rounded()))%, ink \(label.ink.rawValue) (smooth gray \(String(format: "%.1f", label.smoothGray * 100))%), 1-dot features \(label.oneDotFeatures)")
        if !label.expectedCodes.isEmpty {
            let ok = label.expectedCodes.count - label.missingCodes.count
            let kinds = label.expectedCodes.map(\.symbology).joined(separator: ", ")
            print("          codes: \(ok)/\(label.expectedCodes.count) scan after conversion (\(kinds))")
        }
        for d in CodeAnalysis.analyze(label, dpi: options.dpi) {
            let hist = d.runs.sorted { $0.key < $1.key }.prefix(12).map { "\($0.key):\($0.value)" }.joined(separator: " ")
            print("          \(d.symbology) \(d.picketFence ? "picket" : "LADDER") · module ≈ \(String(format: "%.2f", d.moduleDots)) dots · runs(dots:count) \(hist)")
        }
        for r in label.codeReports {
            print("          \(r.symbology) fit · \(String(format: "%.2f", r.moduleDots)) dots/module\(r.redrawn ? ", redrawn" : "")\(r.picketFence ? "" : ", ladder") · \(r.severity)")
        }
        for w in label.warnings { print("          ⚠️  \(w)") }
        let png = outDir.appendingPathComponent("\(base)-p\(i + 1).png")
        do { try LabelWriter.writePNG(label, to: png) } catch { fail("\(error)") }
    }

    let pdf = outDir.appendingPathComponent("\(base).label.pdf")
    do { try LabelWriter.writePDF(labels, size: options.size, to: pdf) } catch { fail("\(error)") }
    print("  wrote \(pdf.path) and \(labels.count) preview(s)")

    if let printer, shouldPrint || dryRun {
        let lpArgs = LabelPrint.lpArguments(file: pdf, printer: printer.name, size: options.size, copies: copies)
        if dryRun {
            print("  would run: lp \(lpArgs.joined(separator: " "))")
        } else {
            do { print("  " + (try LabelPrint.send(file: pdf, printer: printer.name, size: options.size, copies: copies))) }
            catch { fail("\(error)") }
        }
    }
}
