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
        /// The real Keychain takes a while, which is when a poll and a stream overlap.
        var delay: TimeInterval = 0
        func secret(for source: UUID) throws -> String? {
            Thread.sleep(forTimeInterval: delay)
            return values[source]
        }
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

        // Editing keeps the history, and a blank key keeps the saved one.
        var renamed = remote.sources[0]
        renamed.name = "Renamed"
        try await remote.update(renamed, secret: "")
        XCTAssertEqual(secrets.values[source.id], "SECRET")
        try await waitFor { remote.live[source.id]?.entries.contains { $0.name == "order 1459.pdf" && $0.state == .sent } == true }
        XCTAssertEqual(sent.all.filter { $0.contains("order 1459") }.count, 1, "editing doesn't reprint")

        remote.remove(source.id)
        try await waitFor { secrets.values[source.id] == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.remote.appendingPathComponent(source.id.uuidString).path))
    }

    func testAServerStreamPrintsWithItsCopiesOnceARuleSaysSo() async throws {
        let store = Store()
        guard store.printer != nil else { throw XCTSkip("needs a printer queue (nothing is sent to it)") }
        UserDefaults.standard.set("print", forKey: "newFilesAction")
        UserDefaults.standard.set(false, forKey: "alwaysReview")
        defer { ["newFilesAction", "alwaysReview"].forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        try? FileManager.default.removeItem(at: AppPaths.remote)

        let server = FakeHTTP()
        try await server.start()
        defer { server.stop() }
        let pdf = FakeS3.pdf()
        server.handle { $0.path == "/events" ? .stream : .full(200, [:], pdf) }

        let sent = Sent(), copies = Sent()
        let remote = RemoteController(secrets: Secrets())
        remote.sender = { file, _, _, n in sent.add(file.lastPathComponent); copies.add("\(n)"); return "test-1" }
        remote.start(store: store)
        let source = RemoteSource(name: "Stream", kind: .http(HTTPSource(streamURL: "\(server.base)/events")))
        try await remote.add(source, secret: nil)
        try await waitFor { server.openStreams == 1 }
        try await waitFor { remote.live[source.id]?.status.isStreaming == true || server.openStreams == 1 }
        server.push("event: label\nid: 1\ndata: {\"id\":\"a\",\"url\":\"\(server.base)/a.pdf\",\"name\":\"order 7.pdf\",\"copies\":3}\n\n")
        try await waitFor { sent.all.count == 1 }
        XCTAssertTrue(sent.all[0].contains("order 7"))
        XCTAssertEqual(copies.all, ["3"], "the job's copies, through the rules")
        remote.remove(source.id)
    }

    /// A poll and a stream ask for a source's inbox at once. Two inboxes would each keep their own memory
    /// of what printed, and print the same job twice.
    func testOverlappingRequestsShareOneInbox() async throws {
        try? FileManager.default.removeItem(at: AppPaths.remote)
        let secrets = Secrets()
        secrets.delay = 0.2
        let remote = RemoteController(secrets: secrets)
        let source = RemoteSource(name: "Server", kind: .http(HTTPSource(jobsURL: "http://127.0.0.1:1/jobs", streamURL: "http://127.0.0.1:1/events")))
        async let a = remote.inbox(for: source)
        async let b = remote.inbox(for: source)
        let (first, second) = await (a, b)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    /// Whichever way a job arrives, it prints once.
    func testAJobOnBothTheStreamAndTheJobsListPrintsOnce() async throws {
        let store = Store()
        guard store.printer != nil else { throw XCTSkip("needs a printer queue (nothing is sent to it)") }
        UserDefaults.standard.set("print", forKey: "newFilesAction")
        UserDefaults.standard.set(false, forKey: "alwaysReview")
        defer { ["newFilesAction", "alwaysReview"].forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        try? FileManager.default.removeItem(at: AppPaths.remote)

        final class Listing: @unchecked Sendable { let lock = NSLock(); var jobs = Data(#"{"jobs":[]}"#.utf8) }
        let listing = Listing(), server = FakeHTTP()
        try await server.start()
        defer { server.stop() }
        let pdf = FakeS3.pdf()
        server.handle { r in
            switch r.path {
            case "/events": .stream
            case "/jobs": .full(200, [:], listing.lock.withLock { listing.jobs })
            default: .full(200, [:], pdf)
            }
        }
        let sent = Sent()
        let secrets = Secrets()
        secrets.delay = 0.3
        let remote = RemoteController(secrets: secrets)
        remote.sender = { file, _, _, _ in sent.add(file.lastPathComponent); return "test-1" }
        remote.start(store: store)
        var source = RemoteSource(name: "Server", kind: .http(HTTPSource(jobsURL: "\(server.base)/jobs", streamURL: "\(server.base)/events")))
        source.interval = 0.2
        try await remote.add(source, secret: nil)
        try await waitFor { server.openStreams == 1 && server.requests.filter { $0.path == "/jobs" }.count >= 2 }

        server.push("event: label\nid: 1\ndata: {\"id\":\"a\",\"url\":\"\(server.base)/a.pdf\"}\n\n")
        try await waitFor { sent.all.count == 1 }
        listing.lock.withLock { listing.jobs = Data(#"{"jobs":[{"id":"a","url":"\#(server.base)/a.pdf"}]}"#.utf8) }
        let polls = server.requests.count
        try await waitFor { server.requests.count > polls + 4 }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(sent.all.count, 1, "the poll knows the stream printed it")
        remote.remove(source.id)
    }

    private func waitFor(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
