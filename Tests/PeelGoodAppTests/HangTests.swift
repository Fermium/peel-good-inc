import Darwin
import Foundation
import LabelKit
import XCTest
@testable import PeelGoodApp

/// Issue #10: 0.6.0 stopped answering MCP and HTTP. A bot's `preview_label` by path ran `open()` on the main thread
/// while macOS was asking whether the app may read ~/Downloads; nobody answered, so `open()` never returned and
/// nothing that needs the main thread (health, list_jobs, every tool) answered again.
///
/// A named pipe stands in for that prompt: opening it for reading blocks in the kernel until a writer comes, just
/// like `open()` on a folder macOS is still asking about. A watchdog opens the writer after `watchdog` seconds, so
/// a regression fails on timing instead of hanging the suite. Runs on CI: nothing reaches a printer.
@MainActor
final class HangTests: XCTestCase {
    let port = 47_379
    let keys = ["apiHTTPEnabled", "apiMCPEnabled", "apiPort", "apiMCPLocalFiles"]
    let watchdog: TimeInterval = 20
    var pipe: URL!
    var savedLimit: TimeInterval = 0

    override func setUp() async throws {
        savedLimit = FileAccess.limit
        FileAccess.limit = 2
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pipe = folder.appendingPathComponent("order-1496-label.pdf")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
    }

    override func tearDown() async throws {
        Self.unblock(pipe)
        FileAccess.limit = savedLimit
        let api = APIController.shared
        api.httpEnabled = false
        api.mcpEnabled = false
        for _ in 0..<100 where api.status != .off { try await Task.sleep(for: .milliseconds(50)) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try? FileManager.default.removeItem(at: pipe.deletingLastPathComponent())
    }

    /// Opens the pipe's write end if a reader is waiting, which lets the reader's `open()` return.
    nonisolated static func unblock(_ url: URL) {
        let fd = open(url.path, O_WRONLY | O_NONBLOCK)
        if fd >= 0 { close(fd) }
    }

    func testHealthAndListJobsAnswerWhileAPreviewWaitsOnOpen() async throws {
        let api = APIController.shared
        UserDefaults.standard.set(port, forKey: "apiPort")
        api.attach(MockLabelService(), configurator: AppConfigurator(store: Store(), rules: RuleEngine(fileURL: nil), folders: .inMemory()))
        api.mcpCanUseLocalFiles = true
        api.httpEnabled = true
        api.mcpEnabled = true
        for _ in 0..<100 where api.status != .running(port: port) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(api.status, .running(port: port))

        let client = Client(port: port, token: api.token)
        let session = try await client.session()
        let pipe = pipe!, watchdog = watchdog
        // From `watchdog` seconds on, keep freeing anything stuck on the pipe until the test ends.
        let stop = Flag()
        defer { stop.set() }
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: watchdog)
            while !stop.isSet { Self.unblock(pipe); Thread.sleep(forTimeInterval: 0.25) }
        }

        // Everything runs off the main actor, so a blocked main thread shows up in the timings below.
        let started = Date()
        let preview = Task.detached { try await client.tool(session, id: 10, "preview_label", ["path": pipe.path, "fit": "fit-page"], timeout: watchdog + 10) }
        let others = Task.detached { () -> (health: String, healthAt: TimeInterval, jobs: String, jobsAt: TimeInterval) in
            try? await Task.sleep(for: .milliseconds(500))
            let health: String
            do { health = "\(try await client.get("/v1/health").0)" } catch { health = "\(error)" }
            let healthAt = Date().timeIntervalSince(started)
            let jobs: String
            do { jobs = try await client.tool(session, id: 11, "list_jobs", [:]) } catch { jobs = "\(error)" }
            return (health, healthAt, jobs, Date().timeIntervalSince(started))
        }

        // While the preview is out, health and list_jobs (same MCP session) answer straight away.
        let o = await others.value
        XCTAssertEqual(o.health, "200")
        XCTAssertLessThan(o.healthAt, 2, "health waited for the stuck preview")
        XCTAssertTrue(o.jobs.contains("\"result\""), o.jobs)
        XCTAssertLessThan(o.jobsAt, 3, "list_jobs waited for the stuck preview")

        // The stuck call itself gives up with a clear error long before the watchdog would free it.
        let reply: String
        do { reply = try await preview.value } catch { reply = "\(error)" }
        let previewAt = Date().timeIntervalSince(started)
        XCTAssertTrue(reply.contains("file_access_waiting"), reply)
        XCTAssertLessThan(previewAt, watchdog - 5, "preview_label waited for the open")

        // A second try while that open is still out answers at once instead of parking another thread.
        let t = Date()
        let again = await Task.detached { do { return try await client.tool(session, id: 12, "preview_label", ["path": pipe.path]) } catch { return "\(error)" } }.value
        XCTAssertTrue(again.contains("file_access_waiting"), again)
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
    }

    func testProbeReportsWaitingThenRecovers() async throws {
        let first = await FileAccess.probe(pipe, limit: 0.5)
        XCTAssertEqual(first, .waiting)
        Self.unblock(pipe)
        var outcome = FileAccess.Outcome.waiting
        for _ in 0..<40 where outcome == .waiting {
            try await Task.sleep(for: .milliseconds(50))
            let file = pipe.deletingLastPathComponent().appendingPathComponent("plain.pdf")
            try Data("%PDF-1.4\n".utf8).write(to: file)
            outcome = await FileAccess.probe(file, limit: 0.5)
        }
        XCTAssertEqual(outcome, .readable, "the folder opens again once the stuck open returns")
    }

    // MARK: Helpers

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// HTTP and MCP over the real listener, from any thread.
    struct Client: Sendable {
        let port: Int
        let token: String

        func request(_ path: String, timeout: TimeInterval) -> URLRequest {
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.timeoutInterval = timeout
            return r
        }

        func get(_ path: String) async throws -> (Int, Data) {
            let (data, response) = try await URLSession.shared.data(for: request(path, timeout: 3))
            return ((response as! HTTPURLResponse).statusCode, data)
        }

        /// POSTs a JSON-RPC message to /mcp; returns the session header and the first SSE data line.
        func mcp(_ body: [String: Any], session: String?, timeout: TimeInterval = 3) async throws -> (String?, String) {
            var r = request("/mcp", timeout: timeout)
            r.httpMethod = "POST"
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            r.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
            if let session { r.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            let (bytes, response) = try await URLSession.shared.bytes(for: r)
            var text = ""
            if body["id"] != nil {
                for try await line in bytes.lines where line.hasPrefix("data: {") {
                    text = String(line.dropFirst(6))
                    break
                }
            }
            return ((response as! HTTPURLResponse).value(forHTTPHeaderField: "Mcp-Session-Id"), text)
        }

        func session() async throws -> String {
            let (session, _) = try await mcp(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                              "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                                         "clientInfo": ["name": "test", "version": "1"]]], session: nil)
            let id = try XCTUnwrap(session)
            _ = try await mcp(["jsonrpc": "2.0", "method": "notifications/initialized"], session: id)
            return id
        }

        func tool(_ session: String, id: Int, _ name: String, _ args: [String: Any], timeout: TimeInterval = 3) async throws -> String {
            try await mcp(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": args]],
                          session: session, timeout: timeout).1
        }
    }
}
