import CoreGraphics
import Foundation
import LabelKit
import PeelGoodCore
import PeelGoodShared
import XCTest

/// PeelGoodCore: one behaviour for the app, the API and the command line. Nothing here prints or
/// touches the app's real settings: settings live in memory or in a throwaway UserDefaults suite.
final class CoreTests: XCTestCase {
    static let label = PrinterInfo(name: "Label_Printer_ITPP941AP", makeAndModel: "MUNBYN ITPP941AP-AirPrint", isDefault: false,
                                   presets: SizeCatalog.standard.filter { $0.width <= 4 && $0.width >= 2 },
                                   customMin: LabelSize(width: 1, height: 1), customMax: LabelSize(width: 4.25, height: 11))
    static let office = PrinterInfo(name: "Canon_TS9500_series", makeAndModel: "Canon TS9500 series", isDefault: true,
                                    presets: [.fourBySix, LabelSize(width: 8.5, height: 11)])
    static let small = PrinterInfo(name: "Small_Printer", makeAndModel: "Tiny 2in", presets: [LabelSize(width: 2, height: 1)])
    static let printers = [office, label, small]

    // MARK: 1. Settings

    /// What the app writes through UserDefaults is what the CLI reads through CFPreferences.
    func testAppWritesWhatTheCommandLineReads() throws {
        let domain = "test.peelgood.core.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = AppSettings.userDefaults(defaults, source: domain)
        app.printerName = Self.label.name
        app.setSize(LabelSize(width: 4, height: 4), for: Self.label.name)
        app.setInk(.photo, for: Self.label.name)
        app.setCutoff(0.4, for: Self.label.name)
        app.setNudge(CGPoint(x: 1, y: -0.5), for: Self.label.name)
        app.setToneGamma(0.8, for: Self.label.name)
        app.hiddenPrinters = [Self.small.name]
        defaults.synchronize()

        let cli = AppSettings.preferences(domain: domain)
        XCTAssertFalse(cli.isWritable, "the CLI reads the app's settings")
        XCTAssertEqual(cli.printerName, Self.label.name)
        XCTAssertEqual(cli.hiddenPrinters, [Self.small.name])
        let a = app.options(for: Self.label), c = cli.options(for: Self.label)
        XCTAssertEqual(a.options.size, c.options.size)
        XCTAssertEqual(c.options.size, LabelSize(width: 4, height: 4))
        XCTAssertEqual(c.options.ink, .photo)
        XCTAssertEqual(c.options.cutoff, 0.4, accuracy: 1e-9)
        XCTAssertEqual(c.options.nudgeMM, CGPoint(x: 1, y: -0.5))
        XCTAssertEqual(c.options.toneGamma, 0.8, accuracy: 1e-9)
        XCTAssertEqual(c.saved, ["size", "ink", "cutoff", "nudge", "toneGamma"])
    }

    func testDefaultsAndLegacyKeys() {
        let s = AppSettings.memory(["fit": "fill"])
        XCTAssertEqual(s.countdown, 1.5)
        XCTAssertEqual(s.historyDays, 30)
        XCTAssertEqual(s.tagName, "Printed")
        XCTAssertEqual(s.tagColor, .green)
        XCTAssertTrue(s.tagAfterPrint)
        XCTAssertEqual(s.newFilesAction, .ask)
        XCTAssertEqual(s.options(for: Self.label).options.fit, .fill, "the old app-wide fit still applies")
        XCTAssertEqual(s.options(for: Self.label).options.cutoff, 0.5)
    }

    // MARK: 2. Printers and the saved-size fallback

    func testPrintersMatchTheSameWayEverywhere() {
        let r = PrinterResolver(printers: Self.printers)
        XCTAssertEqual(r.find("Label_Printer_ITPP941AP")?.name, Self.label.name, "queue name")
        XCTAssertEqual(r.find("label_printer_itpp941ap")?.name, Self.label.name, "ignoring case")
        XCTAssertEqual(r.find("MUNBYN ITPP941AP")?.name, Self.label.name, "display name")
        XCTAssertEqual(r.find("ts9500")?.name, Self.office.name, "the one that contains it")
        XCTAssertNil(r.find("printer"), "ambiguous")
        XCTAssertNil(r.find("Zebra"))
    }

    func testDefaultPrinterRespectsHiddenPrinters() {
        var r = PrinterResolver(printers: Self.printers)
        XCTAssertEqual(r.defaultChoice?.printer.name, Self.label.name)
        XCTAssertEqual(r.defaultChoice?.source, .labelPrinter)
        XCTAssertFalse(r.eligible.contains { $0.name == Self.small.name }, "can't take 4x6")

        r.chosen = Self.office.name
        XCTAssertEqual(r.defaultChoice?.source, .chosen)
        r.hidden = [Self.office.name, Self.label.name]
        XCTAssertNil(r.defaultChoice, "hidden printers are never the default")
        XCTAssertEqual(r.find(Self.label.name)?.name, Self.label.name, "naming a hidden printer still finds it")
        XCTAssertNil(r.find(Self.label.name, in: .eligible))

        r.hidden = [Self.label.name]
        r.chosen = nil
        XCTAssertEqual(r.defaultChoice?.printer.name, Self.office.name)
        XCTAssertEqual(r.defaultChoice?.source, .firstEligible)
    }

    /// A saved size the printer can't take falls back to 4x6 with a note; an asked-for size is an error.
    func testSavedSizeFallsBackAskedSizeFails() throws {
        let s = AppSettings.memory()
        s.setSize(LabelSize(width: 8.5, height: 11), for: Self.label.name)
        let r = s.options(for: Self.label)
        XCTAssertEqual(r.options.size, .fourBySix)
        XCTAssertEqual(r.note, "MUNBYN ITPP941AP can't take 8.5 × 11 in labels, so this uses 4 × 6 in.")

        XCTAssertThrowsError(try OptionOverrides(size: "8.5x11").apply(to: r.options, on: Self.label)) { e in
            XCTAssertEqual((e as? OptionError)?.code, "unsupported_size")
            XCTAssertEqual((e as? OptionError)?.isUnsupported, true)
        }
        XCTAssertThrowsError(try OptionOverrides(size: "big").apply(to: r.options, on: Self.label)) { e in
            XCTAssertEqual((e as? OptionError)?.code, "invalid_size")
        }
        let o = try OptionOverrides(size: "4x4", fit: "FILL", ink: " Photo").apply(to: r.options, on: Self.label)
        XCTAssertEqual(o.size, LabelSize(width: 4, height: 4))
        XCTAssertEqual(o.fit, .fill, "values ignore case everywhere")
        XCTAssertEqual(o.ink, .photo)
    }

    // MARK: 3. Rules for the command line

    func testRulesDecideForTheCommandLine() throws {
        var rule = Rule(name: "Labels from Terminal", conditions: [RuleCondition(field: .trigger, op: .is, values: [RuleTrigger.cli.rawValue])])
        rule.outcome.ink = .crisp
        rule.outcome.copies = 2
        rule.outcome.printer = "munbyn itpp941ap"
        let book = RuleBook(rules: [rule])
        let r = PrinterResolver(printers: Self.printers)
        func decide(_ t: RuleTrigger) -> RuleDecision? {
            book.decide(RuleContext(trigger: t, fileName: "label.pdf", kind: .pdf), printers: r.eligible, current: Self.office,
                        defaults: { _ in LabelOptions() })
        }
        let d = try XCTUnwrap(decide(.cli))
        XCTAssertEqual(d.ruleName, "Labels from Terminal")
        XCTAssertEqual(d.printer.name, Self.label.name, "the rule's printer matches like --printer does")
        XCTAssertEqual(d.copies, 2)
        XCTAssertEqual(d.options.ink, .crisp)
        XCTAssertEqual(decide(.drop)?.isFallback, true)
    }

    /// The CLI reads rules.json and never moves a file it can't read.
    func testRuleBookRoundTripAndReadOnlyLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("core-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rules.json")
        try RuleBook(rules: [Rule(name: "A", conditions: [RuleCondition(field: .name, op: .contains, values: ["label"])])]).save(to: url)
        XCTAssertEqual(RuleBook.load(from: url, setAsideBroken: false)?.rules.first?.name, "A")
        try Data("{".utf8).write(to: url)
        XCTAssertNil(RuleBook.load(from: url, setAsideBroken: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "read-only load leaves the file")
        XCTAssertNil(RuleBook.load(from: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".broken"), "the app sets it aside")
    }

    /// CLI prints go to History and become Reprint Last Label, under the app's naming.
    func testHistorySaveAndLastPrint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("core-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("order-1460-label.label.pdf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TestLabel.pattern.writePDF(size: .fourBySix, title: "t", to: pdf)
        let date = ISO8601DateFormatter().date(from: "2026-10-29T20:03:09Z")!
        let saved = try History.save(pdf, source: URL(fileURLWithPath: "/x/order-1460-label.pdf"), in: dir.appendingPathComponent("History"), at: date)
        XCTAssertEqual(saved.lastPathComponent, "2026-10-29T20-03-09Z order-1460-label.label.pdf")
        let entries = History.entries(in: dir.appendingPathComponent("History"))
        XCTAssertEqual(entries.first?.name, "order-1460-label")
        XCTAssertEqual(entries.first?.date, date)
        XCTAssertEqual(entries.first?.labels, 1)

        let s = AppSettings.memory()
        s.lastPrint = AppSettings.LastPrint(file: saved, printer: Self.label.name, size: .fourBySix)
        XCTAssertEqual(s.lastPrint?.file, saved)
        XCTAssertEqual(s.string(SettingsKey.lastFile.rawValue), saved.path, "the keys the app reads")
    }

    // MARK: 4. Rule actions and triggers

    /// Only watched folders follow New files and may Ask; files handed over (the API too) print or preview.
    func testActionsAndEverythingElse() throws {
        var book = RuleBook()
        book.fallback.outcome.action = .review
        book.fallback.outcome.copies = 3
        func decide(_ t: RuleTrigger, _ unattended: RuleAction = .ask) -> RuleDecision? {
            book.decide(RuleContext(trigger: t, fileName: "a.pdf", kind: .pdf), printers: Self.printers, current: Self.label,
                        defaults: { _ in LabelOptions() }, unattended: unattended)
        }
        XCTAssertEqual(decide(.api)?.action, .print, "Everything else's saved action is ignored; the API isn't a watched folder")
        XCTAssertEqual(decide(.api)?.copies, 1)
        XCTAssertEqual(decide(.watchedFolder)?.action, .ask)
        XCTAssertEqual(decide(.watchedFolder, .print)?.action, .print)
        var rule = Rule(name: "Ask", conditions: [RuleCondition(field: .kind, op: .is, values: [FileKind.pdf.rawValue])])
        rule.outcome.action = .ask
        book.rules = [rule]
        XCTAssertEqual(decide(.api)?.action, .review, "Ask previews for files handed over")
        XCTAssertEqual(decide(.clipboard)?.action, .review)
        XCTAssertEqual(decide(.watchedFolder)?.action, .ask)
        XCTAssertFalse(RuleTrigger.api.isUnattended)
    }

    // MARK: 5. Finder tags

    func testTagPrecedence() {
        let general = FinderTag(name: "Printed", color: .green), mine = FinderTag(name: "Returns", color: .red)
        XCTAssertEqual(RuleTag.general.resolve(generalOn: true, general: general), general)
        XCTAssertNil(RuleTag.none.resolve(generalOn: true, general: general), "a rule's None wins over General")
        XCTAssertEqual(RuleTag.custom(mine).resolve(generalOn: true, general: general), mine, "a rule's own tag replaces General's")
        for tag in [RuleTag.general, .none, .custom(mine)] {
            XCTAssertNil(tag.resolve(generalOn: false, general: general), "General off tags nothing")
        }
        XCTAssertNil(RuleTag.general.resolve(generalOn: true, general: FinderTag(name: " ", color: .green)))
        XCTAssertEqual(RuleOutcome().tag, .general, "a new rule follows General")
    }

    func testTagJSONIsCompatible() throws {
        func outcome(_ json: String) throws -> RuleOutcome { try JSONDecoder().decode(RuleOutcome.self, from: Data(json.utf8)) }
        XCTAssertEqual(try outcome(#"{"copies": 1}"#).tag, .none, "old files without a tag had it turned off")
        XCTAssertEqual(try outcome(#"{"tag": {"name": "Done", "color": 6}}"#).tag, .custom(FinderTag(name: "Done", color: .red)))
        XCTAssertEqual(try outcome(#"{"tag": "default"}"#).tag, .general)
        XCTAssertEqual(try outcome(#"{"tag": "none"}"#).tag, .none)
        let back = try outcome(String(decoding: try JSONEncoder().encode(RuleOutcome()), as: UTF8.self))
        XCTAssertEqual(back.tag, .general)
    }

    func testFinderTagIsTheOneWriter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tag-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        FinderTag(name: "Printed", color: .green).apply(to: url)
        FinderTag(name: "Printed", color: .red).apply(to: url)
        FinderTag(name: "Returns", color: .none).apply(to: url)
        XCTAssertEqual(FinderTag.names(on: url), ["Printed", "Returns"], "same name replaced, others kept")
    }

    // MARK: 6. Sizes as people read them

    func testSizeDisplayIsTheSameInTheAppAndTheCommandLine() {
        let metric = LabelSize(parsing: "100x150mm")!
        XCTAssertEqual(metric.primary, "100 × 150 mm", "not 100×150mm in")
        XCTAssertEqual(metric.display, "100 × 150 mm (3.94 × 5.91 in)")
        XCTAssertEqual(LabelSize.fourBySix.primary, "4 × 6 in")
        XCTAssertEqual(LabelSize.fourBySix.display, "4 × 6 in (102 × 152 mm)")
        XCTAssertEqual(TestLabel.title(printer: Self.label, size: metric), "MUNBYN ITPP941AP · 100 × 150 mm")
        XCTAssertEqual(Self.small.displayName, "Tiny 2in")
        XCTAssertEqual(PrinterInfo(name: "My_Printer", presets: []).displayName, "My Printer")
    }

    // MARK: 7. Test labels

    func testTestLabelsPrintAsDrawn() throws {
        var o = LabelOptions()
        o.ink = .photo
        TestLabel.pattern.adjust(&o)
        XCTAssertEqual(o.ink, .crisp)
        XCTAssertEqual(o.crop, .none)
        XCTAssertEqual(o.rotation, .none)
        var w = LabelOptions()
        TestLabel.stepWedge.adjust(&w)
        XCTAssertEqual(w.ink, .photo)
        XCTAssertEqual(w.toneGamma, 1)
        w.ink = .halftone
        w.toneGamma = 0.7
        TestLabel.stepWedge.adjust(&w, keepInk: true, keepToneGamma: true)
        XCTAssertEqual(w.ink, .halftone)
        XCTAssertEqual(w.toneGamma, 0.7)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(TestLabel.stepWedge.fileStem(.fourBySix))-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestLabel.stepWedge.writePDF(size: .fourBySix, title: "wedge", to: url)
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(doc.numberOfPages, 1)
        XCTAssertEqual(doc.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 288, height: 432))
    }

    // MARK: 8. Paths

    func testPathsAndServerInfo() throws {
        XCTAssertEqual(AppPaths.history, AppPaths.support.appendingPathComponent("History", isDirectory: true))
        XCTAssertEqual(AppPaths.rulesFile.lastPathComponent, "rules.json")
        XCTAssertEqual(AppPaths.token.deletingLastPathComponent(), AppPaths.serverInfo.deletingLastPathComponent())
        XCTAssertEqual(AppIdentity.bundleID, "com.fermium.peelgood")
        if AppPaths.override == nil { XCTAssertTrue(AppPaths.isScratchRun, "tests never use the real folders") }

        let info = ServerInfo(port: 47311, pid: ProcessInfo.processInfo.processIdentifier, http: true, mcp: false, tokenPath: "/t", version: "1")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("server-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(info).write(to: url)
        let back = try XCTUnwrap(ServerInfo.load(from: url))
        XCTAssertEqual(back, info)
        XCTAssertEqual(back.mcpURL, "http://127.0.0.1:47311/mcp")
        XCTAssertTrue(back.isAlive)
    }

    /// The old bundle ID's settings are copied into an empty new domain once, never over existing ones.
    /// Two fixed throwaway domains, emptied before and after; the real ones are never touched.
    func testDefaultsMigration() {
        let old = "com.fermium.peelgood-test.migration-old", new = "com.fermium.peelgood-test.migration-new"
        func clear(_ d: String) {
            CFPreferencesSetMultiple(nil, DefaultsMigration.keys(in: d) as CFArray, d as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(d as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        clear(old); clear(new)
        defer { clear(old); clear(new) }
        XCTAssertEqual(DefaultsMigration.copy(from: old, to: new), 0, "nothing to copy")
        XCTAssertEqual(AppSettings.defaultDomain(current: new, legacy: old), new)

        let oldSettings = AppSettings.preferences(domain: old, writable: true)
        oldSettings.set("Label_Printer", SettingsKey.printer.rawValue)
        oldSettings.set(2.5, SettingsKey.countdown.rawValue)
        XCTAssertEqual(AppSettings.defaultDomain(current: new, legacy: old), old, "the CLI falls back to the old domain")

        XCTAssertEqual(DefaultsMigration.copy(from: old, to: new), 2)
        let newSettings = AppSettings.preferences(domain: new)
        XCTAssertEqual(newSettings.printerName, "Label_Printer")
        XCTAssertEqual(newSettings.countdown, 2.5)
        XCTAssertEqual(AppSettings.preferences(domain: old).printerName, "Label_Printer", "the old domain stays")
        XCTAssertEqual(AppSettings.defaultDomain(current: new, legacy: old), new)

        oldSettings.set("Other", SettingsKey.printer.rawValue)
        XCTAssertEqual(DefaultsMigration.copy(from: old, to: new), 0, "only once")
        XCTAssertEqual(newSettings.printerName, "Label_Printer")
    }

    // MARK: 9. Limits

    func testLimitsAndPickerChoices() throws {
        XCTAssertEqual(Limits.choices(Limits.countdownChoices, including: 5), [0, 1.5, 3, 5], "a value MCP set still shows")
        XCTAssertEqual(Limits.choices(Limits.countdownChoices, including: 1.5), Limits.countdownChoices)
        XCTAssertEqual(Limits.choices(Limits.historyChoices, including: 14, keepLast: 0), [1, 7, 14, 30, 90, 365, 0], "Forever stays last")
        XCTAssertEqual(Limits.countdownTitle(0), "Immediately")
        XCTAssertEqual(Limits.countdownTitle(4.5), "After 4.5 s")
        XCTAssertEqual(Limits.historyTitle(14), "14 days")
        XCTAssertEqual(Limits.inks, InkMode.allCases.map(\.rawValue))
        XCTAssertNoThrow(try OptionOverrides.copies(Limits.copies.upperBound))
        XCTAssertThrowsError(try OptionOverrides.copies(Limits.copies.upperBound + 1))
        XCTAssertThrowsError(try OptionOverrides(cutoff: 0.1).apply(to: LabelOptions(), on: nil))
        XCTAssertThrowsError(try OptionOverrides(nudgeMM: CGPoint(x: 11, y: 0)).apply(to: LabelOptions(), on: nil))
    }
}
