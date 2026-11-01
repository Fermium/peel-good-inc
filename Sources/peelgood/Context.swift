import Foundation
import PeelGoodCLI
import PeelGoodCore
import LabelKit
import PeelGoodShared

/// What every command gets: the parsed line, output styles, the app's defaults and paths.
struct Context {
    let inv: Invocation
    let out: Style
    let err: Style
    /// The app's settings, read only (only Reprint Last Label is ever written, by `LabelRun`).
    let defaults: AppSettings
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
        if let data = try? encoder.encode(value) { JSONStdout.write(data + Data("\n".utf8)) }
    }

    // MARK: Paths

    /// The app's data folder (`AppPaths`, which honours PEELGOOD_SUPPORT_DIR).
    var supportFolder: URL { AppPaths.support }
    var historyFolder: URL { AppPaths.history }

    // MARK: Printers

    func resolver(_ printers: [PrinterInfo]) -> PrinterResolver { PrinterResolver(printers: printers, settings: defaults) }

    /// The name asked for: --printer, then PEELGOOD_PRINTER.
    var requestedPrinter: (name: String, from: String)? {
        if let name = inv["printer"] { return (name, "--printer") }
        if let name = environment["PEELGOOD_PRINTER"], !name.isEmpty { return (name, "PEELGOOD_PRINTER") }
        return nil
    }

    /// --printer, then PEELGOOD_PRINTER, matched like the app and the API do (`PrinterResolver`); then the
    /// app's default: its chosen printer, the label printer, or the first that takes 4x6. Hidden printers
    /// are never picked by default.
    func choosePrinter(_ printers: [PrinterInfo], required: Bool) throws -> (PrinterInfo, String)? {
        let resolver = resolver(printers)
        if let (name, from) = requestedPrinter {
            if let p = resolver.find(name) { return (p, from) }
            if let host = Printers.zebraHost(name) {
                do { return (try Printers.zebra(host: host), from) } catch {
                    throw CLIError("\(error)", hint: "Is the printer on and connected?", code: .printer)
                }
            }
            let near = Parser.closest(name, among: printers.map(\.name)) ?? resolver.candidates(name).first?.name
            throw CLIError("no printer named \(name)",
                           hint: near.map { "Did you mean \($0)? `\(tool) printers` lists them." } ?? "`\(tool) printers` lists them.", code: .printer)
        }
        if let choice = resolver.defaultChoice { return (choice.printer, choice.source.rawValue) }
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

/// `~/x` for paths in the home folder.
func tilde(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

func inches(_ v: CGFloat) -> String { String(format: "%.2f", v / 72) }

/// Keeps the real stdout for the JSON result and points fd 1 at stderr in the meantime.
enum JSONStdout {
    nonisolated(unsafe) private static var saved: Int32 = -1

    static func capture() {
        fflush(stdout)
        saved = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
    }

    static func write(_ data: Data) {
        fflush(stdout)
        let fd = saved >= 0 ? saved : STDOUT_FILENO
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }
}
