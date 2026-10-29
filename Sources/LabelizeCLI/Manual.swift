import Foundation
import LabelKit
import LabelizeCore
import PeelGoodShared

/// One description of the command line, used everywhere: the parser, `--help`, shell
/// completions, the man page and the manual in Settings > CLI. Change a command here and
/// all of them follow.

public struct CLIOption: Sendable, Hashable {
    public enum Completion: Sendable, Hashable { case none, file, directory, printers, sizes, choices }

    public var name: String
    public var short: Character?
    /// Placeholder for the value ("WxH"); nil for a plain flag.
    public var value: String?
    public var help: String
    public var choices: [String]
    public var completion: Completion
    public var hidden: Bool

    public init(_ name: String, short: Character? = nil, value: String? = nil, help: String, choices: [String] = [],
                completion: Completion = .none, hidden: Bool = false) {
        self.name = name
        self.short = short
        self.value = value
        self.help = help
        self.choices = choices
        self.completion = choices.isEmpty ? completion : .choices
        self.hidden = hidden
    }

    public var takesValue: Bool { value != nil }

    /// "-s, --size WxH"
    public var signature: String {
        let long = "--\(name)" + (value.map { " \($0)" } ?? "")
        return short.map { "-\($0), \(long)" } ?? long
    }
}

public struct CLIArgument: Sendable, Hashable {
    public var name: String
    public var help: String
    public var variadic: Bool
    public var optional: Bool
    public var completion: CLIOption.Completion
    public var choices: [String]

    public init(_ name: String, help: String, variadic: Bool = false, optional: Bool = false,
                completion: CLIOption.Completion = .none, choices: [String] = []) {
        self.name = name
        self.help = help
        self.variadic = variadic
        self.optional = optional
        self.completion = choices.isEmpty ? completion : .choices
        self.choices = choices
    }

    /// "<file>…", "[printer]"
    public var signature: String {
        let core = "<\(name)>" + (variadic ? "…" : "")
        return optional ? "[\(core)]" : core
    }
}

public struct CLIExample: Sendable, Hashable {
    public var command: String
    public var comment: String
    public init(_ command: String, _ comment: String) {
        self.command = command
        self.comment = comment
    }
}

public struct CLICommand: Sendable, Hashable {
    public enum Group: String, Sendable, CaseIterable { case labels = "Labels", printers = "Printers", app = "App", shell = "Shell" }

    public var name: String
    public var aliases: [String]
    public var group: Group
    public var summary: String
    public var discussion: String
    public var arguments: [CLIArgument]
    public var options: [CLIOption]
    public var examples: [CLIExample]
    public var hidden: Bool

    public init(_ name: String, aliases: [String] = [], group: Group, summary: String, discussion: String = "",
                arguments: [CLIArgument] = [], options: [CLIOption] = [], examples: [CLIExample] = [], hidden: Bool = false) {
        self.name = name
        self.aliases = aliases
        self.group = group
        self.summary = summary
        self.discussion = discussion
        self.arguments = arguments
        self.options = options
        self.examples = examples
        self.hidden = hidden
    }

    /// "peelgood print [options] <file>…"
    public func usage(tool: String = Manual.tool) -> String {
        ([tool, name] + (options.contains { !$0.hidden } ? ["[options]"] : []) + arguments.map(\.signature)).joined(separator: " ")
    }

    public var visibleOptions: [CLIOption] { options.filter { !$0.hidden } }
}

public enum ExitCode: Int32, Sendable, CaseIterable {
    case ok = 0
    case failure = 1
    case usage = 2
    case printer = 3
    case input = 4
    case unhealthy = 5

    public var meaning: String {
        switch self {
        case .ok: "Success."
        case .failure: "Something went wrong while making or sending a label."
        case .usage: "The command line couldn't be understood."
        case .printer: "No printer, an unknown printer, or a size the printer can't take."
        case .input: "A file couldn't be read."
        case .unhealthy: "doctor found a problem."
        }
    }
}

public enum Manual {
    public static let tool = "peelgood"
    public static let names = [tool]

    // MARK: Shared options

    static func choices<T: RawRepresentable & CaseIterable>(_: T.Type) -> [String] where T.RawValue == String {
        T.allCases.map(\.rawValue)
    }

    /// Ink modes and their help come from LabelKit, so new ones show up in help and completions by themselves.
    static var inkSummary: String {
        "How grays print: " + InkMode.allCases.map { "\($0.rawValue) (\($0.help))" }.joined(separator: ", ") + "."
    }

    public static let printer = CLIOption("printer", short: "p", value: "NAME", help: "Printer queue. Default: the one chosen in the app, else your label printer.",
                                          completion: .printers)
    public static let size = CLIOption("size", short: "s", value: "WxH", help: "Label size in inches, or with mm (100x150mm). Default: the app's size for the printer, else 4x6.",
                                       completion: .sizes)
    public static let copies = CLIOption("copies", short: "n", value: "N", help: "Copies of each label, \(Limits.describe(Limits.copies)).")
    public static let rules = CLIOption("rules", help: "Apply the app's rules (on when the app has any).")
    public static let noRules = CLIOption("no-rules", help: "Ignore the app's rules.")
    public static let noHistory = CLIOption("no-history", help: "Don't save the print to History or Reprint Last Label.")
    public static let dryRun = CLIOption("dry-run", help: "Do everything but print: show the lp command instead.")
    public static let out = CLIOption("out", short: "o", value: "DIR", help: "Folder for the label PDF and PNG previews.", completion: .directory)
    public static let ink = CLIOption("ink", value: "MODE", help: inkSummary, choices: choices(InkMode.self))
    public static let cutoff = CLIOption("cutoff", value: "\(Int(Limits.cutoff.lowerBound * 100))-\(Int(Limits.cutoff.upperBound * 100))", help: "Black and white cutoff in percent. Default 50.")
    public static let toneGamma = CLIOption("tone-gamma", value: "G", help: "Printer dot gain for photo and halftone: coverage c prints as c^G. Default 0.65, 1 turns it off.")
    public static let nudge = CLIOption("nudge", value: "X,Y", help: "Shift in mm, +x right, +y down. Default: the app's calibration.")

    public static let layout: [CLIOption] = [
        printer, size,
        CLIOption("fit", value: "MODE", help: "fit shows everything, fill covers the label. Default fit.", choices: choices(FitMode.self)),
        CLIOption("crop", value: "MODE", help: "auto finds the label or code on the page, content trims margins, none keeps the page.",
                  choices: choices(CropMode.self)),
        CLIOption("pad", value: "MM", help: "Padding around the crop in mm. Default 2."),
        CLIOption("rotate", value: "MODE", help: "Turn the page to match the label: auto, none, cw or ccw. Default auto.", choices: choices(RotationMode.self)),
        ink, cutoff, toneGamma, nudge,
        CLIOption("no-snap", help: "Don't fit barcodes to the printer's dot grid."),
    ]

    public static let globalOptions: [CLIOption] = [
        CLIOption("json", help: "Machine-readable output on stdout."),
        CLIOption("verbose", short: "v", help: "More detail: crop, scale, code analysis."),
        CLIOption("quiet", short: "q", help: "Only errors."),
        CLIOption("no-color", help: "Plain text. Also NO_COLOR=1."),
        CLIOption("help", short: "h", help: "Help for a command."),
    ]

    static let files = CLIArgument("file", help: "PDF, SVG, PNG, JPEG, HEIC or TIFF.", variadic: true, completion: .file)

    // MARK: Commands

    public static let commands: [CLICommand] = [
        CLICommand("print", aliases: ["p"], group: .labels, summary: "Print files as labels",
                   discussion: "Finds the label on each page, fits it to the label size and sends it to the printer. Every page becomes a label. When the app has rules, the first file's matching rule picks the printer, size, fit, ink and copies, as if it were dropped; options you pass win. All the files print as one job, as a drop of several files does in the app: one PDF, sent once with the copies, saved to History once and made Reprint Last Label.",
                   arguments: [files],
                   options: layout + [copies, dryRun, rules, noRules, noHistory,
                                      CLIOption("out", short: "o", value: "DIR", help: "Also keep the label PDF here.", completion: .directory)],
                   examples: [
                       CLIExample("peelgood print order-1460-label.pdf", "Print on your label printer with the app's settings"),
                       CLIExample("peelgood print return.png --size 4x6 --copies 2", "Two copies at 4x6"),
                       CLIExample("peelgood print label.pdf --dry-run", "See what would be sent"),
                       CLIExample("peelgood print ~/Downloads/*.pdf --printer Label_Printer", "Print a batch on a named printer"),
                       CLIExample("peelgood print label.pdf --no-rules --no-history", "Only the printer's settings, and leave no trace"),
                   ]),
        CLICommand("preview", group: .labels, summary: "Make the label without printing",
                   discussion: "Writes the label PDF and one PNG per page, then lists them. Nothing is sent to a printer. The app's rules apply as they do for print, so the preview shows what print will do.",
                   arguments: [files],
                   options: layout + [rules, noRules, CLIOption("out", short: "o", value: "DIR", help: "Folder for the files. Default: a temporary folder.", completion: .directory),
                                      CLIOption("open", help: "Open the label PDF in Preview when done.")],
                   examples: [
                       CLIExample("peelgood preview label.pdf", "Write the label PDF and PNGs to a temporary folder"),
                       CLIExample("peelgood preview photo.jpg --ink photo -o out", "Dithered, into ./out"),
                       CLIExample("peelgood preview label.pdf --json | jq '.files[0].pdf'", "The PDF's path, for scripts"),
                   ]),
        CLICommand("test-label", group: .labels, summary: "Print a calibration label",
                   discussion: "A border 2 mm in, rulers and a QR code. Use it to check offset and scale, then set a nudge in the app.",
                   options: [printer, size, nudge, copies, dryRun, out],
                   examples: [
                       CLIExample("peelgood test-label", "On your label printer at its size"),
                       CLIExample("peelgood test-label --size 2x1 --dry-run", "Check a small roll without printing"),
                   ]),
        CLICommand("step-wedge", aliases: ["wedge"], group: .labels, summary: "Print a gray ramp to compare ink modes",
                   discussion: "Steps from white to black in 10% stops, plus a smooth gradient. Print it once per ink mode to pick one for photos.",
                   options: [printer, size, ink, cutoff, toneGamma, nudge, copies, dryRun, out],
                   examples: [
                       CLIExample("peelgood step-wedge --ink photo", "See how dithering renders grays"),
                       CLIExample("peelgood step-wedge --ink crisp --cutoff 40 --dry-run", "Try a lower cutoff without printing"),
                   ]),
        CLICommand("printers", aliases: ["ls"], group: .printers, summary: "List printers",
                   options: [CLIOption("names", help: "Queue names only, one per line.")],
                   examples: [CLIExample("peelgood printers", "Every printer, label printers marked"),
                              CLIExample("peelgood printers --json", "For scripts")]),
        CLICommand("sizes", group: .printers, summary: "List label sizes a printer takes",
                   arguments: [CLIArgument("printer", help: "Printer queue. Default: your label printer.", optional: true, completion: .printers)],
                   options: [CLIOption("names", help: "Supported sizes only, one per line.")],
                   examples: [CLIExample("peelgood sizes", "Sizes for your label printer"),
                              CLIExample("peelgood sizes Label_Printer --json", "For a named printer, as JSON")]),
        CLICommand("doctor", group: .app, summary: "Check printers, CUPS, the app and its API",
                   discussion: "Runs read-only checks and says what to fix. Exits 5 when a check fails.",
                   examples: [CLIExample("peelgood doctor", "Check everything")]),
        CLICommand("history", group: .app, summary: "List recent prints",
                   discussion: "Labels the app and `peelgood print` printed, newest first. They're kept in \(AppIdentity.supportFolderDisplay)/History.",
                   options: [CLIOption("limit", short: "n", value: "N", help: "How many. Default 10."),
                             CLIOption("paths", help: "Full paths only, one per line.")],
                   examples: [CLIExample("peelgood history", "The last 10 prints"),
                              CLIExample("peelgood preview \"$(peelgood history -n 1 --paths)\"", "Preview the last label again")]),
        CLICommand("version", group: .app, summary: "Show the version",
                   examples: [CLIExample("peelgood version --json", "Version and paths as JSON")]),
        CLICommand("completions", group: .shell, summary: "Print a shell completion script",
                   discussion: "Homebrew installs completions for you. Otherwise add the line for your shell.",
                   arguments: [CLIArgument("shell", help: "zsh, bash or fish.", choices: Completions.Shell.allCases.map(\.rawValue))],
                   examples: [
                       CLIExample(Completions.Shell.zsh.installLine, "zsh: add to ~/.zshrc"),
                       CLIExample(Completions.Shell.bash.installLine, "bash: add to ~/.bash_profile"),
                       CLIExample(Completions.Shell.fish.installLine, "fish: run once"),
                   ]),
        CLICommand("help", group: .shell, summary: "Help for a command",
                   arguments: [CLIArgument("command", help: "A command name.", optional: true,
                                           choices: ["print", "preview", "test-label", "step-wedge", "printers", "sizes", "doctor", "history", "version", "completions"])],
                   examples: [CLIExample("peelgood help print", "Options and examples for print")]),
        CLICommand("man-page", group: .shell, summary: "Print the man page in roff",
                   options: [CLIOption("release", value: "VERSION", help: "Version to print in the footer.", hidden: true)], hidden: true),
    ]

    public static var visibleCommands: [CLICommand] { commands.filter { !$0.hidden } }

    public static func command(_ name: String) -> CLICommand? {
        commands.first { $0.name == name || $0.aliases.contains(name) }
    }

    public static let environment: [(name: String, help: String)] = [
        ("LABELIZE_PRINTER", "Printer to use when --printer isn't given."),
        ("NO_COLOR", "Turns off color, like --no-color."),
        ("CLICOLOR_FORCE", "Color even when output isn't a terminal."),
        ("PEELGOOD_DEFAULTS_DOMAIN", "Settings domain to read defaults from. Only Reprint Last Label is written back. Default \(AppIdentity.bundleID); none turns it off."),
        ("LABELIZE_SUPPORT_DIR", "The app's data folder. Default \(AppIdentity.supportFolderDisplay)."),
    ]

    /// The old flag-only form, still accepted.
    public static let legacy: [(old: String, new: String)] = [
        ("peelgood file.pdf --print", "peelgood print file.pdf"),
        ("peelgood file.pdf --dry-run", "peelgood print file.pdf --dry-run"),
        ("peelgood file.pdf", "peelgood preview file.pdf -o out"),
        ("peelgood --list-printers", "peelgood printers"),
        ("peelgood --list-sizes --printer P", "peelgood sizes P"),
        ("peelgood --test-label --print", "peelgood test-label"),
        ("peelgood --step-wedge --print", "peelgood step-wedge"),
    ]
}
