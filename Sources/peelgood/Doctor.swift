import AppKit
import Foundation
import LabelizeCLI
import LabelKit

/// `peelgood doctor`: read-only checks, each with what to do about it.
struct Doctor {
    struct Check: Encodable {
        enum Status: String, Encodable { case ok, warning, failed, info }
        var area: String
        var status: Status
        var message: String
        var fix: String?
    }

    let ctx: Context
    static let bundleID = "com.fermiumlabs.labelize"

    func run() -> ExitCode {
        var checks: [Check] = []
        func add(_ area: String, _ status: Check.Status, _ message: String, fix: String? = nil) {
            checks.append(Check(area: area, status: status, message: message, fix: fix))
        }

        // CUPS
        let scheduler = run("/usr/bin/lpstat", ["-r"])
        if scheduler.contains("is running") { add("CUPS", .ok, "Print system is running") }
        else { add("CUPS", .failed, "Print system isn't answering", fix: "Restart the Mac, or reset printing in System Settings > Printers & Scanners.") }

        // Printers
        let printers = Printers.all()
        let labelPrinters = printers.filter(\.isLabelPrinter)
        if printers.isEmpty {
            add("Printers", .failed, "No printers on this Mac", fix: "Add one in System Settings > Printers & Scanners.")
        } else {
            add("Printers", labelPrinters.isEmpty ? .warning : .ok,
                "\(printers.count) printer\(printers.count == 1 ? "" : "s"), \(labelPrinters.count) label printer\(labelPrinters.count == 1 ? "" : "s")",
                fix: labelPrinters.isEmpty ? "Labels go to any printer that takes 4x6, but a thermal label printer works best." : nil)
        }
        if let appPrinter = ctx.defaults.printerName, !printers.contains(where: { $0.name == appPrinter }) {
            add("Printers", .warning, "The app's printer \(appPrinter) isn't installed", fix: "Choose another in Peel Good Inc. > Settings > Printers.")
        }
        if let (p, from) = try? ctx.choosePrinter(printers, required: false) {
            let source = from == "app" ? "chosen in the app" : from
            switch p.state {
            case .stopped:
                add("Printers", .failed, "\(p.name) is paused", fix: "Resume it in System Settings > Printers & Scanners, or run: cupsenable \(p.name)")
            default:
                add("Printers", .ok, "Default: \(p.model) (\(p.name), \(source)), \(p.state.rawValue)")
            }
            let size = ctx.defaults.options(for: p.name).options.size
            if p.resolve(size) == nil {
                add("Printers", .warning, "\(p.name) can't take the app's size \(size.display)", fix: "Pick a size in Settings > Printers.")
            }
        } else if !printers.isEmpty {
            add("Printers", .warning, "No default label printer", fix: "Pass --printer, or set LABELIZE_PRINTER.")
        }

        // App
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)
        if let appURL {
            let version = (NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "?"
            add("App", .ok, "Peel Good Inc. \(version) at \(tilde(appURL.path))")
        } else {
            add("App", .warning, "Peel Good Inc. isn't installed", fix: "brew install --cask fermium/tap/peel-good-inc")
        }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        add("App", running ? .ok : .info, running ? "App is running" : "App isn't running",
            fix: running ? nil : "The command works on its own. Open the app for rules, watched folders and the API.")
        if ctx.defaults.source == "none" {
            add("App", .info, "Not reading the app's settings (PEELGOOD_DEFAULTS_DOMAIN=none)")
        } else if ctx.defaults.printerName != nil || ctx.defaults.string("size.\(ctx.defaults.printerName ?? "")") != nil {
            add("App", .ok, "Using the app's settings for defaults")
        }

        // API and MCP
        let serverInfo = ctx.supportFolder.appendingPathComponent("server.json")
        if let data = try? Data(contentsOf: serverInfo),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let port = info["port"] as? Int {
            let pid = (info["pid"] as? NSNumber)?.int32Value ?? 0
            let alive = pid > 0 && kill(pid, 0) == 0
            let http = info["http"] as? Bool ?? false, mcp = info["mcp"] as? Bool ?? false
            if !alive {
                add("API", .info, "API is off (the app isn't running)")
            } else if health(port: port) {
                let on = [http ? "HTTP API" : nil, mcp ? "MCP" : nil].compactMap { $0 }
                add("API", .ok, "\(on.isEmpty ? "Server" : on.joined(separator: " and ")) answering on 127.0.0.1:\(port)")
                if !mcp { add("API", .info, "MCP server is off", fix: "Turn it on in Settings > API.") }
            } else {
                add("API", .warning, "Nothing answers on 127.0.0.1:\(port)", fix: "Check Settings > API > Advanced > Status.")
            }
        } else {
            add("API", .info, "API and MCP are off", fix: running ? "Turn them on in Settings > API." : nil)
        }
        if let appURL {
            let relay = appURL.appendingPathComponent("Contents/MacOS/peel-good-mcp")
            if FileManager.default.isExecutableFile(atPath: relay.path) { add("API", .ok, "MCP relay for Claude Desktop at \(tilde(relay.path))") }
        }

        // Command line
        let me = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        for name in Manual.names {
            let found = which(name)
            if let found {
                let target = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
                add("Command", .ok, "\(name) is \(tilde(found))" + (target != found ? " \(ctx.out.dim("→ \(tilde(target))"))" : ""))
            } else if name == Manual.tool {
                add("Command", .warning, "\(name) isn't on your PATH" + (me.map { " (running \(tilde($0)))" } ?? ""),
                    fix: "Peel Good Inc. > Settings > CLI > Install Command.")
            } else {
                add("Command", .info, "Short name \(name) isn't installed", fix: "Settings > CLI installs it with peelgood.")
            }
        }
        let man = run("/usr/bin/man", ["-w", Manual.tool]).trimmingCharacters(in: .whitespacesAndNewlines)
        add("Command", man.isEmpty ? .info : .ok, man.isEmpty ? "No man page installed" : "Man page at \(tilde(man))",
            fix: man.isEmpty ? "`\(ctx.tool) help` has the same text." : nil)

        // Data
        let history = (try? FileManager.default.contentsOfDirectory(atPath: ctx.historyFolder.path))?.count ?? 0
        add("Data", .ok, "\(tilde(ctx.supportFolder.path)), \(history) label\(history == 1 ? "" : "s") in History")

        if ctx.json {
            ctx.emit(["checks": AnyEncodable(checks), "ok": AnyEncodable(!checks.contains { $0.status == .failed })])
        } else {
            let s = ctx.out
            var area = ""
            for c in checks {
                if c.area != area { area = c.area; print(s.bold(area)) }
                let mark: String = switch c.status {
                case .ok: s.ok
                case .warning: s.warn
                case .failed: s.fail
                case .info: s.dim("–")
                }
                print("  \(mark) \(c.message)")
                if let fix = c.fix, c.status != .ok { print("    \(s.dim(fix))") }
            }
            let failed = checks.filter { $0.status == .failed }.count, warned = checks.filter { $0.status == .warning }.count
            print()
            print(failed + warned == 0 ? "\(s.ok) All good." : "\(failed > 0 ? s.fail : s.warn) \(failed) problem\(failed == 1 ? "" : "s"), \(warned) warning\(warned == 1 ? "" : "s").")
        }
        return checks.contains { $0.status == .failed } ? .unhealthy : .ok
    }

    /// GET /v1/health with the app's token, a second at most.
    private func health(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        if let token = try? String(contentsOf: ctx.supportFolder.appendingPathComponent("token"), encoding: .utf8) {
            request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 2)
        return ok
    }

    private func which(_ name: String) -> String? {
        let path = ctx.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
