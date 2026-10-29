import Foundation
import LabelizeCLI
import LabelKit

/// What every command gets: the parsed line, output styles, the app's defaults and paths.
struct Context {
    let inv: Invocation
    let out: Style
    let err: Style
    let defaults: AppDefaults
    let tool: String
    let environment: [String: String]

    var json: Bool { inv.global.json }
    var quiet: Bool { inv.global.quiet || inv.global.json }
    var verbose: Bool { inv.global.verbose && !inv.global.json }

    /// Human output; nothing with --json or --quiet.
    func say(_ line: String = "") {
        guard !quiet else { return }
        print(line)
    }

    func note(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
    }

    // MARK: Paths

    var supportFolder: URL {
        if let dir = environment["LABELIZE_SUPPORT_DIR"], !dir.isEmpty { return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peel Good", isDirectory: true)
    }

    var historyFolder: URL { supportFolder.appendingPathComponent("History", isDirectory: true) }

    // MARK: Printers

    /// --printer, then LABELIZE_PRINTER, then the app's choice, then the system's label printer.
    func choosePrinter(_ printers: [PrinterInfo], required: Bool) throws -> (PrinterInfo, String)? {
        if let name = inv["printer"] ?? environment["LABELIZE_PRINTER"].flatMap({ $0.isEmpty ? nil : $0 }) {
            let from = inv["printer"] != nil ? "--printer" : "LABELIZE_PRINTER"
            if let p = printers.first(where: { $0.name == name }) ?? printers.first(where: { $0.name.lowercased() == name.lowercased() }) {
                return (p, from)
            }
            let matches = printers.filter { $0.name.localizedCaseInsensitiveContains(name) || $0.makeAndModel.localizedCaseInsensitiveContains(name) }
            if matches.count == 1 { return (matches[0], from) }
            let near = Parser.closest(name, among: printers.map(\.name)) ?? matches.first?.name
            throw CLIError("no printer named \(name)",
                           hint: near.map { "Did you mean \($0)? `\(tool) printers` lists them." } ?? "`\(tool) printers` lists them.", code: .printer)
        }
        if let name = defaults.printerName, let p = printers.first(where: { $0.name == name }), p.resolve(.fourBySix) != nil {
            return (p, "app")
        }
        if let p = Printers.defaultLabelPrinter(in: printers) { return (p, "label printer") }
        guard required else { return nil }
        throw CLIError(printers.isEmpty ? "no printers on this Mac" : "no label printer found",
                       hint: printers.isEmpty ? "Add one in System Settings > Printers & Scanners."
                                              : "Pass --printer NAME. `\(tool) printers` lists them.", code: .printer)
    }

    // MARK: Version

    /// The app bundle around this helper (Contents/Helpers/peelgood), if there is one.
    static var enclosingApp: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    static var version: (short: String, build: String?) {
        guard let app = enclosingApp, let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return ("dev", nil) }
        return (info["CFBundleShortVersionString"] as? String ?? "dev", info["CFBundleVersion"] as? String)
    }
}

extension LabelSize {
    /// "4×6 in"
    var display: String { description.replacingOccurrences(of: "x", with: "×") + " in" }
}

extension PrinterInfo {
    var model: String {
        let m = makeAndModel.replacingOccurrences(of: "-AirPrint", with: "")
        return m.isEmpty ? name.replacingOccurrences(of: "_", with: " ") : m
    }
}

/// `~/x` for paths in the home folder.
func tilde(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

func inches(_ v: CGFloat) -> String { String(format: "%.2f", v / 72) }
