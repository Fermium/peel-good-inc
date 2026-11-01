import Foundation
import LabelKit
import PeelGoodCore
import PeelGoodRemote
import PeelGoodShared
import RemoteTestSupport
import XCTest
@testable import PeelGoodApp

/// The whole path a label takes: a real run loop and S3 client against a local S3, then the rules,
/// up to a stand-in for the printer.
@MainActor
final class RemoteControllerTests: XCTestCase {
    final class Secrets: SecretStore, @unchecked Sendable {
        var values: [UUID: String] = [:]
        func secret(for source: UUID) throws -> String? { values[source] }
        func setSecret(_ secret: String?, for source: UUID) throws { values[source] = secret }
    }

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
    }

    func testALabelLandsInTheBucketAndWaitsForAPerson() async throws {
        let store = Store()
        guard store.printer != nil else { throw XCTSkip("needs a printer queue (nothing is sent to it)") }
        UserDefaults.standard.set("ask", forKey: "newFilesAction")
        UserDefaults.standard.set(false, forKey: "alwaysReview")
        defer { ["newFilesAction", "alwaysReview"].forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        try? FileManager.default.removeItem(at: AppPaths.remote)

        let s3 = FakeS3()
        try await s3.start()
        defer { s3.stop() }
        s3.clock = Date()
        s3.put("out/already-there.pdf", at: Date().addingTimeInterval(-86_400))

        let secrets = Secrets(), sent = Sent()
        let remote = RemoteController(secrets: secrets)
        remote.sender = { file, _, _, _ in sent.add(file.lastPathComponent); return "test-1" }
        var asked: [String] = []
        remote.ask = { name, _, _, _ in asked.append(name) }
        remote.start(store: store)
        var source = RemoteSource(name: "Orders", s3: s3.source)
        source.interval = 0.2
        try await remote.add(source, secret: "SECRET")
        XCTAssertEqual(secrets.values[source.id], "SECRET")
        XCTAssertFalse(String(decoding: try Data(contentsOf: AppPaths.remote.appendingPathComponent("sources.json")), as: UTF8.self).contains("SECRET"),
                       "the secret key stays out of the source list")

        try await waitFor { remote.live[source.id]?.status.skippedOnFirstCheck == 1 }

        s3.clock = Date()
        s3.put("out/order 1459.pdf")
        try await waitFor { remote.live[source.id]?.entries.contains { $0.state == .waiting } == true }
        XCTAssertEqual(sent.all, [], "nothing prints until a person or a rule says so")
        XCTAssertEqual(remote.waitingCount, 1)
        XCTAssertEqual(asked, ["order 1459.pdf"], "asked once")

        let item = try XCTUnwrap(remote.live[source.id]?.entries.first { $0.state == .waiting })
        XCTAssertEqual(item.name, "order 1459.pdf")
        remote.printNow(item.id, source: source.id)
        try await waitFor { remote.live[source.id]?.entries.contains { $0.state == .sent } == true }
        XCTAssertEqual(sent.all.count, 1)
        XCTAssertTrue(sent.all[0].contains("order 1459"), "the printer gets the composed label, named after the file")
        XCTAssertEqual(remote.waitingCount, 0)

        // Paused: a new file doesn't arrive until it resumes.
        remote.setPaused(true, source.id)
        s3.clock = Date()
        s3.put("out/second.pdf")
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(remote.live[source.id]?.entries.contains { $0.key == "out/second.pdf" } == true)
        remote.setPaused(false, source.id)
        try await waitFor { remote.live[source.id]?.entries.contains { $0.key == "out/second.pdf" } == true }

        remote.remove(source.id)
        try await waitFor { secrets.values[source.id] == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.remote.appendingPathComponent(source.id.uuidString).path))
    }

    private func waitFor(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
