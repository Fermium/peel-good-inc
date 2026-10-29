import LabelKit
import LabelizeCore
@testable import LabelizeCLI
import XCTest

/// The command line, parsed without running anything: nothing here reaches a printer.
final class ParserTests: XCTestCase {
    private func parse(_ line: String, files: Set<String> = []) throws -> Invocation {
        try Parser.parse(line.split(separator: " ").map(String.init), fileExists: { files.contains($0) })
    }

    private func usageError(_ line: String, files: Set<String> = [], file: StaticString = #filePath, lineNo: UInt = #line) -> CLIError? {
        do {
            _ = try parse(line, files: files)
            XCTFail("expected an error for \(line)", file: file, line: lineNo)
            return nil
        } catch let e as CLIError {
            return e
        } catch {
            XCTFail("\(error)", file: file, line: lineNo)
            return nil
        }
    }

    // MARK: Commands

    func testPrintWithOptions() throws {
        let inv = try parse("print a.pdf b.png --size 4x6 -n 2 --ink=crisp -p Label_Printer --dry-run --json")
        XCTAssertEqual(inv.command, "print")
        XCTAssertEqual(inv.arguments, ["a.pdf", "b.png"])
        XCTAssertEqual(inv["size"], "4x6")
        XCTAssertEqual(inv["copies"], "2")
        XCTAssertEqual(inv["ink"], "crisp")
        XCTAssertEqual(inv["printer"], "Label_Printer")
        XCTAssertTrue(inv.has("dry-run"))
        XCTAssertTrue(inv.global.json)
        XCTAssertNil(inv.legacyHint)
    }

    func testAliasesAndShortValueForms() throws {
        XCTAssertEqual(try parse("p a.pdf -s2x1").command, "print")
        XCTAssertEqual(try parse("p a.pdf -s2x1")["size"], "2x1")
        XCTAssertEqual(try parse("ls").command, "printers")
        XCTAssertEqual(try parse("wedge --ink photo").command, "step-wedge")
    }

    func testNegativeNudgeIsAValue() throws {
        XCTAssertEqual(try parse("print a.pdf --nudge -1.5,0.5")["nudge"], "-1.5,0.5")
    }

    func testDoubleDashEndsOptions() throws {
        XCTAssertEqual(try parse("preview -- --weird.pdf").arguments, ["--weird.pdf"])
    }

    func testHelpForms() throws {
        XCTAssertEqual(try parse("").command, "help")
        XCTAssertEqual(try parse("--help").command, "help")
        let sub = try parse("print --help")
        XCTAssertEqual(sub.command, "help")
        XCTAssertEqual(sub.arguments, ["print"])
        XCTAssertEqual(try parse("help sizes").arguments, ["sizes"])
        XCTAssertEqual(try parse("--version").command, "version")
        XCTAssertEqual(try parse("-V").command, "version")
    }

    // MARK: Errors

    func testMistypedCommandSuggests() {
        let e = usageError("prnt a.pdf")
        XCTAssertEqual(e?.code, .usage)
        XCTAssertEqual(e?.hint, "Did you mean `peelgood print`?")
        XCTAssertEqual(usageError("doctr")?.hint, "Did you mean `peelgood doctor`?")
    }

    func testUnknownOptionSuggests() {
        let e = usageError("print a.pdf --szie 4x6")
        XCTAssertEqual(e?.message, "print has no option --szie")
        XCTAssertTrue(e?.hint?.hasPrefix("Did you mean --size?") == true)
        XCTAssertEqual(usageError("printers --limit 3")?.hint, "--limit belongs to `peelgood history`.")
    }

    func testBadChoiceListsChoices() {
        let e = usageError("print a.pdf --ink crsip")
        XCTAssertEqual(e?.message, "--ink can't be crsip")
        XCTAssertTrue(e?.hint?.contains("Did you mean crisp?") == true)
        XCTAssertTrue(e?.hint?.contains(InkMode.allCases.last!.rawValue) == true)
    }

    func testMissingFileAndValue() {
        XCTAssertEqual(usageError("print")?.message, "print needs at least one file")
        XCTAssertEqual(usageError("print a.pdf --size")?.message, "--size needs a value (WxH)")
        XCTAssertEqual(usageError("completions tcsh")?.message, "shell can't be tcsh")
        XCTAssertEqual(usageError("version extra")?.message, "version doesn't take extra")
        XCTAssertEqual(usageError("print a.pdf --dry-run=yes")?.message, "--dry-run doesn't take a value")
    }

    // MARK: Old flags

    func testLegacyPrint() throws {
        let inv = try parse("file.pdf --size 4x6 --print")
        XCTAssertEqual(inv.command, "print")
        XCTAssertEqual(inv.arguments, ["file.pdf"])
        XCTAssertEqual(inv["size"], "4x6")
        XCTAssertEqual(inv["out"], "out")
        XCTAssertFalse(inv.has("dry-run"))
        XCTAssertEqual(inv.legacyHint, "The flag-only form still works. Next time: peelgood print file.pdf --size 4x6 --out out")
    }

    func testLegacyDryRunAndPreview() throws {
        let dry = try parse("--ink photo label.png --dry-run --copies 3")
        XCTAssertEqual(dry.command, "print")
        XCTAssertTrue(dry.has("dry-run"))
        XCTAssertEqual(dry["copies"], "3")
        XCTAssertEqual(dry.arguments, ["label.png"])

        // No --print: the old CLI only wrote files to ./out. --copies meant nothing then.
        let preview = try parse("label.pdf --copies 2 --out /tmp/x", files: ["label.pdf"])
        XCTAssertEqual(preview.command, "preview")
        XCTAssertEqual(preview["out"], "/tmp/x")
        XCTAssertNil(preview["copies"])
        XCTAssertNotNil(preview.legacyHint)
    }

    func testLegacyListsAndTestLabel() throws {
        XCTAssertEqual(try parse("--list-printers").command, "printers")
        let sizes = try parse("--list-sizes --printer Label_Printer")
        XCTAssertEqual(sizes.command, "sizes")
        XCTAssertEqual(sizes.arguments, ["Label_Printer"])

        let test = try parse("--test-label --size 2x1 --fit fill")
        XCTAssertEqual(test.command, "test-label")
        XCTAssertEqual(test["size"], "2x1")
        XCTAssertNil(test["fit"])
        XCTAssertTrue(test.has("dry-run"), "without --print the old --test-label only wrote a file")

        let printed = try parse("--test-label --print --printer P")
        XCTAssertFalse(printed.has("dry-run"))
        XCTAssertEqual(printed["printer"], "P")
        XCTAssertEqual(try parse("--step-wedge --ink photo --print").command, "step-wedge")
    }

    func testFileNamedLikeACommandNeedsDashDash() throws {
        // A file called "print" in the current folder: the command wins.
        XCTAssertEqual(try parse("print a.pdf", files: ["print"]).command, "print")
    }

    // MARK: Options into LabelOptions

    func testLayoutApply() throws {
        var base = LabelOptions()
        base.ink = .photo
        base.cutoff = 0.4
        let o = try Layout.apply(try parse("print a.pdf --size 100x150mm --fit fill --crop none --rotate cw --cutoff 60 --nudge 1,-2 --no-snap --pad 3"), to: base)
        XCTAssertEqual(o.size, LabelSize(width: 100 / 25.4, height: 150 / 25.4))
        XCTAssertEqual(o.fit, .fill)
        XCTAssertEqual(o.crop, CropMode.none)
        XCTAssertEqual(o.rotation, .cw)
        XCTAssertEqual(o.ink, .photo, "the app's ink stays when --ink isn't given")
        XCTAssertEqual(o.cutoff, 0.6, accuracy: 1e-9)
        XCTAssertEqual(o.nudgeMM, CGPoint(x: 1, y: -2))
        XCTAssertFalse(o.snapCodes)
        XCTAssertEqual(o.paddingMM, 3)
    }

    func testLayoutErrors() throws {
        XCTAssertThrowsError(try Layout.apply(try parse("print a.pdf --size big"), to: LabelOptions()))
        XCTAssertThrowsError(try Layout.apply(try parse("print a.pdf --cutoff 140"), to: LabelOptions()))
        XCTAssertThrowsError(try Layout.apply(try parse("print a.pdf --nudge 1"), to: LabelOptions()))
        XCTAssertThrowsError(try Layout.copies(try parse("print a.pdf -n 0")))
        XCTAssertEqual(try Layout.copies(try parse("print a.pdf")), 1)
    }

    func testAppDefaultsArePerPrinter() {
        let values: [String: Any] = ["printer": "P", "size.P": "2x1", "ink": "photo", "cutoff.P": 0.3, "nudgeX.P": 1.5]
        let d = AppSettings.memory(values, source: "test")
        let p = PrinterInfo(name: "P", presets: [LabelSize(width: 2, height: 1), .fourBySix])
        let r = d.options(for: p)
        XCTAssertEqual(d.printerName, "P")
        XCTAssertEqual(r.options.size, LabelSize(width: 2, height: 1))
        XCTAssertEqual(r.options.ink, .photo)
        XCTAssertEqual(r.options.cutoff, 0.3)
        XCTAssertEqual(r.options.nudgeMM, CGPoint(x: 1.5, y: 0))
        XCTAssertEqual(r.saved, ["size", "ink", "cutoff", "nudge"])
        XCTAssertNil(r.note)
        XCTAssertEqual(AppSettings.system(environment: ["PEELGOOD_DEFAULTS_DOMAIN": "none"]).source, "none")
        XCTAssertFalse(AppSettings.system(environment: ["PEELGOOD_DEFAULTS_DOMAIN": "none"], writable: true).isWritable)
    }

    // MARK: Generated text

    func testHelpCompletionsAndManPageCoverEveryCommand() {
        let man = ManPage.roff(version: "1.0")
        let zsh = Completions.script(for: .zsh), bash = Completions.script(for: .bash), fish = Completions.script(for: .fish)
        for c in Manual.visibleCommands {
            XCTAssertTrue(Help.overview(.plain).contains(c.name), c.name)
            XCTAssertTrue(man.contains(".SS \(ManPage.esc(c.usage()))"), c.name)
            XCTAssertTrue(zsh.contains("'\(c.name):"), c.name)
            XCTAssertTrue(bash.contains(c.name), c.name)
            XCTAssertTrue(fish.contains("-a \(c.name) "), c.name)
            for o in c.visibleOptions {
                XCTAssertTrue(Help.command(c, .plain).contains("--\(o.name)"), "\(c.name) --\(o.name)")
            }
        }
        XCTAssertTrue(zsh.hasPrefix("#compdef peelgood"))
        XCTAssertTrue(bash.contains("complete -o filenames -F _peelgood peelgood"))
        XCTAssertTrue(man.hasPrefix(".\\\""))
        XCTAssertFalse(Help.overview(.plain).contains("\u{1B}["), "no escapes without a terminal")
        XCTAssertTrue(Help.overview(Style(enabled: true)).contains("\u{1B}["))
    }

    func testStyleRespectsNoColor() {
        XCTAssertFalse(Style.detect(fd: 1, noColor: false, environment: ["NO_COLOR": "1", "CLICOLOR_FORCE": "1"]).enabled)
        XCTAssertTrue(Style.detect(fd: 1, noColor: false, environment: ["CLICOLOR_FORCE": "1"]).enabled)
        XCTAssertFalse(Style.detect(fd: 1, noColor: true, environment: ["CLICOLOR_FORCE": "1"]).enabled)
    }

    func testCopyIsTerse() {
        // Apple style for everything shown in Settings: no em dashes.
        let text = Manual.commands.flatMap { [$0.summary, $0.discussion] + $0.options.map(\.help) + $0.examples.map(\.comment) }
        for t in text { XCTAssertFalse(t.contains("—"), t) }
    }
}
