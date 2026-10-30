import CoreGraphics
import Foundation
import PeelGoodCLI
import LabelKit
import PeelGoodCore

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
    let printers = ctx.defaults.printers()
    if ctx.inv.has("names") {
        printers.forEach { print($0.name) }
        return .ok
    }
    let used = try? ctx.choosePrinter(printers, required: false)
    let rows = printers.map { p in
        PrinterRow(name: p.name, model: p.displayName, state: p.state.rawValue, isDefault: p.isDefault, isLabelPrinter: p.isLabelPrinter,
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
    let modelWidth = min(28, printers.map(\.displayName.count).max()! + 2)
    for (p, row) in zip(printers, rows) {
        let bullet = row.usedByDefault ? s.green("●") : s.dim("○")
        let state: String = switch p.state {
        case .idle: s.green("idle")
        case .printing: s.cyan("printing")
        case .stopped: s.red(p.problem ?? "paused")
        case .unknown: s.dim("unknown")
        }
        var tags: [String] = []
        if p.isLabelPrinter { tags.append("label printer") }
        if row.chosenInApp { tags.append("chosen in the app") }
        if ctx.defaults.hiddenPrinters.contains(p.name) { tags.append("hidden in the app") }
        if p.isDefault { tags.append("system default") }
        let model = String(p.displayName.prefix(modelWidth - 2)).padding(toLength: modelWidth, withPad: " ", startingAt: 0)
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
    let printers = ctx.defaults.printers()
    var inv = ctx.inv
    if let name = inv.arguments.first { inv.values["printer"] = name }
    let scoped = Context(inv: inv, out: ctx.out, err: ctx.err, defaults: ctx.defaults, tool: ctx.tool, environment: ctx.environment)
    guard let (p, _) = try scoped.choosePrinter(printers, required: true) else { return .printer }
    // The size the app really prints at: the saved one, else 4x6, or 4x6 when the printer can't take the saved one.
    let app = ctx.defaults.options(for: p)
    let appSize = app.options.size
    let entries = SizeCatalog.entries(for: p)
    if inv.has("names") {
        entries.filter(\.isSupported).forEach { print($0.size.description) }
        return .ok
    }
    let rows = entries.map { e in
        SizeRow(size: e.size.description, media: e.size.cupsMedia, source: e.source.rawValue, supported: e.isSupported,
                reason: e.unsupportedReason, appDefault: appSize.matches(e.size))
    }
    if ctx.json { ctx.emit(["printer": AnyEncodable(p.name), "sizes": AnyEncodable(rows)]); return .ok }
    let s = ctx.out
    ctx.say("\(s.bold(p.displayName)) \(s.dim("(\(p.name))"))")
    if let lo = p.customMin, let hi = p.customMax { ctx.say(s.dim("  takes custom sizes from \(lo.primary) to \(hi.primary)")) }
    if let note = app.note { ctx.say("  \(s.warn) \(s.yellow(note))") }
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
    History.entries(in: ctx.historyFolder).map { HistoryRow(name: $0.name, date: $0.date, labels: $0.labels, path: $0.url.path) }
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
        ctx.say("\(s.dim("No prints yet. Labels printed by the app or `\(ctx.tool) print` show up here."))")
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
