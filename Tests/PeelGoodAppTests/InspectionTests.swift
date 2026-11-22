import CoreGraphics
import Foundation
import LabelKit
import PeelGoodCore
import XCTest
@testable import PeelGoodApp

/// Issue #6: Vision text recognition stuck on a batch of photos took every thread of the Swift concurrency pool,
/// and every print, preview and drop waited behind it forever. Reading a file for the rules must not need that pool.
/// No printer needed, so these run on CI.
final class InspectionTests: XCTestCase {
    func testInspectionRunsWhileTheConcurrencyPoolIsBusy() throws {
        let file = try Self.pdf()
        defer { try? FileManager.default.removeItem(at: file) }

        // Take every default-priority thread of the pool, the way the stuck OCR calls did.
        let release = DispatchSemaphore(value: 0)
        let blockers = ProcessInfo.processInfo.activeProcessorCount * 2
        defer { for _ in 0..<blockers { release.signal() } }
        for _ in 0..<blockers { Task.detached { release.wait() } }
        Thread.sleep(forTimeInterval: 0.3)

        let done = DispatchSemaphore(value: 0)
        let result = Result()
        Task.detached(priority: .high) {
            result.context = await JobFlow.inspect(file, trigger: .api, codes: true, text: true)
            done.signal()
        }
        // The wait is on this thread, not the pool, so a regression fails here instead of hanging the suite.
        XCTAssertEqual(done.wait(timeout: .now() + 15), .success, "inspection waited for the busy concurrency pool")
        XCTAssertEqual(result.context?.kind, .pdf)
        XCTAssertEqual(result.context?.pageText?.contains("HELLO"), true)
        XCTAssertEqual(result.context?.unread, [])
    }

    func testQuickFactsSayWhatsMissing() {
        let ctx = RuleContext.quick(URL(fileURLWithPath: "/tmp/label.pdf"), trigger: .api, wanted: (codes: false, text: true))
        XCTAssertEqual(ctx.unread, [RuleContext.unreadFile, RuleContext.unreadText])
        XCTAssertEqual(ctx.kind, .pdf)
        XCTAssertEqual(ctx.fileName, "label.pdf")
    }

    @MainActor
    func testDeadlineStopsWorkThatRunsOver() async throws {
        struct Late: Error {}
        let started = Date()
        do {
            _ = try await Deadline.run(0.2, orThrow: Late()) { try await Task.sleep(for: .seconds(30)); return 1 }
            XCTFail("should have timed out")
        } catch is Late {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let value = try await Deadline.run(5, orThrow: Late()) { 7 }
        XCTAssertEqual(value, 7)
    }

    func testRulesOnTextThatCouldntBeReadDontMatch() {
        var ctx = RuleContext(trigger: .api, fileName: "IMG_1.HEIC", kind: .image, isRaster: true)
        ctx.unread = [RuleContext.unreadText]
        let has = Rule(name: "Has", conditions: [RuleCondition(field: .pageText, op: .contains, values: ["Royal Mail"])])
        let hasNot = Rule(name: "Has not", conditions: [RuleCondition(field: .pageText, op: .doesNotContain, values: ["Royal Mail"])])
        XCTAssertFalse(has.matches(ctx))
        XCTAssertFalse(hasNot.matches(ctx))
        ctx.unread = []
        ctx.pageText = ""
        XCTAssertTrue(hasNot.matches(ctx))
    }

    private final class Result: @unchecked Sendable { var context: RuleContext? }

    static func pdf() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inspect-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 288, height: 432)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        ctx.beginPDFPage(nil)
        let attributed = NSAttributedString(string: "HELLO", attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 36, nil)])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 40, y: 200)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }
}
