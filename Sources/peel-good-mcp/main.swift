// peel-good-mcp: a stdio MCP server for clients like Claude Desktop that relays every
// JSON-RPC message to the app's local MCP endpoint (http://127.0.0.1:<port>/mcp).
// Peel Good Inc. must be running with Settings > API > MCP server on.
import Foundation
import PeelGoodShared

func log(_ message: String) {
    FileHandle.standardError.write(Data("peel-good-mcp: \(message)\n".utf8))
}

/// Serializes writes to stdout, one JSON-RPC message per line.
actor Output {
    func write(_ data: Data) {
        var line = data
        while line.last == 0x0A || line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty else { return }
        FileHandle.standardOutput.write(line + Data("\n".utf8))
    }

    func error(id: Any?, code: Int, _ message: String) {
        guard let id, !(id is NSNull) else { return }   // notifications get no reply
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        if let data = try? JSONSerialization.data(withJSONObject: body) { write(data) }
    }
}

struct Endpoint {
    var url: URL
    var token: String

    /// From server.json and the token file the app writes.
    static func load() -> Endpoint? {
        guard let info = ServerInfo.load(), info.mcp, let token = ServerInfo.token() else { return nil }
        return Endpoint(url: URL(string: "http://127.0.0.1:\(info.port)/mcp")!, token: token)
    }
}

actor Relay {
    let output = Output()
    private var sessionID: String?
    private var protocolVersion: String?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    static let notRunning = "\(AppIdentity.appName) isn't running, or its MCP server is off. Open \(AppIdentity.appName) and turn on Settings > API > MCP server."

    /// The client's initialize, replayed when the app has restarted and forgotten the session.
    private var initialize: Data?

    func send(_ line: Data) async {
        let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        let id = message?["id"]
        guard let message else {
            await output.error(id: NSNull(), code: -32700, "Parse error")
            return
        }
        let method = message["method"] as? String
        if method == "initialize" { initialize = line }
        guard let endpoint = Endpoint.load() else {
            log(Self.notRunning)
            await output.error(id: id, code: -32000, Self.notRunning)
            return
        }
        let first = await exchange(line, id: id, method: method, endpoint: endpoint, silent: false, canRecover: true)
        // A restarted app has no sessions, so every call failed until the client restarted too. Start a new
        // session with the client's own initialize, then send the message again, once.
        guard case .sessionLost = first, method != "initialize", let initialize else { return }
        log("the session ended (\(AppIdentity.appName) restarted?); starting a new one")
        sessionID = nil
        guard case .ok = await exchange(initialize, id: nil, method: "initialize", endpoint: endpoint, silent: true, canRecover: false) else {
            await output.error(id: id, code: -32000, "\(AppIdentity.appName) restarted and the MCP session couldn't be renewed. Reconnect the MCP server.")
            return
        }
        let initialized = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        _ = await exchange(initialized, id: nil, method: "notifications/initialized", endpoint: endpoint, silent: true, canRecover: false)
        _ = await exchange(line, id: id, method: method, endpoint: endpoint, silent: false, canRecover: false)
    }

    private enum Exchange { case ok, failed, sessionLost }

    /// POSTs one message and writes the reply to stdout (unless `silent`). With `canRecover`, a reply saying the
    /// session is gone isn't written: the caller renews the session and sends again.
    private func exchange(_ line: Data, id: Any?, method: String?, endpoint: Endpoint, silent: Bool, canRecover: Bool) async -> Exchange {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.httpBody = line
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if type.hasPrefix("text/event-stream") {
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    let payload = Data(line.dropFirst(5).drop { $0 == " " }.utf8)
                    if payload.isEmpty { continue }
                    if method == "initialize" { rememberVersion(payload) }
                    if !silent { await output.write(payload) }
                }
            } else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                if http.statusCode >= 400 {
                    let text = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
                        .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(decoding: body, as: UTF8.self)
                    log("HTTP \(http.statusCode): \(text)")
                    // 404: the app no longer knows the session. 400 "Missing Mcp-Session-Id": it was dropped after a 404.
                    let lost = http.statusCode == 404 || (http.statusCode == 400 && text.lowercased().contains("mcp-session-id"))
                    if http.statusCode == 404 { sessionID = nil }
                    if lost && canRecover { return .sessionLost }
                    if !silent { await output.error(id: id, code: -32000, "\(AppIdentity.appName): \(text)") }
                    return .failed
                } else if !body.isEmpty, !silent {
                    await output.write(body)
                }
            }
            return .ok
        } catch {
            log("\(error.localizedDescription)")
            if !silent { await output.error(id: id, code: -32000, (error as? URLError)?.code == .cannotConnectToHost ? Self.notRunning : error.localizedDescription) }
            return .failed
        }
    }

    private func rememberVersion(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let result = object["result"] as? [String: Any], let version = result["protocolVersion"] as? String else { return }
        protocolVersion = version
    }

    func close() async {
        guard let sessionID, let endpoint = Endpoint.load() else { return }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        _ = try? await session.data(for: request)
    }
}

let relay = Relay()
let done = DispatchSemaphore(value: 0)
Task {
    // One message at a time, in order: the client's next message often depends on the last reply.
    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            await relay.send(Data(line.utf8))
        }
    } catch {
        log("stdin: \(error.localizedDescription)")
    }
    await relay.close()
    done.signal()
}
done.wait()
