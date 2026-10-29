import AppKit
import LabelKit
import LabelizeCore
import MCP
import XCTest
@testable import LabelizeApp

/// API prints go through the app's job flow: rules, countdown or review, and an outcome.
/// The sender is a stand-in, so nothing reaches a printer; the presenter shows nothing.
@MainActor
final class JobFlowTests: XCTestCase {
    final class Presenter: JobPresenter {
        var jobs: [PrintJob] = []
        func present(_ job: PrintJob) {
            jobs.append(job)
            job.start()
        }
    }

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, Int)] = []
        func add(_ file: URL, _ copies: Int) { lock.withLock { items.append((file.lastPathComponent, copies)) } }
        var all: [(String, Int)] { lock.withLock { items } }
    }

    var store: Store!
    var service: AppLabelService!
    var presenter: Presenter!
    var sent: Sent!
    var printer: PrinterInfo!
    var file: URL!
    let keys = ["countdown", "alwaysReview", "playSounds", "last.file", "last.printer", "last.size", "apiHTTPEnabled", "apiMCPEnabled", "historyDays"]

    override func setUp() async throws {
        store = Store()
        guard let p = store.printer else { throw XCTSkip("needs a printer queue (nothing is sent to it)") }
        printer = p
        UserDefaults.standard.set(0.2, forKey: "countdown")
        UserDefaults.standard.set(false, forKey: "alwaysReview")
        UserDefaults.standard.set(false, forKey: "playSounds")
        UserDefaults.standard.set(0, forKey: "historyDays")   // never prune the real history folder from a test
        let sent = Sent()
        self.sent = sent
        service = AppLabelService(store: store, sender: { file, _, _, copies in
            sent.add(file, copies)
            return "test-1"
        })
        service.rules = RuleEngine(fileURL: nil)
        presenter = Presenter()
        service.presenter = presenter
        file = try Self.twoPagePDF()
    }

    override func tearDown() async throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        if let printer { ["ink", "size", "fit"].forEach { UserDefaults.standard.removeObject(forKey: "\($0).\(printer.name)") } }
        // Labels the stand-in "printed" went to the history folder; take them back out.
        for job in service?.jobs() ?? [] { if let path = job.savedPDF { try? FileManager.default.removeItem(atPath: path) } }
    }

    func testCountdownPrintsEveryPageThroughThePresenter() async throws {
        let job = try await service.print(files: [file], request: APIPrintRequest(), source: APIJob.Source.upload)
        XCTAssertEqual(presenter.jobs.count, 1)
        XCTAssertFalse(presenter.jobs[0].reviewFirst)
        XCTAssertEqual(job.status, .printed)
        XCTAssertEqual(job.action, "countdown")
        XCTAssertEqual(job.rule, "Everything else")
        XCTAssertEqual(job.labels, 2, "every page prints")
        XCTAssertEqual(job.labelDetails?.count, 2)
        XCTAssertTrue(job.labelDetails!.allSatisfy { ["crisp", "photo"].contains($0.ink) && $0.scalePercent > 0 })
        XCTAssertEqual(sent.all.count, 1)
        XCTAssertEqual(job.printerJobID, "test-1")
    }

    func testAskFirstWaitsForPrint() async throws {
        UserDefaults.standard.set(true, forKey: "alwaysReview")
        let task = Task { try await service.print(files: [file], request: APIPrintRequest(), source: APIJob.Source.upload) }
        try await waitFor { self.presenter.jobs.first?.phase == .review }
        XCTAssertEqual(service.jobs().first?.status, .waiting)
        XCTAssertEqual(sent.all.count, 0, "nothing prints before Print")
        await presenter.jobs[0].send()   // the Print button
        let job = try await task.value
        XCTAssertEqual(job.status, .printed)
        XCTAssertEqual(job.action, "review")
        XCTAssertEqual(sent.all.count, 1)
    }

    func testCancelInThePopover() async throws {
        UserDefaults.standard.set(true, forKey: "alwaysReview")
        let task = Task { try await service.print(files: [file], request: APIPrintRequest(), source: APIJob.Source.upload) }
        try await waitFor { self.presenter.jobs.first?.phase == .review }
        presenter.jobs[0].cancel()
        let job = try await task.value
        XCTAssertEqual(job.status, .cancelled)
        XCTAssertEqual(sent.all.count, 0)
    }

    func testTimeoutReturnsWaitingAndJobsShowTheEnd() async throws {
        UserDefaults.standard.set(true, forKey: "alwaysReview")
        service.waitLimit = .milliseconds(1500)
        let job = try await service.print(files: [file], request: APIPrintRequest(), source: APIJob.Source.upload)
        XCTAssertEqual(job.status, .waiting)
        await presenter.jobs[0].send()
        XCTAssertEqual(service.jobs().first { $0.id == job.id }?.status, .printed)
    }

    func testRuleAppliesAndRequestOverridesIt() async throws {
        var rule = Rule(name: "From apps", conditions: [RuleCondition(field: .trigger, op: .is, values: [RuleTrigger.api.rawValue])])
        rule.outcome.ink = .photo
        rule.outcome.copies = 3
        service.rules.add(rule)

        var job = try await service.print(files: [file], request: APIPrintRequest(), source: APIJob.Source.upload)
        XCTAssertEqual(job.rule, "From apps")
        XCTAssertEqual(job.copies, 3)
        XCTAssertEqual(job.labelDetails?.map(\.ink), ["photo", "photo"])
        XCTAssertEqual(sent.all.last?.1, 3)

        job = try await service.print(files: [file], request: APIPrintRequest(ink: "crisp", copies: 1), source: APIJob.Source.upload)
        XCTAssertEqual(job.rule, "From apps")
        XCTAssertEqual(job.copies, 1)
        XCTAssertEqual(job.labelDetails?.map(\.ink), ["crisp", "crisp"])

        // A rule that previews waits for Print, like a drop.
        rule.outcome.action = .review
        service.rules.update(rule)
        let task = Task { try await service.print(files: [file], request: APIPrintRequest(), source: APIJob.Source.upload) }
        try await waitFor { self.presenter.jobs.last?.phase == .review }
        presenter.jobs.last!.cancel()
        let cancelled = try await task.value
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    func testReprintNamesDontPileUp() async throws {
        let first = try await service.print(files: [file], request: APIPrintRequest(), source: APIJob.Source.upload)
        let again = try await service.reprintLast(copies: nil)
        XCTAssertNil(again.rule)
        let name = URL(fileURLWithPath: try XCTUnwrap(again.savedPDF)).lastPathComponent
        XCTAssertTrue(name.hasSuffix(" two-pages.label.pdf"), name)
        XCTAssertEqual(name.components(separatedBy: "Z ").count, 2, name)
        XCTAssertNotNil(first.savedPDF)

        XCTAssertEqual(History.baseName(URL(fileURLWithPath: "/h/2026-10-29T20-57-08Z 2026-10-29T20-56-58Z test-label.label.label.pdf")), "test-label")
        XCTAssertEqual(History.baseName(URL(fileURLWithPath: "/h/order 1459.pdf")), "order 1459")
        XCTAssertEqual(History.baseName(URL(fileURLWithPath: "/h/2026-10-29T20-57-08Z .label.pdf")), "label")
    }

    func testPreviewReplyHasRuleAndNoEmptyPNG() async throws {
        let api = APIController.shared
        api.attach(service, configurator: AppConfigurator(store: store, rules: service.rules, folders: .inMemory()))
        let data = try Data(contentsOf: file).base64EncodedString()
        let r = await MCPTools.call(CallTool.Parameters(name: "preview_label", arguments: ["content_base64": .string(data), "filename": "a.pdf"]))
        XCTAssertNotEqual(r.isError, true)
        let text = r.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined()
        XCTAssertFalse(text.contains("\"png\""), text)
        XCTAssertTrue(text.contains("\"rule\" : \"Everything else\""), text)
        XCTAssertTrue(text.contains("\"ink\""))
        XCTAssertEqual(r.content.filter { if case .image = $0 { true } else { false } }.count, 2)
        // HTTP JSON keeps the base64 PNG it documents.
        let preview = try await service.preview(files: [file], request: APIPrintRequest())
        XCTAssertTrue(preview.images.allSatisfy { ($0.png?.count ?? 0) > 0 })
        XCTAssertTrue(sent.all.isEmpty, "preview never prints")
    }

    func testInkInSettingsIsWhatPrintUses() async throws {
        store.setInk(.photo, for: printer)
        XCTAssertEqual(service.printers().first { $0.name == printer.name }?.ink, "photo")
        let config = AppConfigurator(store: store, rules: service.rules, folders: .inMemory())
        let row = (config.settings()["printers"] as? [[String: Any]])?.first { $0["name"] as? String == printer.name }
        XCTAssertEqual(row?["ink"] as? String, "photo")
        XCTAssertEqual(store.options(for: printer).ink, .photo)
        let job = try await service.print(files: [file], request: APIPrintRequest(printer: printer.name), source: APIJob.Source.upload)
        XCTAssertEqual(job.labelDetails?.map(\.ink), ["photo", "photo"])
    }

    /// The API takes the action the rules decided: Everything else's saved action is ignored, as for a drop.
    func testAPIUsesTheDecidedAction() async throws {
        service.rules.fallback.outcome.action = .review
        let job = try await service.print(files: [file], request: APIPrintRequest(), source: APIJob.Source.upload)
        XCTAssertEqual(job.action, "countdown")
        XCTAssertEqual(job.status, .printed)

        var rule = Rule(name: "Ask me", conditions: [RuleCondition(field: .trigger, op: .is, values: [RuleTrigger.api.rawValue])])
        rule.outcome.action = .ask
        service.rules.add(rule)
        let plan = try await service.plan([file], APIPrintRequest())
        XCTAssertEqual(plan.action, .review, "Ask is the preview for files handed over")
        XCTAssertTrue(plan.review)
    }

    /// Print Clipboard (menu and MCP) is "From the clipboard", not "From another app".
    func testClipboardTrigger() async throws {
        let rule = Rule(name: "Clipboard", conditions: [RuleCondition(field: .trigger, op: .is, values: [RuleTrigger.clipboard.rawValue])])
        service.rules.add(rule)
        let viaClipboard = try await service.plan([file], APIPrintRequest(), trigger: .clipboard)
        XCTAssertEqual(viaClipboard.rule, "Clipboard")
        let viaAPI = try await service.plan([file], APIPrintRequest())
        XCTAssertEqual(viaAPI.rule, "Everything else")
    }

    // MARK: Helpers

    /// A 4x6 PDF with two pages of text and a box.
    static func twoPagePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("two-pages.pdf")
        var box = CGRect(x: 0, y: 0, width: 288, height: 432)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in 1...2 {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 20, y: 20, width: 248, height: 8))
            ctx.stroke(CGRect(x: 30, y: 60, width: 228, height: 300))
            let text = NSAttributedString(string: "Page \(page)", attributes: [.font: NSFont.boldSystemFont(ofSize: 36)])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(at: CGPoint(x: 60, y: 200))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
}
