import Foundation
import LabelKit
import LabelizeCore
import MCP
import XCTest
@testable import LabelizeApp

/// The app on LabelizeCore: in-memory settings, sample printers; nothing prints.
@MainActor
final class CoreParityTests: XCTestCase {
    /// Print Test Label prints on the printer it's shown for and leaves the default printer alone.
    func testTestLabelDoesNotChangeTheDefaultPrinter() throws {
        let store = Store(settings: .memory())
        let printer = RulesPreviewData.printers[0]
        store.setInk(.photo, for: printer)
        let plan = try XCTUnwrap(JobFlow.testLabelPlan(printer: printer, store: store, review: false))
        XCTAssertNil(store.settings.printerName, "the default printer didn't change")
        XCTAssertEqual(plan.printer.name, printer.name)
        XCTAssertEqual(plan.options.ink, .crisp)
        XCTAssertEqual(plan.options.rotation, .none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.files[0].path))
        XCTAssertNil(plan.decision)
    }

    /// Store reads and writes through AppSettings, the same keys the CLI reads.
    func testStoreIsAppSettings() {
        let settings = AppSettings.memory()
        let store = Store(settings: settings)
        let p = RulesPreviewData.printers[0]
        store.setSize(LabelSize(width: 4, height: 4), for: p)
        store.setToneGamma(0.8, for: p)
        store.hiddenPrinters = ["X"]
        XCTAssertEqual(settings.savedSize(p.name), LabelSize(width: 4, height: 4))
        XCTAssertEqual(settings.options(for: p).options.toneGamma, 0.8, accuracy: 1e-9)
        XCTAssertEqual(settings.string("size.\(p.name)"), "4x4")
        XCTAssertEqual(store.options(for: p).size, settings.options(for: p).options.size)
        XCTAssertEqual(settings.hiddenPrinters, ["X"])
    }

    /// A rule's tag: Default follows General, None and Custom are the rule's, General off tags nothing.
    func testPlanTagFollowsRuleTag() {
        let settings = AppSettings.memory()
        settings.tagName = "Shipped"
        XCTAssertEqual(RuleTag.general.resolve(settings), FinderTag(name: "Shipped", color: .green))
        settings.tagAfterPrint = false
        XCTAssertNil(RuleTag.custom(FinderTag(name: "Mine")).resolve(settings))
    }

    /// MCP's and OpenAPI's lists and ranges come from Limits and LabelKit.
    func testSchemasUseLimits() throws {
        let print = try XCTUnwrap(MCPTools.catalog.first { $0.tool.name == "print_label" }?.tool)
        let props = print.inputSchema.objectValue?["properties"]?.objectValue
        XCTAssertEqual(props?["copies"]?.objectValue?["maximum"]?.intValue, Limits.copies.upperBound)
        XCTAssertEqual(props?["ink"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue), Limits.inks)
        let printer = try XCTUnwrap(MCPTools.catalog.first { $0.tool.name == "set_printer_settings" }?.tool)
        let cutoff = printer.inputSchema.objectValue?["properties"]?.objectValue?["cutoff"]?.objectValue
        XCTAssertEqual(cutoff?["minimum"]?.doubleValue, Limits.cutoff.lowerBound)
        XCTAssertEqual(cutoff?["maximum"]?.doubleValue, Limits.cutoff.upperBound)
        let doc = OpenAPI.document(port: 47311).serialized(pretty: false)
        XCTAssertTrue(doc.contains("\"maximum\":\(Limits.copies.upperBound)"), "OpenAPI copies")
        XCTAssertTrue(doc.contains(Limits.inks.map { "\"\($0)\"" }.joined(separator: ",")), "OpenAPI inks")
    }
}
