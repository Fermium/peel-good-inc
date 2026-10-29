import Foundation
import XCTest
@testable import LabelizeApp

/// The API against `MockLabelService`: nothing here reaches a printer.
@MainActor
final class APITests: XCTestCase {
    let port = 47_377
    let keys = ["apiHTTPEnabled", "apiMCPEnabled", "apiPort"]

    override func tearDown() async throws {
        let api = APIController.shared
        api.httpEnabled = false
        api.mcpEnabled = false
        try await waitFor { api.status == .off }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func testOpenAPIExamplesMatchSchemas() {
        XCTAssertEqual(OpenAPI.selfCheck(), [])
        let doc = OpenAPI.document(port: port)
        XCTAssertEqual(doc["openapi"]?.stringValue, "3.1.0")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(doc.serialized().utf8)))
    }

    func testMultipart() throws {
        let body = "--XyZ\r\nContent-Disposition: form-data; name=\"size\"\r\n\r\n4x6\r\n--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.pdf\"\r\nContent-Type: application/pdf\r\n\r\n%PDF-1.4\r\nbinary\r\n--XyZ--\r\n"
        let form = try Multipart(data: Data(body.utf8), boundary: "XyZ")
        XCTAssertEqual(form.field("size"), "4x6")
        XCTAssertEqual(form.files.count, 1)
        XCTAssertEqual(form.files[0].filename, "a.pdf")
        XCTAssertEqual(String(decoding: form.files[0].data, as: UTF8.self), "%PDF-1.4\r\nbinary")
    }

    func testSwitchesStartAndStopLive() async throws {
        let api = APIController.shared
        let mock = MockLabelService()
        UserDefaults.standard.set(port, forKey: "apiPort")
        api.attach(mock)
        XCTAssertEqual(api.status, .off, "both switches are off by default")

        api.httpEnabled = true
        try await waitFor { api.status == .running(port: self.port) }
        var (status, _) = try await get("/v1/health")
        XCTAssertEqual(status, 200)
        (status, _) = try await post("/mcp", initialize)
        XCTAssertEqual(status, 404, "MCP is still off")

        api.mcpEnabled = true
        try await waitFor { api.status == .running(port: self.port) }
        (status, _) = try await post("/mcp", initialize)
        XCTAssertEqual(status, 200)

        api.httpEnabled = false
        try await waitFor { api.status == .running(port: self.port) }
        (status, _) = try await get("/v1/health")
        XCTAssertEqual(status, 404, "HTTP API off, MCP still on")
        (status, _) = try await get("/")
        XCTAssertEqual(status, 404)

        api.httpEnabled = true
        api.port = port + 1
        try await waitFor { api.status == .running(port: self.port + 1) }
        (status, _) = try await get("/v1/health", port: port + 1)
        XCTAssertEqual(status, 200)
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: APISettings.serverInfoURL)) as? [String: Any]
        XCTAssertEqual(info?["port"] as? Int, port + 1)

        // Print through the API reaches only the mock.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("api-test.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: file)
        (status, _) = try await post("/v1/print", "{\"path\": \"\(file.path)\", \"copies\": 2}", json: true, port: port + 1)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(mock.printed.count, 1)
        XCTAssertEqual(mock.printed.first?.request.copies, 2)

        api.httpEnabled = false
        api.mcpEnabled = false
        try await waitFor { api.status == .off }
        XCTAssertFalse(FileManager.default.fileExists(atPath: APISettings.serverInfoURL.path))
        do {
            _ = try await get("/v1/health", port: port + 1)
            XCTFail("server should be stopped")
        } catch {}
    }

    // MARK: Helpers

    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#

    private func request(_ path: String, port: Int?) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port ?? self.port)\(path)")!)
        r.setValue("Bearer \(APIController.shared.token)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 5
        return r
    }

    private func get(_ path: String, port: Int? = nil) async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(for: request(path, port: port))
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    private func post(_ path: String, _ body: String, json: Bool = true, port: Int? = nil) async throws -> (Int, Data) {
        var r = request(path, port: port)
        r.httpMethod = "POST"
        r.httpBody = Data(body.utf8)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: r)
        var data = Data()
        for try await line in bytes.lines {
            data.append(contentsOf: Array(line.utf8))
            if line.hasPrefix("data: {") { break }   // SSE: first message is enough
        }
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out, status \(APIController.shared.status)"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}
