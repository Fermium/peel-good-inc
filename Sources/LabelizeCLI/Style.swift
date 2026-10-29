import Foundation

/// ANSI styling, on only for a terminal. NO_COLOR and --no-color turn it off, CLICOLOR_FORCE on.
public struct Style: Sendable {
    public var enabled: Bool
    public var unicode: Bool

    public init(enabled: Bool, unicode: Bool = true) {
        self.enabled = enabled
        self.unicode = unicode
    }

    public static func detect(fd: Int32, noColor: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Style {
        let unicode = !(environment["LANG"] ?? "UTF-8").isEmpty
        if noColor || environment["NO_COLOR"].map({ !$0.isEmpty }) == true { return Style(enabled: false, unicode: unicode) }
        if let force = environment["CLICOLOR_FORCE"], force != "0", !force.isEmpty { return Style(enabled: true, unicode: unicode) }
        return Style(enabled: isatty(fd) == 1 && environment["TERM"] != "dumb", unicode: unicode)
    }

    public static let plain = Style(enabled: false)

    private func wrap(_ s: String, _ code: String) -> String { enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }

    public func bold(_ s: String) -> String { wrap(s, "1") }
    public func dim(_ s: String) -> String { wrap(s, "2") }
    public func green(_ s: String) -> String { wrap(s, "32") }
    public func yellow(_ s: String) -> String { wrap(s, "33") }
    public func red(_ s: String) -> String { wrap(s, "31") }
    public func cyan(_ s: String) -> String { wrap(s, "36") }
    /// The brand's peel orange, for the header.
    public func accent(_ s: String) -> String { wrap(s, "38;5;208") }

    public var ok: String { green(unicode ? "✓" : "ok") }
    public var warn: String { yellow(unicode ? "!" : "!") }
    public var fail: String { red(unicode ? "✗" : "x") }
    public var arrow: String { dim(unicode ? "→" : "->") }
    public var dot: String { dim(unicode ? "·" : "-") }
}

/// Text for `labelize help` and `labelize <command> --help`.
public enum Help {
    public static func overview(_ s: Style, tool: String = Manual.tool) -> String {
        var out = "\(s.bold(s.accent("Peel Good Inc."))) \(s.dim("prints any PDF, SVG or image as a thermal label."))\n\n"
        out += "\(s.bold("USAGE"))\n  \(tool) <command> [options]\n\n"
        let width = Manual.visibleCommands.map(\.name.count).max()! + 2
        for group in CLICommand.Group.allCases {
            let commands = Manual.visibleCommands.filter { $0.group == group }
            guard !commands.isEmpty else { continue }
            out += "\(s.bold(group.rawValue.uppercased()))\n"
            for c in commands {
                out += "  \(s.cyan(c.name.padding(toLength: width, withPad: " ", startingAt: 0)))\(c.summary)\n"
            }
            out += "\n"
        }
        out += "\(s.bold("FLAGS"))\n" + optionLines(Manual.globalOptions + [CLIOption("version", short: "V", help: "Show the version.")], s) + "\n"
        out += "\(s.bold("EXAMPLES"))\n"
        for e in [Manual.commands[0].examples[0], Manual.commands[1].examples[0], CLIExample("labelize doctor", "Check printers, the app and its API")] {
            out += "  \(s.dim("# " + e.comment))\n  $ \(e.command)\n"
        }
        out += "\n\(s.dim("Run `\(tool) help <command>` for its options, or `man labelize`."))\n"
        return out
    }

    public static func command(_ c: CLICommand, _ s: Style, tool: String = Manual.tool) -> String {
        var out = "\(s.bold(c.summary))\n"
        if !c.discussion.isEmpty { out += "\n" + wrap(c.discussion, indent: 0) + "\n" }
        out += "\n\(s.bold("USAGE"))\n  \(c.usage(tool: tool))\n"
        if !c.aliases.isEmpty { out += "\n\(s.bold("ALIASES"))\n  " + c.aliases.map { "\(tool) \($0)" }.joined(separator: ", ") + "\n" }
        if !c.arguments.isEmpty {
            out += "\n\(s.bold("ARGUMENTS"))\n"
            let width = c.arguments.map(\.signature.count).max()! + 3
            for a in c.arguments {
                out += "  " + a.signature.padding(toLength: width, withPad: " ", startingAt: 0) + a.help + "\n"
            }
        }
        if !c.visibleOptions.isEmpty { out += "\n\(s.bold("OPTIONS"))\n" + optionLines(c.visibleOptions, s) }
        out += "\n\(s.bold("FLAGS"))\n" + optionLines(Manual.globalOptions.filter { $0.name != "help" }, s)
        if !c.examples.isEmpty {
            out += "\n\(s.bold("EXAMPLES"))\n"
            for e in c.examples { out += "  \(s.dim("# " + e.comment))\n  $ \(e.command)\n" }
        }
        return out
    }

    static func optionLines(_ options: [CLIOption], _ s: Style) -> String {
        let width = max(22, options.map { $0.signature.count + ($0.short == nil ? 4 : 0) }.max()! + 2)
        return options.map { o in
            let sig = (o.short == nil ? "    " : "") + o.signature
            let help = wrap(o.help, indent: width + 2, width: 90).dropFirst(width + 2)
            return "  " + s.cyan(sig) + String(repeating: " ", count: max(1, width - sig.count)) + help + "\n"
        }.joined()
    }

    /// Word-wraps to `width` columns, indenting every line.
    static func wrap(_ text: String, indent: Int, width: Int = 80) -> String {
        var lines: [String] = [], line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, indent + line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        let pad = String(repeating: " ", count: indent)
        return lines.map { pad + $0 }.joined(separator: "\n")
    }
}
