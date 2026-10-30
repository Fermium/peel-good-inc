// peelgood (also installed as peel): the command line for Peel Good Inc.
// Commands, options, help, completions and the man page are all described once in
// Sources/PeelGoodCLI/Manual.swift; this file only runs them.
import Foundation
import PeelGoodCLI
import LabelKit
import PeelGoodCore

let environment = ProcessInfo.processInfo.environment
let tool = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }).flatMap { Manual.names.contains($0) ? $0 : nil } ?? Manual.tool
let rawArgs = Array(CommandLine.arguments.dropFirst())
let earlyErr = Style.detect(fd: 2, noColor: rawArgs.contains("--no-color"))

func report(_ error: CLIError, style: Style) -> Never {
    var text = "\(style.red("error:")) \(error.message)\n"
    if let hint = error.hint { text += hint.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + style.dim(String($0)) }.joined(separator: "\n") + "\n" }
    FileHandle.standardError.write(Data(text.utf8))
    exit(error.code.rawValue)
}

let inv: Invocation
do { inv = try Parser.parse(rawArgs) } catch let e as CLIError { report(e, style: earlyErr) } catch { report(CLIError("\(error)"), style: earlyErr) }

// With --json, stdout carries only the JSON: anything else written to fd 1 while we work (system
// frameworks print there, e.g. GPU driver notices on virtual Macs) is sent to stderr instead.
if inv.global.json { JSONStdout.capture() }

let ctx = Context(inv: inv, out: Style.detect(fd: 1, noColor: inv.global.noColor), err: Style.detect(fd: 2, noColor: inv.global.noColor),
                  defaults: AppSettings.system(), tool: tool, environment: environment)

func run() throws -> ExitCode {
    switch inv.command {
    case "print": return try LabelRun(ctx: ctx, kind: .print).run()
    case "preview": return try LabelRun(ctx: ctx, kind: .preview).run()
    case "test-label": return try LabelRun(ctx: ctx, kind: .testLabel).run()
    case "step-wedge": return try LabelRun(ctx: ctx, kind: .stepWedge).run()
    case "printers": return try listPrinters(ctx)
    case "sizes": return try listSizes(ctx)
    case "doctor": return Doctor(ctx: ctx).run()
    case "history": return try listHistory(ctx)
    case "version": return showVersion(ctx)
    case "completions":
        print(Completions.script(for: Completions.Shell(rawValue: inv.arguments[0])!), terminator: "")
        return .ok
    case "man-page":
        print(ManPage.roff(version: inv["release"] ?? Context.version.short), terminator: "")
        return .ok
    default:
        if let name = inv.arguments.first {
            guard let command = Manual.command(name) else {
                throw CLIError.usage("no command \(name)", hint: Parser.closest(name, among: Manual.visibleCommands.map(\.name)).map { "Did you mean \($0)?" })
            }
            print(Help.command(command, ctx.out, tool: tool), terminator: "")
        } else {
            print(Help.overview(ctx.out, tool: tool), terminator: "")
        }
        return .ok
    }
}

do {
    let code = try run()
    if let hint = inv.legacyHint, isatty(2) == 1, !ctx.quiet { ctx.note(ctx.err.dim("tip: \(hint)")) }
    exit(code.rawValue)
} catch let e as CLIError {
    report(e, style: ctx.err)
} catch let e as ExitOnly {
    exit(e.code.rawValue)
} catch {
    report(CLIError("\(error)"), style: ctx.err)
}
