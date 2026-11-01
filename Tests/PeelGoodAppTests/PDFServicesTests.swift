import Foundation
import XCTest
@testable import PeelGoodApp

/// The Print dialog's PDF menu item, in a temporary folder (never the real ~/Library/PDF Services).
final class PDFServicesTests: XCTestCase {
    func testInstallRepairAndRemove() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pdfservices-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = tmp.appendingPathComponent("PDF Services", isDirectory: true)
        let old = tmp.appendingPathComponent("Old/Peel Good Inc.app"), new = tmp.appendingPathComponent("Applications/Peel Good Inc.app")

        XCTAssertFalse(PDFServices.isInstalled(in: folder))
        try PDFServices.install(app: old, in: folder)
        XCTAssertEqual(PDFServices.entry(in: folder).lastPathComponent, "Print Label with Peel Good Inc.", "the menu item's title")
        XCTAssertEqual(PDFServices.destination(in: folder)?.path, old.path)

        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        PDFServices.repair(app: new, in: folder)
        XCTAssertEqual(PDFServices.destination(in: folder)?.path, old.path, "a working item is left alone")
        try FileManager.default.removeItem(at: old)
        PDFServices.repair(app: new, in: folder)
        XCTAssertEqual(PDFServices.destination(in: folder)?.path, new.path, "follows the app when it moves")
        PDFServices.repair(app: nil, in: folder)
        XCTAssertEqual(PDFServices.destination(in: folder)?.path, new.path, "a non-bundle build leaves it alone")

        try PDFServices.remove(from: folder)
        XCTAssertFalse(PDFServices.isInstalled(in: folder))
        try PDFServices.remove(from: folder)
        PDFServices.repair(app: new, in: folder)
        XCTAssertFalse(PDFServices.isInstalled(in: folder), "repair never adds it")
    }
}
