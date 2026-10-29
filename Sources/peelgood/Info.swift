import CoreGraphics
import Foundation
import LabelizeCLI
import LabelKit

// printers, sizes, history and version.

struct PrinterRow: Encodable {
    var name: String
    var model: String
    var state: String
    var isDefault: Bool
    var isLabelPrinter: Bool
    var chosenInApp: Bool
    var usedByDefault: Bool
    var presets: [String]
}

func listPrinters(_ ctx: Context) throws -> ExitCode {
    let printers = Printers.all()
    if ctx.inv.has("names") {
        printers.forEach { print($0.name) }
        return .ok
    }
    let used = try? ctx.choosePrinter(printers, required: false)
    let rows = printers.map { p in
        PrinterRow(name: p.name, model: p.model, state: p.state.rawValue, isDefault: p.isDefault, isLabelPrinter: p.isLabelPrinter,
                   chosenInApp: ctx.defaults.printerName == p.name, usedByDefault: used?.0.name == p.name,
                   presets: p.presets.map(\.description))
    }
    if ctx.json { ctx.emit(rows); return .ok }
    let s = ctx.out
    guard !printers.isEmpty else {
        ctx.say("\(s.warn) No printers on this Mac. Add one in System Settings > Printers & Scanners.")
        return .printer
    }
    let width = printers.map(\.name.count).max()! + 2
    let modelWidth = min(28, printers.map(\.model.count).max()! + 2)
    for (p, row) in zip(printers, rows) {
        let bullet = row.usedByDefault ? s.green("●") : s.dim("○")
        let state: String = switch p.state {
        case .idle: s.green("idle")
        case .printing: s.cyan("printing")
        case .stopped: s.red("paused")
        case .unknown: s.dim("unknown")
        }
        var tags: [String] = []
        if p.isLabelPrinter { tags.append("label printer") }
        if row.chosenInApp { tags.append("chosen in the app") }
        if p.isDefault { tags.append("system default") }
        let model = String(p.model.prefix(modelWidth - 2)).padding(toLength: modelWidth, withPad: " ", startingAt: 0)
        ctx.say("\(bullet) \(s.bold(p.name.padding(toLength: width, withPad: " ", startingAt: 0)))\(model)\(state)"
            + (tags.isEmpty ? "" : "  \(s.dim(tags.joined(separator: ", ")))"))
    }
    if let used {
        ctx.say("\n\(s.dim("● is used when you don't pass --printer (\(used.1 == "app" ? "chosen in the app" : used.1))."))")
    }
    return .ok
}

struct SizeRow: Encodable {
    var size: String
    var media: String
    var source: String
    var supported: Bool
    var reason: String?
    var appDefault: Bool
}

func listSizes(_ ctx: Context) throws -> ExitCode {
    let printers = Printers.all()
    var inv = ctx.inv
    if let name = inv.arguments.first { inv.values["printer"] = name }
    let scoped = Context(inv: inv, out: ctx.out, err: ctx.err, defaults: ctx.defaults, tool: ctx.tool, environment: ctx.environment)
    guard let (p, _) = try scoped.choosePrinter(printers, required: true) else { return .printer }
    let appSize = ctx.defaults.string("size.\(p.name)").flatMap(LabelSize.init(parsing:))
    let entries = SizeCatalog.entries(for: p)
    if inv.has("names") {
        entries.filter(\.isSupported).forEach { print($0.size.description) }
        return .ok
    }
    let rows = entries.map { e in
        SizeRow(size: e.size.description, media: e.size.cupsMedia, source: e.source.rawValue, supported: e.isSupported,
                reason: e.unsupportedReason, appDefault: appSize.map { $0.matches(e.size) } ?? false)
    }
    if ctx.json { ctx.emit(["printer": AnyEncodable(p.name), "sizes": AnyEncodable(rows)]); return .ok }
    let s = ctx.out
    ctx.say("\(s.bold(p.model)) \(s.dim("(\(p.name))"))")
    if let lo = p.customMin, let hi = p.customMax { ctx.say(s.dim("  takes custom sizes from \(lo.display) to \(hi.display)")) }
    for (e, row) in zip(entries, rows) {
        let mark = e.isSupported ? s.ok : s.fail
        let size = e.size.description.padding(toLength: 11, withPad: " ", startingAt: 0)
        let detail = e.unsupportedReason ?? (e.source == .printer ? "preset \(e.size.cupsMedia)" : "custom")
        ctx.say("  \(mark) \(e.isSupported ? size : s.dim(size))\(s.dim(detail))\(row.appDefault ? "  " + s.green("used by the app") : "")")
    }
    return .ok
}

struct AnyEncodable: Encodable {
    let encodeTo: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeTo = value.encode }
    func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
}

// MARK: History

struct HistoryRow: Encodable {
    var name: String
    var date: Date
    var labels: Int
    var path: String
}

func historyRows(_ ctx: Context) -> [HistoryRow] {
    let keys: [URLResourceKey] = [.creationDateKey]
    let files = (try? FileManager.default.contentsOfDirectory(at: ctx.historyFolder, includingPropertiesForKeys: keys)) ?? []
    let stamp = try! Regex(#"^(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(?:\.\d+)?Z)\s+"#)
    let parser = ISO8601DateFormatter()
    return files.filter { $0.pathExtension.lowercased() == "pdf" }.map { url in
        var name = url.deletingPathExtension().lastPathComponent
        var date = (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
        if let m = name.prefixMatch(of: stamp), let s = m.output[1].substring {
            let iso = String(s).replacingOccurrences(of: #"T(\d{2})-(\d{2})-(\d{2})"#, with: "T$1:$2:$3", options: .regularExpression)
            date = parser.date(from: iso) ?? date
        }
        while let m = name.prefixMatch(of: stamp) { name.removeSubrange(m.range) }
        while name.hasSuffix(".label") { name.removeLast(".label".count) }
        let pages = CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
        return HistoryRow(name: name.isEmpty ? "label" : name, date: date, labels: pages, path: url.path)
    }.sorted { $0.date > $1.date }
}

func listHistory(_ ctx: Context) throws -> ExitCode {
    var limit = 10
    if let v = ctx.inv["limit"] {
        guard let n = Int(v), n > 0 else { throw CLIError.usage("--limit needs a whole number, like 10") }
        limit = n
    }
    let all = historyRows(ctx)
    let rows = Array(all.prefix(limit))
    if ctx.inv.has("paths") { rows.forEach { print($0.path) }; return .ok }
    if ctx.json { ctx.emit(rows); return .ok }
    let s = ctx.out
    guard !rows.isEmpty else {
        ctx.say("\(s.dim("No prints yet. Labels printed by the app show up here."))")
        return .ok
    }
    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .short
    let whenWidth = rows.map { relative.localizedString(for: $0.date, relativeTo: Date()).count }.max()! + 2
    for r in rows {
        let when = relative.localizedString(for: r.date, relativeTo: Date())
        let count = r.labels == 1 ? "1 label" : "\(r.labels) labels"
        ctx.say("  \(s.dim(when.padding(toLength: whenWidth, withPad: " ", startingAt: 0)))\(s.bold(r.name))  \(s.dim(count))")
        if ctx.verbose { ctx.say("  " + String(repeating: " ", count: whenWidth) + s.dim(tilde(r.path))) }
    }
    if all.count > rows.count { ctx.say(s.dim("\n  \(all.count - rows.count) more. Use -n to show more.")) }
    return .ok
}

// MARK: Version

struct VersionInfo: Encodable {
    var version: String
    var build: String?
    var executable: String?
    var app: String?
    var inks: [String]
}

func showVersion(_ ctx: Context) -> ExitCode {
    let v = Context.version
    let info = VersionInfo(version: v.short, build: v.build, executable: Bundle.main.executableURL?.resolvingSymlinksInPath().path,
                           app: Context.enclosingApp?.path, inks: InkMode.allCases.map(\.rawValue))
    if ctx.json { ctx.emit(info); return .ok }
    print("\(ctx.tool) \(v.short)" + (v.build.map { " (\($0))" } ?? ""))
    return .ok
}
