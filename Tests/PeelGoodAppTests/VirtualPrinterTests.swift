import Foundation
import LabelKit
import Synchronization
import XCTest
@testable import PeelGoodApp

/// The IPP printer, without CUPS or a socket: messages in, messages out, documents in a temp inbox.
final class VirtualPrinterTests: XCTestCase {
    private func request(_ op: VirtualPrinter.Operation, _ attributes: [IPPAttribute] = [], data: Data = Data()) -> IPPMessage {
        IPPMessage(code: op.rawValue, requestID: 7, groups: [IPPGroup(tag: IPPTag.operation, attributes: [
            IPPAttribute("attributes-charset", .charset("utf-8")),
            IPPAttribute("attributes-natural-language", .language("en")),
            IPPAttribute("printer-uri", .uri(VirtualPrinter.uri)),
        ] + attributes)], data: data)
    }

    func testCodecRoundTrips() throws {
        var m = request(.printJob, [IPPAttribute("copies", .integer(2)), IPPAttribute("which", [.keyword("a"), .keyword("b")]),
                                    IPPAttribute("media-col", .collection([IPPAttribute("media-size-name", .keyword("oe_4x6-label_4x6in"))]))],
                        data: Data("%PDF-1.4 body".utf8))
        m.groups.append(IPPGroup(tag: IPPTag.job, attributes: [IPPAttribute("range", .range(1, 99)), IPPAttribute("res", .resolution(203, 203))]))
        XCTAssertEqual(try IPPCodec.decode(IPPCodec.encode(m)), m)
        XCTAssertThrowsError(try IPPCodec.decode(Data([2, 0, 0])))
    }

    func testAnswersLikeAPrinterCUPSCanUse() throws {
        let printer = VirtualPrinter { _, _, _ in }
        let reply = printer.handle(request(.getPrinterAttributes))
        XCTAssertEqual(reply.code, VirtualPrinter.Status.ok.rawValue)
        XCTAssertEqual(reply.requestID, 7)
        XCTAssertEqual(reply.groups.first?.attributes.first?.name, "attributes-charset", "charset comes first")
        XCTAssertEqual(reply.string("document-format-supported"), "application/pdf")
        let media = reply.attribute("media-supported")?.values.compactMap(\.string) ?? []
        XCTAssertTrue(media.contains("oe_4x6-label_4x6in") && media.contains("om_100x150mm_100x150mm"))
        let ops = Set(reply.attribute("operations-supported")?.values.compactMap(\.int) ?? [])
        XCTAssertEqual(ops, [0x02, 0x04, 0x08, 0x09, 0x0A, 0x0B], "no Create-Job without Send-Document")
        XCTAssertEqual(printer.handle(request(.validateJob, [IPPAttribute("document-format", .mimeType("image/urf"))])).code,
                       VirtualPrinter.Status.documentFormatNotSupported.rawValue)
        XCTAssertEqual(printer.handle(IPPMessage(code: 0x0005, requestID: 1)).code, VirtualPrinter.Status.operationNotSupported.rawValue)
    }

    func testPrintJobLandsInTheInbox() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("ipp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inbox) }
        let got = Mutex<[(URL, String, String?)]>([])
        let printer = VirtualPrinter(folder: {
            let folder = inbox.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }) { file, title, media in got.withLock { $0.append((file, title, media)) } }
        let pdf = Data("%PDF-1.4 label".utf8)
        let reply = printer.handle(request(.printJob, [IPPAttribute("job-name", .name("Order 12/34: label")),
                                                       IPPAttribute("media", .keyword("oe_4x6-label_4x6in"))], data: pdf))
        XCTAssertEqual(reply.code, VirtualPrinter.Status.ok.rawValue)
        let id = try XCTUnwrap(reply.int("job-id"))
        XCTAssertEqual(reply.int("job-state"), 9, "done once the app has it, so CUPS stops waiting")
        let received = got.withLock { $0 }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].0.lastPathComponent, "Order 12-34- label.pdf")
        XCTAssertEqual(try Data(contentsOf: received[0].0), pdf)
        XCTAssertEqual(received[0].1, "Order 12/34: label")
        XCTAssertEqual(received[0].2, "oe_4x6-label_4x6in")
        XCTAssertEqual(printer.handle(request(.getJobAttributes, [IPPAttribute("job-id", .integer(Int32(id)))])).int("job-state"), 9)
        XCTAssertEqual(printer.handle(request(.getJobAttributes, [IPPAttribute("job-id", .integer(999))])).code, VirtualPrinter.Status.notFound.rawValue)
        XCTAssertEqual(printer.handle(request(.printJob, data: Data("not a pdf".utf8))).code, VirtualPrinter.Status.documentFormatNotSupported.rawValue)
    }

    func testMediaNames() {
        for size in VirtualPrinter.sizes {
            XCTAssertEqual(LabelSize(pwgMedia: VirtualPrinter.mediaName(size)), size, VirtualPrinter.mediaName(size))
        }
        XCTAssertEqual(VirtualPrinter.mediaName(LabelSize(width: 2.25, height: 1.25)), "oe_2.25x1.25-label_2.25x1.25in")
        XCTAssertEqual(VirtualPrinter.title(fromJobName: "775 - Order 1234"), "Order 1234", "CUPS's job number goes")
        XCTAssertEqual(VirtualPrinter.title(fromJobName: "776 -   "), "Printed document", "one default, for title and file name")
        XCTAssertEqual(LabelSize(pwgMedia: "custom_min_1x0.5in"), LabelSize(width: 1, height: 0.5))
        XCTAssertEqual(VirtualPrinter.title(fromJobName: "Order - 1234"), "Order - 1234")
        XCTAssertEqual(VirtualPrinter.fileName(".hidden"), "_.hidden.pdf")
        XCTAssertFalse(Printers.all().contains { $0.name == Printers.virtualQueue }, "never prints to itself")
    }

    func testHostileInputIsRefused() throws {
        // Collections nested deeper than any real request: refused, not decoded until the stack runs out.
        var deep = IPPValue.integer(1)
        for _ in 0...IPPCodec.maxDepth { deep = .collection([IPPAttribute("x", deep)]) }
        let message = IPPMessage(code: 0x0002, requestID: 1, groups: [IPPGroup(tag: IPPTag.operation, attributes: [IPPAttribute("media-col", deep)])])
        XCTAssertThrowsError(try IPPCodec.decode(IPPCodec.encode(message)))
        var shallow = IPPValue.integer(1)
        for _ in 1..<IPPCodec.maxDepth { shallow = .collection([IPPAttribute("x", shallow)]) }
        XCTAssertNoThrow(try IPPCodec.decode(IPPCodec.encode(IPPMessage(code: 0x0002, requestID: 1, groups: [
            IPPGroup(tag: IPPTag.operation, attributes: [IPPAttribute("media-col", shallow)])]))))

        // Long titles are cut by bytes (file names hold 255 bytes, not characters).
        let name = VirtualPrinter.fileName(String(repeating: "é", count: 300) + "\u{7}")
        XCTAssertLessThanOrEqual(name.utf8.count, 204)
        XCTAssertTrue(name.hasSuffix(".pdf") && !name.contains("\u{7}"))
        XCTAssertEqual(VirtualPrinter.fileName("label.PDF"), "label.pdf")

        // Only this Mac by its own name, and never a web page (DNS rebinding).
        XCTAssertTrue(IPPServer.isLocal(["host": "127.0.0.1:47312"], port: 47312))
        XCTAssertTrue(IPPServer.isLocal(["host": "LOCALHOST:47312"], port: 47312))
        XCTAssertFalse(IPPServer.isLocal([:], port: 47312))
        XCTAssertFalse(IPPServer.isLocal(["host": "evil.example:47312"], port: 47312))
        XCTAssertFalse(IPPServer.isLocal(["host": "127.0.0.1:47312", "origin": "http://evil.example"], port: 47312))

        // One copy is all the Print dialog offers: the rules set copies.
        let attrs = VirtualPrinter { _, _, _ in }.handle(request(.getPrinterAttributes))
        XCTAssertEqual(attrs.attribute("copies-supported")?.values, [.range(1, 1)])
    }
}
