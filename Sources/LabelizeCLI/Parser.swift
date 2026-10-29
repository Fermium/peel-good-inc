import Foundation

/// A failure with something to try next. `code` becomes the exit status.
public struct CLIError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var hint: String?
    public var code: ExitCode

    public init(_ message: String, hint: String? = nil, code: ExitCode = .failure) {
        self.message = message
        self.hint = hint
        self.code = code
    }

    public static func usage(_ message: String, hint: String? = nil) -> CLIError { CLIError(message, hint: hint, code: .usage) }

    public var description: String { hint.map { "\(message)\n\($0)" } ?? message }
}

public struct GlobalFlags: Equatable, Sendable {
    public var json = false
    public var verbose = false
    public var quiet = false
    public var noColor = false
    public var help = false
    public init() {}
}

/// A parsed command line: a command, its arguments and its options by long name.
public struct Invocation: Equatable {
    public var command: String
    public var arguments: [String] = []
    /// Options with values, by long name. The last one given wins.
    public var values: [String: String] = [:]
    /// Flags that were given, by long name.
    public var flags: Set<String> = []
    public var global = GlobalFlags()
    /// Set when the old flag-only form was used: what to type instead.
    public var legacyHint: String?

    public init(command: String, arguments: [String] = [], values: [String: String] = [:], flags: Set<String> = []) {
        self.command = command
        self.arguments = arguments
        self.values = values
        self.flags = flags
    }

    public func has(_ flag: String) -> Bool { flags.contains(flag) }
    public subscript(_ option: String) -> String? { values[option] }
}

public enum Parser {
    /// Parses arguments without the program name. `fileExists` decides whether an unknown first
    /// word is a file (the old form, `labelize label.pdf`) or a mistyped command.
    public static func parse(_ args: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> Invocation {
        // No arguments, or only global flags: the overview.
        let globalNames = Set(Manual.globalOptions.flatMap { ["--\($0.name)"] + ($0.short.map { ["-\($0)"] } ?? []) })
        guard let first = args.first(where: { !globalNames.contains($0) }) else {
            var inv = try parse(command: Manual.command("help")!, args)
            inv.global.help = false
            return inv
        }
        if first == "-V" || first == "--version" {
            return try parse(command: Manual.command("version")!, args.filter { $0 != first })
        }
        if let command = Manual.command(first) {
            var rest = args
            rest.remove(at: args.firstIndex(of: first)!)
            var inv = try parse(command: command, rest)
            if inv.global.help, inv.command != "help" {
                inv = Invocation(command: "help", arguments: [inv.command])
            }
            return inv
        }
        if Legacy.looksLegacy(args, first: first, fileExists: fileExists) {
            let (translated, hint) = Legacy.translate(args)
            var inv = try parse(translated, fileExists: { _ in false })
            inv.legacyHint = hint
            return inv
        }
        if first.hasPrefix("-") {
            throw CLIError.usage("unknown option \(first)", hint: suggestion(first, among: Manual.globalOptions.map { "--\($0.name)" })
                ?? "Run `labelize help` for commands.")
        }
        let names = Manual.visibleCommands.flatMap { [$0.name] + $0.aliases }
        if let near = closest(first, among: names) {
            throw CLIError.usage("unknown command \(first)", hint: "Did you mean `labelize \(near)`?")
        }
        throw CLIError.usage("no command or file named \(first)",
                             hint: "Commands: " + Manual.visibleCommands.map(\.name).joined(separator: ", ") + ". Run `labelize help` for more.")
    }

    /// Parses the words after the command name.
    public static func parse(command: CLICommand, _ args: [String]) throws -> Invocation {
        var inv = Invocation(command: command.name)
        var queue = ArraySlice(args)
        var onlyArguments = false
        let options = command.options + Manual.globalOptions

        while let word = queue.popFirst() {
            if onlyArguments || word == "-" || !word.hasPrefix("-") {
                inv.arguments.append(word)
                continue
            }
            if word == "--" { onlyArguments = true; continue }

            // --name=value, --name value, -x value, -xvalue
            var name = word, attached: String?
            if word.hasPrefix("--"), let eq = word.firstIndex(of: "=") {
                name = String(word[..<eq])
                attached = String(word[word.index(after: eq)...])
            }
            var option: CLIOption?
            if name.hasPrefix("--") {
                option = options.first { "--\($0.name)" == name }
            } else if name.count >= 2 {
                let letter = name[name.index(after: name.startIndex)]
                option = options.first { $0.short == letter }
                if option != nil, name.count > 2 {
                    if option!.takesValue { attached = String(name.dropFirst(2)) } else { option = nil }
                }
                // A negative number is an argument: `--nudge -1,0` is handled below, this is `labelize sizes -1`.
                if option == nil, Double(name) != nil { inv.arguments.append(word); continue }
            }
            guard let option else {
                let all = options.filter { !$0.hidden }.map { "--\($0.name)" }
                var hint = suggestion(name, among: all).map { $0 + " Or run `labelize help \(command.name)`." }
                if hint == nil, let owner = Manual.commands.first(where: { c in c.options.contains { "--\($0.name)" == name } }) {
                    hint = "\(name) belongs to `labelize \(owner.name)`."
                }
                throw CLIError.usage("\(command.name) has no option \(name)", hint: hint ?? "Run `labelize help \(command.name)` for its options.")
            }
            switch option.name {
            case "json": inv.global.json = true; continue
            case "verbose": inv.global.verbose = true; continue
            case "quiet": inv.global.quiet = true; continue
            case "no-color": inv.global.noColor = true; continue
            case "help": inv.global.help = true; continue
            default: break
            }
            if option.takesValue {
                guard let value = attached ?? queue.popFirst() else {
                    throw CLIError.usage("--\(option.name) needs a value (\(option.value!))", hint: option.help)
                }
                if !option.choices.isEmpty, !option.choices.contains(value) {
                    throw CLIError.usage("--\(option.name) can't be \(value)",
                                         hint: "Use " + list(option.choices) + "." + (closest(value, among: option.choices).map { " Did you mean \($0)?" } ?? ""))
                }
                inv.values[option.name] = value
            } else {
                if attached != nil { throw CLIError.usage("--\(option.name) doesn't take a value") }
                inv.flags.insert(option.name)
            }
        }
        if !inv.global.help { try checkArguments(command, inv.arguments) }
        return inv
    }

    private static func checkArguments(_ command: CLICommand, _ given: [String]) throws {
        let required = command.arguments.filter { !$0.optional }
        let variadic = command.arguments.contains(where: \.variadic)
        if given.count < required.count {
            let missing = required[given.count]
            let example = command.examples.first.map { "\n  \($0.command)" } ?? ""
            throw CLIError.usage("\(command.name) needs \(missing.variadic ? "at least one " : "a ")\(missing.name)",
                                 hint: "Usage: \(command.usage())" + (example.isEmpty ? "" : "\nFor example:" + example))
        }
        if !variadic, given.count > command.arguments.count {
            let extra = given[command.arguments.count]
            throw CLIError.usage("\(command.name) doesn't take \(extra)",
                                 hint: "Usage: \(command.usage())")
        }
        for (arg, value) in zip(command.arguments, given) where !arg.choices.isEmpty && !arg.choices.contains(value) {
            throw CLIError.usage("\(arg.name) can't be \(value)", hint: "Use " + list(arg.choices) + ".")
        }
    }

    // MARK: Suggestions

    static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " or " + items.last!
    }

    static func suggestion(_ word: String, among candidates: [String]) -> String? {
        closest(word, among: candidates).map { "Did you mean \($0)?" }
    }

    /// The candidate within a couple of edits, or one that starts with the word.
    public static func closest(_ word: String, among candidates: [String]) -> String? {
        let w = word.lowercased()
        let scored = candidates.map { ($0, distance(w, $0.lowercased())) }.sorted { $0.1 < $1.1 }
        if let best = scored.first, best.1 <= (w.count >= 4 ? 2 : 1) { return best.0 }
        let trimmed = w.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if trimmed.count >= 2, let prefix = candidates.first(where: { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-")).hasPrefix(trimmed) }) {
            return prefix
        }
        // A mistyped start of a long name: "Label_Printr" for "Label_Printer_ITPP941AP".
        if w.count >= 5, let start = candidates.first(where: { distance(w, String($0.lowercased().prefix(w.count + 1))) <= 1 }) {
            return start
        }
        return nil
    }

    /// Levenshtein distance.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let old = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : 1 + min(previous, row[j], row[j - 1])
                previous = old
            }
        }
        return row[b.count]
    }
}

/// The old flag-only command line (`labelize label.pdf --size 4x6 --print`), rewritten into the new one.
public enum Legacy {
    static let onlyLegacy: Set<String> = ["--print", "--list-printers", "--list-sizes", "--test-label", "--step-wedge"]

    static func looksLegacy(_ args: [String], first: String, fileExists: (String) -> Bool) -> Bool {
        if args.contains(where: onlyLegacy.contains) { return true }
        if first.hasPrefix("-") {
            return Manual.layout.contains { "--\($0.name)" == first || first.hasPrefix("--\($0.name)=") }
                || ["--copies", "--out", "--dry-run"].contains(first)
        }
        return fileExists(first) || looksLikeLabelFile(first)
    }

    static func looksLikeLabelFile(_ word: String) -> Bool {
        ["pdf", "svg", "png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"].contains((word as NSString).pathExtension.lowercased())
    }

    /// The new arguments and a one-line hint showing them.
    public static func translate(_ args: [String]) -> ([String], String) {
        var rest = args
        func take(_ flag: String) -> Bool {
            guard let i = rest.firstIndex(of: flag) else { return false }
            rest.remove(at: i)
            return true
        }
        func takeValue(_ flag: String) -> String? {
            if let i = rest.firstIndex(of: flag), i + 1 < rest.count {
                let v = rest[i + 1]
                rest.removeSubrange(i...(i + 1))
                return v
            }
            if let i = rest.firstIndex(where: { $0.hasPrefix(flag + "=") }) {
                let v = String(rest[i].dropFirst(flag.count + 1))
                rest.remove(at: i)
                return v
            }
            return nil
        }

        let send = take("--print"), dry = take("--dry-run")
        var translated: [String]
        if take("--list-printers") {
            translated = ["printers"] + rest.filter(isGlobal)
        } else if take("--list-sizes") {
            translated = ["sizes"] + (takeValue("--printer").map { [$0] } ?? []) + rest.filter(isGlobal)
        } else {
            let wedge = take("--step-wedge"), test = take("--test-label")
            if wedge || test {
                // Files given with --test-label were printed after it; the new commands make one label each.
                rest = dropFiles(rest)
                translated = [wedge ? "step-wedge" : "test-label"] + allowed(rest, for: wedge ? "step-wedge" : "test-label")
                if !send { translated.append("--dry-run") }
            } else {
                let name = send || dry ? "print" : "preview"
                translated = [name] + allowed(rest, for: name, keepArguments: true)
                if dry { translated.append("--dry-run") }
            }
            // The old default output folder.
            if !translated.contains("--out") && !translated.contains(where: { $0.hasPrefix("--out=") }) {
                translated += ["--out", "out"]
            }
        }
        let shown = translated.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        return (translated, "The flag-only form still works. Next time: labelize \(shown)")
    }

    private static func isGlobal(_ word: String) -> Bool {
        Manual.globalOptions.contains { "--\($0.name)" == word || $0.short.map { "-\($0)" } == word }
    }

    /// Drops plain arguments (files) but keeps option values.
    private static func dropFiles(_ args: [String]) -> [String] {
        var out: [String] = [], i = 0
        let valued = Set((Manual.layout + [Manual.copies, Manual.out]).filter(\.takesValue).map { "--\($0.name)" })
        while i < args.count {
            let a = args[i]
            if valued.contains(a), i + 1 < args.count { out += [a, args[i + 1]]; i += 2; continue }
            if a.hasPrefix("-") { out.append(a) }
            i += 1
        }
        return out
    }

    /// Keeps only the options the target command knows (the old form allowed --fit with --test-label).
    private static func allowed(_ args: [String], for name: String, keepArguments: Bool = false) -> [String] {
        guard let command = Manual.command(name) else { return args }
        let known = command.options + Manual.globalOptions
        var out: [String] = [], i = 0
        while i < args.count {
            let a = args[i], base = a.split(separator: "=", maxSplits: 1).first.map(String.init) ?? a
            let option = known.first { "--\($0.name)" == base || $0.short.map { "-\($0)" } == base }
            let skipValue = option == nil && Manual.layout.contains { "--\($0.name)" == base && $0.takesValue } && !a.contains("=")
            if keepArguments, !a.hasPrefix("-") || a == "-" {
                out.append(a)
            } else if option != nil {
                out.append(a)
                if option!.takesValue, !a.contains("="), i + 1 < args.count { out.append(args[i + 1]); i += 1 }
            }
            i += skipValue ? 2 : 1
        }
        return out
    }
}
