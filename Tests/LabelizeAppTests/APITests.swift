import Foundation
import MCP
import XCTest
@testable import LabelizeApp

/// The API against `MockLabelService`: nothing here reaches a printer.
@MainActor
final class APITests: XCTestCase {
    let port = 47_377
    let keys = ["apiHTTPEnabled", "apiMCPEnabled", "apiPort", "apiMCPLocalFiles", "apiMCPSettings", "playSounds", "tagColor"]

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
        api.attach(mock, configurator: memoryConfigurator())
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
        // A path on this Mac is refused over HTTP; only files sent with the request print.
        (status, _) = try await post("/v1/print", "{\"path\": \"\(file.path)\", \"copies\": 2}", port: port + 1)
        XCTAssertEqual(status, 415)
        (status, _) = try await post("/v1/print?path=\(file.path)", "%PDF-1.4\n", type: "application/pdf", port: port + 1)
        XCTAssertEqual(status, 400)
        (status, _) = try await post("/v1/print/clipboard", "", port: port + 1)
        XCTAssertEqual(status, 404)
        (status, _) = try await post("/v1/reprint", "", port: port + 1)
        XCTAssertEqual(status, 404)
        XCTAssertEqual(mock.printed.count, 0)
        let data: Data
        (status, data) = try await post("/v1/print?copies=2&filename=label.pdf", "%PDF-1.4\n", type: "application/pdf", port: port + 1)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(mock.printed.count, 1)
        XCTAssertEqual(mock.printed.first?.request.copies, 2)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("savedPDF"))
        let big = String(repeating: "x", count: APILimits.maxFileBytes + 1)
        (status, _) = try await post("/v1/print?filename=big.pdf", big, type: "application/pdf", port: port + 1)
        XCTAssertEqual(status, 413)

        api.httpEnabled = false
        api.mcpEnabled = false
        try await waitFor { api.status == .off }
        XCTAssertFalse(FileManager.default.fileExists(atPath: APISettings.serverInfoURL.path))
        do {
            _ = try await get("/v1/health", port: port + 1)
            XCTFail("server should be stopped")
        } catch {}
    }

    // MARK: MCP permissions

    func testMCPPermissions() async throws {
        let api = APIController.shared
        let mock = MockLabelService()
        let config = memoryConfigurator()
        api.attach(mock, configurator: config)
        api.mcpCanUseLocalFiles = false
        api.mcpCanChangeSettings = false
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: file)

        // Off: uploads and reading work; paths, clipboard, reprint and changes are refused, naming the setting.
        var r = await tool("print_label", ["content_base64": .string(Data("%PDF-1.4\n".utf8).base64EncodedString()), "filename": "a.pdf"])
        XCTAssertNotEqual(r.isError, true)
        for (name, args) in [("print_label", ["path": Value.string(file.path)]), ("preview_label", ["path": .string(file.path)]),
                             ("print_clipboard", [:]), ("reprint_last", [:])] as [(String, [String: Value])] {
            r = await tool(name, args)
            XCTAssertEqual(r.isError, true, name)
            XCTAssertTrue(text(r).contains("Let MCP print files from this Mac"), name)
        }
        r = await tool("update_settings", ["playSounds": false])
        XCTAssertTrue(text(r).contains("Let MCP change settings"))
        r = await tool("get_settings")
        XCTAssertNotEqual(r.isError, true)
        XCTAssertFalse(text(r).contains(api.token))
        XCTAssertEqual(mock.printed.count, 1)

        // On.
        api.mcpCanUseLocalFiles = true
        api.mcpCanChangeSettings = true
        r = await tool("print_label", ["path": .string(file.path)])
        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertEqual(mock.printed.count, 2)
        r = await tool("update_settings", ["playSounds": false, "tagColor": "blue"])
        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertFalse(config.store.playSounds)
        XCTAssertEqual(config.store.tagColor, .blue)

        // Never: its own switch, its permissions, the token.
        for key in ["mcpEnabled", "mcpCanUseLocalFiles", "mcpCanChangeSettings", "token"] {
            r = await tool("update_settings", [key: true])
            XCTAssertEqual(r.isError, true, key)
            XCTAssertTrue(text(r).contains("protected_setting"), key)
        }
        XCTAssertTrue(api.mcpCanUseLocalFiles && api.mcpCanChangeSettings)

        // Rules, in memory.
        r = await tool("add_rule", ["rule": ["name": "Amazon", "conditions": [["field": "source", "op": "is", "values": ["amazon.com"]]],
                                             "outcome": ["size": "4x6", "tag": ["name": "Done", "color": "red"]]]])
        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertEqual(config.rules.rules.count, 1)
        let id = config.rules.rules[0].id.uuidString
        XCTAssertEqual(config.rules.rules[0].outcome.tag?.color, .red)
        r = await tool("update_rule", ["id": .string(id), "rule": ["isEnabled": false]])
        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertEqual(config.rules.rules[0].isEnabled, false)
        XCTAssertEqual(config.rules.rules[0].conditions.first?.values, ["amazon.com"])
        r = await tool("add_rule", ["rule": ["name": "Bad", "conditions": [["field": "kind", "op": "contains", "values": ["pdf"]]]]])
        XCTAssertEqual(r.isError, true)
        r = await tool("update_rule", ["id": "everything-else", "rule": ["outcome": ["copies": 2]]])
        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertEqual(config.rules.fallback.outcome.copies, 2)
        r = await tool("delete_rule", ["id": .string(id)])
        XCTAssertNotEqual(r.isError, true)
        XCTAssertTrue(config.rules.rules.isEmpty)
        r = await tool("set_watched_folders", ["folders": [.string(FileManager.default.temporaryDirectory.path)]])
        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertEqual(config.folders.get().count, 1)
    }

    // MARK: Helpers

    private func memoryConfigurator() -> AppConfigurator {
        AppConfigurator(store: Store(), rules: RuleEngine(fileURL: nil), folders: .inMemory())
    }

    private func tool(_ name: String, _ args: [String: Value] = [:]) async -> CallTool.Result {
        await MCPTools.call(CallTool.Parameters(name: name, arguments: args))
    }

    private func text(_ r: CallTool.Result) -> String {
        r.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined()
    }

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

    private func post(_ path: String, _ body: String, type: String = "application/json", port: Int? = nil) async throws -> (Int, Data) {
        var r = request(path, port: port)
        r.httpMethod = "POST"
        r.httpBody = Data(body.utf8)
        r.setValue(type, forHTTPHeaderField: "Content-Type")
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
