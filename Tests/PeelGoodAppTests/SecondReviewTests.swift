import Foundation
import LabelKit
import PeelGoodCore
import XCTest
@testable import PeelGoodApp

/// The second review's fixes: one rule per check, shared by the app, the API, MCP and the CLI.
/// In-memory settings and sample printers; nothing prints.
@MainActor
final class SecondReviewTests: XCTestCase {
    private func configurator() -> AppConfigurator {
        AppConfigurator(store: Store(settings: .memory()), rules: RuleEngine(fileURL: nil), folders: .inMemory())
    }

    private func code(_ block: () throws -> Any) -> String? {
        do { _ = try block(); return nil } catch let e as APIError { return e.code } catch { return "\(error)" }
    }

    // MARK: Previews

    /// A preview label is a label's info plus its image, and still encodes flat.
    func testLabelPreviewIsLabelInfoPlusImage() throws {
        let info = APILabelInfo(index: 2, ink: "photo", scalePercent: 87.5, rotated: true,
                                codes: [APICode(symbology: "QR", payload: "x", scannable: true, severity: "ok", message: nil)], warnings: ["w"])
        let preview = APILabelPreview(info, width: 10, height: 20, png: Data([1, 2, 3]))
        let data = try APIJSON.encoder.encode(preview)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let infoKeys = try XCTUnwrap(JSONSerialization.jsonObject(with: APIJSON.encoder.encode(info)) as? [String: Any]).keys
        XCTAssertEqual(Set(object.keys), Set(infoKeys).union(["width", "height", "png"]))
        XCTAssertEqual(try JSONDecoder().decode(APILabelPreview.self, from: data), preview)

        let labelInfo = try XCTUnwrap(OpenAPI.component("LabelInfo")).fields.map(\.name)
        let labelPreview = try XCTUnwrap(OpenAPI.component("LabelPreview")).fields.map(\.name)
        XCTAssertEqual(Set(labelPreview), Set(labelInfo).union(["width", "height", "png"]))
    }

    // MARK: Upload types

    /// MCP's content_base64, HTTP uploads and the clipboard read one table of formats.
    func testUploadTypesComeFromOneTable() throws {
        let samples: [(Data, String)] = [
            (Data("%PDF-1.4\n".utf8), "pdf"),
            (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "png"),
            (Data([0xFF, 0xD8, 0xFF, 0xE0]), "jpg"),
            (Data("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8), "svg"),
            (Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00]), "tiff"),
            (Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x08]), "tiff"),
            (Data("GIF89a".utf8), "gif"),
            (Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0]), "heic"),
        ]
        for (data, ext) in samples {
            let mime = try XCTUnwrap(MCPTools.sniff(data), ext)
            XCTAssertEqual(try APIRoutes.uploadName(nil, contentType: mime, index: 0), "Upload 1.\(ext)", ext)
            XCTAssertEqual(try APIRoutes.uploadName("label", contentType: mime, index: 0), "label.\(ext)", ext)
        }
        XCTAssertNil(MCPTools.sniff(Data("hello".utf8)))
        XCTAssertEqual(try APIRoutes.uploadName(nil, contentType: "image/gif; charset=binary", index: 1), "Upload 2.gif")
        XCTAssertThrowsError(try APIRoutes.uploadName(nil, contentType: "text/plain", index: 0))
        XCTAssertEqual(Intake.dataTypes.map(\.1), Intake.formats.map(\.ext))
    }

    // MARK: Empty request values

    /// An empty or blank value counts as not given, for HTTP forms, queries and MCP arguments alike.
    func testBlankRequestValuesAreMissing() throws {
        let r = APIPrintRequest(path: "", printer: "", size: " ", fit: "", ink: "\n")
        XCTAssertEqual(r, APIPrintRequest())
        let merged = try APIRoutes.merge(APIPrintRequest(), query: ["printer": "", "size": "", "copies": ""])
        XCTAssertEqual(merged, APIPrintRequest())
        var raw = APIPrintRequest()
        raw.printer = "  "
        XCTAssertNil(raw.normalized.printer)
        XCTAssertEqual(APIPrintRequest(printer: "Zebra").printer, "Zebra")
    }

    /// An empty printer leaves the rule's printer in charge, as leaving it out does.
    func testEmptyPrinterDoesNotOverrideTheRule() async throws {
        let store = Store(settings: .memory())
        let eligible = store.eligiblePrinters
        guard eligible.count >= 2, let current = store.printer, let other = eligible.first(where: { $0.name != current.name }) else {
            throw XCTSkip("needs two printer queues (nothing is sent to them)")
        }
        let service = AppLabelService(store: store, sender: { _, _, _, _ in "never" })
        service.rules = RuleEngine(fileURL: nil)
        var rule = Rule(name: "From apps", conditions: [RuleCondition(field: .trigger, op: .is, values: [RuleTrigger.api.rawValue])])
        rule.outcome.printer = other.name
        service.rules.add(rule)
        let file = try JobFlowTests.twoPagePDF()
        var request = APIPrintRequest()
        request.printer = ""
        let plan = try await service.plan([file], request)
        XCTAssertEqual(plan.printer.name, other.name)
        XCTAssertEqual(plan.rule, "From apps")
    }

    // MARK: Test label

    /// Before printing: Show preview holds the test label for Print too.
    func testTestLabelFollowsShowPreview() throws {
        let store = Store(settings: .memory())
        let printer = RulesPreviewData.printers[0]
        XCTAssertFalse(try XCTUnwrap(JobFlow.testLabelPlan(printer: printer, store: store, review: false)).review)
        store.alwaysReview = true
        XCTAssertTrue(try XCTUnwrap(JobFlow.testLabelPlan(printer: printer, store: store, review: false)).review)
    }

    // MARK: Typed-in settings

    /// Settings tidies what MCP refuses, with the same rules from PeelGoodCore.
    func testTypedSettingsShareOneCheck() throws {
        XCTAssertThrowsError(try Limits.renameSuffix(" /done"))
        XCTAssertThrowsError(try Limits.renameSuffix("a:b"))
        XCTAssertThrowsError(try Limits.renameSuffix(String(repeating: "a", count: Limits.renameSuffixLength + 1)))
        XCTAssertEqual(try Limits.renameSuffix(" printed"), " printed")
        XCTAssertEqual(Limits.tidyRenameSuffix(" /do:ne"), " done")
        XCTAssertEqual(Limits.tidyRenameSuffix(String(repeating: "a", count: 80)).count, Limits.renameSuffixLength)

        XCTAssertThrowsError(try Limits.tagName("  "))
        XCTAssertThrowsError(try Limits.tagName(String(repeating: "t", count: Limits.tagNameLength + 1)))
        XCTAssertEqual(Limits.tidyTagName("", previous: "Printed"), "Printed")
        XCTAssertEqual(Limits.tidyTagName(String(repeating: "t", count: 80), previous: "Printed").count, Limits.tagNameLength)

        XCTAssertEqual(Limits.clampNudge(CGPoint(x: 25, y: -30)), CGPoint(x: Limits.nudgeMM.upperBound, y: Limits.nudgeMM.lowerBound))
        XCTAssertEqual(Limits.clampNudge(CGPoint(x: 1.5, y: -2)), CGPoint(x: 1.5, y: -2))

        let config = configurator()
        XCTAssertEqual(code { try config.updateSettings(["renameSuffix": " /done"]) }, "invalid_renameSuffix")
        XCTAssertEqual(code { try config.updateSettings(["renameSuffix": String(repeating: "a", count: 65)]) }, "invalid_renameSuffix")
        XCTAssertEqual(code { try config.updateSettings(["tagName": ""]) }, "invalid_tagName")
        XCTAssertEqual(code { try config.updateSettings(["tagName": String(repeating: "t", count: 65)]) }, "invalid_tagName")
        XCTAssertEqual(code { try config.setPrinterSettings(["printer": config.store.printers.first?.name ?? "x", "nudgeXmm": 25]) },
                       config.store.printers.isEmpty ? "printer_not_found" : "invalid_nudgeXmm")
    }

    // MARK: Rules over MCP

    /// add_rule checks fit and ink like set_printer_settings (any letter case) and refuses unknown printers.
    func testAddRuleChecksFitInkAndPrinter() throws {
        let config = configurator()
        let conditions: [[String: Any]] = [["field": "trigger", "op": "is", "values": ["api"]]]
        let added = try config.addRule(["name": "Photos", "conditions": conditions, "outcome": ["ink": "Photo", "fit": "FILL"]])
        let outcome = try XCTUnwrap(added["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["ink"] as? String, "photo")
        XCTAssertEqual(outcome["fit"] as? String, "fill")
        XCTAssertEqual(config.rules.rules.first?.outcome.ink, .photo)

        XCTAssertEqual(code { try config.addRule(["name": "Bad", "conditions": conditions, "outcome": ["ink": "photoo"]]) }, "invalid_ink")
        XCTAssertEqual(code { try config.addRule(["name": "Bad", "conditions": conditions, "outcome": ["fit": "stretch"]]) }, "invalid_fit")
        XCTAssertEqual(code { try config.addRule(["name": "Bad", "conditions": conditions, "outcome": ["printer": "No_Such_Printer_42"]]) },
                       "printer_not_found")
        XCTAssertEqual(config.rules.rules.count, 1, "nothing bad was added")

        let empty = try config.addRule(["name": "Default", "conditions": conditions, "outcome": ["printer": ""]])
        XCTAssertNil((empty["outcome"] as? [String: Any])?["printer"], "an empty printer means the default")

        if let p = config.store.eligiblePrinters.first {
            let byDisplay = try config.addRule(["name": "Named", "conditions": conditions, "outcome": ["printer": p.displayName.uppercased()]])
            if PrinterResolver.match(p.displayName.uppercased(), in: config.store.eligiblePrinters)?.name == p.name {
                XCTAssertEqual((byDisplay["outcome"] as? [String: Any])?["printer"] as? String, p.name, "stored as the queue name")
            }
        }
    }

    /// A rule's printer reads the way printing matches it: by display name too.
    func testRuleSummaryMatchesPrintersLikePrinting() {
        let printers = RulesPreviewData.printers
        XCTAssertEqual(RuleSummary.printerName(printers[0].displayName, printers: printers), printers[0].displayName)
        XCTAssertEqual(RuleSummary.printerName(printers[1].name.lowercased(), printers: printers), printers[1].displayName)
        XCTAssertEqual(RuleSummary.printerName("Gone_Printer", printers: printers), "Gone Printer (not connected)")
        XCTAssertEqual(PrinterInfo.displayName(queue: "Gone_Printer"), "Gone Printer")
    }

    // MARK: Finder tag

    /// General's tag is built in one place; RuleTag decides whether it applies.
    func testGeneralTagIsBuiltOnce() {
        let settings = AppSettings.memory()
        settings.tagName = "Sent"
        settings.tagColor = .blue
        XCTAssertEqual(settings.generalTag, FinderTag(name: "Sent", color: .blue))
        XCTAssertEqual(RuleTag.general.resolve(settings), settings.generalTag)
        settings.tagAfterPrint = false
        XCTAssertEqual(settings.generalTag, FinderTag(name: "Sent", color: .blue))
        XCTAssertNil(RuleTag.general.resolve(settings))
    }
}
