import Foundation
import LabelKit
import PeelGoodCore
import XCTest
@testable import PeelGoodApp

/// Defaults the rule engine fills in: Everything else, the action for watched folders, old rule files.
@MainActor
final class RuleEngineTests: XCTestCase {
    let printers = RulesPreviewData.printers

    private func decide(_ engine: RuleEngine, _ trigger: RuleTrigger, unattended: RuleAction = .ask) -> RuleDecision? {
        let ctx = RuleContext(trigger: trigger, fileName: "label.pdf", kind: .pdf)
        var defaults = LabelOptions()
        defaults.ink = .photo
        return engine.decide(ctx, printers: printers, current: printers[0], defaults: { _ in defaults }, unattended: unattended)
    }

    /// Everything else uses the default printer and its settings, whatever an older version saved in it.
    func testEverythingElseIgnoresItsSavedOutcome() throws {
        let engine = RuleEngine(fileURL: nil)
        engine.fallback.outcome.printer = printers[1].name
        engine.fallback.outcome.ink = .crisp
        engine.fallback.outcome.copies = 3
        engine.fallback.outcome.action = .review
        let d = try XCTUnwrap(decide(engine, .drop))
        XCTAssertTrue(d.isFallback)
        XCTAssertEqual(d.printer.name, printers[0].name)
        XCTAssertEqual(d.options.ink, .photo)
        XCTAssertEqual(d.copies, 1)
        XCTAssertEqual(d.action, .print)
        XCTAssertEqual(d.tag, .general, "the tag follows General")
    }

    /// Rules > New files decides for watched folders; files you hand over print, and Ask becomes the preview.
    func testNewFilesActionAppliesToUnattendedFilesOnly() {
        let engine = RuleEngine(fileURL: nil)
        XCTAssertEqual(decide(engine, .watchedFolder)?.action, .ask)
        XCTAssertEqual(decide(engine, .watchedFolder, unattended: .print)?.action, .print)
        XCTAssertEqual(decide(engine, .watchedFolder, unattended: .review)?.action, .review)
        XCTAssertEqual(decide(engine, .drop, unattended: .review)?.action, .print)

        var rule = Rule(name: "PDFs", conditions: [RuleCondition(field: .kind, op: .is, values: [FileKind.pdf.rawValue])])
        rule.outcome.action = .ask
        engine.rules = [rule]
        XCTAssertEqual(decide(engine, .watchedFolder, unattended: .print)?.action, .ask, "the rule wins")
        XCTAssertEqual(decide(engine, .drop)?.action, .review)
    }

    /// Rules saved with the old per-rule sound still load; the sound isn't written back.
    func testOldPlaySoundStillDecodes() throws {
        let json = #"{"printer": "Canon_TS9500_series", "copies": 2, "playSound": false, "tag": {"name": "Done", "color": 6}}"#
        let o = try JSONDecoder().decode(RuleOutcome.self, from: Data(json.utf8))
        XCTAssertEqual(o.printer, "Canon_TS9500_series")
        XCTAssertEqual(o.copies, 2)
        XCTAssertEqual(o.tag.custom?.name, "Done")
        let out = String(decoding: try JSONEncoder().encode(o), as: UTF8.self)
        XCTAssertFalse(out.contains("playSound"), out)
    }

    func testSummaryUsesDefaultPrinterAndShowPreview() {
        var o = RuleOutcome()
        o.action = .review
        XCTAssertEqual(RuleSummary.outcome(o, printers: printers), "Default printer · shows preview")
        XCTAssertEqual(RuleAction.review.title, "Show preview")
    }
}
