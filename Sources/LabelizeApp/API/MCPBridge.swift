import Foundation
import MCP

/// MCP over Streamable HTTP at `/mcp`: one `Server` + `StatefulHTTPServerTransport` per session.
/// Authentication happens before this, in `APIServer`; the transport adds Origin, Accept,
/// Content-Type, protocol version and session checks.
actor MCPSessions {
    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastUsed: Date
    }

    private struct FixedSessionID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }

    private let port: Int
    private var sessions: [String: Session] = [:]
    private var reaper: Task<Void, Never>?
    static let idleTimeout: TimeInterval = 3600

    init(port: Int) { self.port = port }

    var count: Int { sessions.count }

    func handle(_ r: APIRequest) async -> APIReply {
        if reaper == nil { reaper = Task { [weak self] in await self?.reapLoop() } }
        let request = HTTPRequest(method: r.method, headers: r.headers, body: r.body.isEmpty ? nil : r.body, path: r.path)
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastUsed = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if r.method == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
                await session.server.stop()
                Log.info(.api, "MCP session ended: \(sessionID)")
            }
            return Self.reply(response)
        }
        if r.method == "POST", Self.isInitialize(r.body) {
            return await createSession(request)
        }
        if sessionID != nil {
            return Self.reply(.error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired")))
        }
        return Self.reply(.error(statusCode: 400, .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")))
    }

    func closeAll() async {
        reaper?.cancel()
        reaper = nil
        for (_, s) in sessions {
            await s.transport.disconnect()
            await s.server.stop()
        }
        sessions.removeAll()
    }

    private func createSession(_ request: HTTPRequest) async -> APIReply {
        let id = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionID(id: id),
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port),
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator(),
            ])
        )
        do {
            let server = await MCPTools.makeServer()
            try await server.start(transport: transport)
            sessions[id] = Session(server: server, transport: transport, lastUsed: Date())
            let response = await transport.handleRequest(request)
            if case .error = response {
                sessions.removeValue(forKey: id)
                await transport.disconnect()
            } else {
                Log.info(.api, "MCP session started: \(id)")
            }
            return Self.reply(response)
        } catch {
            await transport.disconnect()
            return Self.reply(.error(statusCode: 500, .internalError("Couldn't start session: \(error.localizedDescription)")))
        }
    }

    private func reapLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            let now = Date()
            for (id, s) in sessions where now.timeIntervalSince(s.lastUsed) > Self.idleTimeout {
                sessions.removeValue(forKey: id)
                await s.transport.disconnect()
                await s.server.stop()
                Log.info(.api, "MCP session expired: \(id)")
            }
        }
    }

    /// A JSON-RPC request with method "initialize".
    static func isInitialize(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["method"] as? String == "initialize" && object["id"] != nil
    }

    static func reply(_ response: HTTPResponse) -> APIReply {
        let headers = response.headers.map { ($0.key, $0.value) }
        switch response {
        case .stream(let stream, _):
            return APIReply(status: response.statusCode, headers: headers, body: .stream(stream))
        default:
            var reply = APIReply(status: response.statusCode, headers: headers, body: .data(response.bodyData ?? Data()))
            if response.statusCode >= 400 { reply.errorCode = "mcp" }
            return reply
        }
    }
}

// MARK: Tools

enum MCPTools {
    static let instructions = """
    Peel Good Inc. prints shipping labels on this Mac's label printer. Every page of every file becomes one label. \
    Use preview_label to check the result and whether barcodes still scan before printing. \
    Paths must be absolute paths on this Mac.
    """

    static func makeServer() async -> Server {
        let server = Server(name: "peel-good", version: OpenAPI.appVersion, title: "Peel Good Inc.", instructions: instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in await call(params) }
        return server
    }

    private static let options: [String: Value] = [
        "printer": ["type": "string", "description": "Queue name or display name from list_printers. Defaults to the default printer set in Peel Good Inc."],
        "size": ["type": "string", "description": "Label size like 4x6, 2.25x1.25 or 100x150mm. Defaults to the printer's size."],
        "fit": ["type": "string", "enum": ["fit", "fill"]],
        "ink": ["type": "string", "enum": ["auto", "crisp", "photo"], "description": "crisp for text and barcodes, photo for grays."],
    ]

    private static let fileInput: [String: Value] = [
        "path": ["type": "string", "description": "Absolute path to a PDF, SVG or image on this Mac."],
        "content_base64": ["type": "string", "description": "The file itself, base64, when there is no path."],
        "filename": ["type": "string", "description": "Name for content_base64, with extension, for example label.pdf."],
    ]

    private static let copies: [String: Value] = ["copies": ["type": "integer", "minimum": 1, "maximum": .int(AppLabelService.maxCopies)]]

    private static func schema(_ props: [String: Value]...) -> Value {
        .object(["type": "object", "properties": .object(props.reduce(into: [:]) { $0.merge($1) { a, _ in a } })])
    }

    static let tools: [Tool] = [
        Tool(name: "list_printers", title: "List printers",
             description: "Printers that can take a 4x6 label or smaller, with their current size and settings.",
             inputSchema: schema(), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "list_sizes", title: "List label sizes",
             description: "Label sizes for a printer, each marked supported or not.",
             inputSchema: schema(["printer": options["printer"]!]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "print_label", title: "Print label",
             description: "Prints a PDF, SVG or image right away. Every page becomes a label. Returns the job, including how many codes still scan.",
             inputSchema: schema(fileInput, options, copies), annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)),
        Tool(name: "preview_label", title: "Preview label",
             description: "Shows each label as it would print, and whether its barcodes and QR codes still scan. Nothing prints.",
             inputSchema: schema(fileInput, options), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "print_clipboard", title: "Print clipboard",
             description: "Prints the PDF, image or files on the clipboard.",
             inputSchema: schema(options, copies), annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)),
        Tool(name: "reprint_last", title: "Reprint last label",
             description: "Sends the last printed labels again to the same printer.",
             inputSchema: schema(copies), annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)),
        Tool(name: "list_jobs", title: "List recent jobs",
             description: "Jobs sent through the API since Peel Good Inc. opened, newest first.",
             inputSchema: schema(), annotations: .init(readOnlyHint: true, openWorldHint: false)),
    ]

    @MainActor
    static func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        let started = Date()
        let result: CallTool.Result
        do {
            guard let service = APIController.shared.service else { throw APIError.failed("Peel Good Inc. isn't ready.", code: "not_ready") }
            result = try await run(params.name, params.arguments ?? [:], service)
        } catch let e as APIError {
            result = CallTool.Result(content: [.text(text: "\(e.message) (\(e.code))", annotations: nil, _meta: nil)], isError: true)
        } catch {
            result = CallTool.Result(content: [.text(text: "\(error)", annotations: nil, _meta: nil)], isError: true)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.info(.api, "MCP tool \(params.name) \(result.isError == true ? "failed" : "ok") \(ms) ms")
        return result
    }

    @MainActor
    private static func run(_ name: String, _ args: [String: Value], _ service: LabelService) async throws -> CallTool.Result {
        switch name {
        case "list_printers":
            return try encoded(service.printers())
        case "list_sizes":
            guard let printer = args["printer"]?.stringValue ?? service.printers().first(where: \.isDefault)?.name else {
                throw APIError.notFound("No label printer found.", code: "no_printer")
            }
            return try encoded(try service.sizes(printer: printer))
        case "print_label":
            let input = try fileInput(args)
            defer { input.cleanUp() }
            return try encoded(try await service.print(files: input.files, request: input.request, source: "file"))
        case "preview_label":
            let input = try fileInput(args)
            defer { input.cleanUp() }
            let preview = try await service.preview(files: input.files, request: input.request)
            var summary = preview
            summary.images = summary.images.map { var i = $0; i.png = Data(); return i }
            let text = String(decoding: try APIJSON.encoder.encode(summary), as: UTF8.self)
            let images = preview.images.prefix(20).map { Tool.Content.image(data: $0.png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil) }
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)] + images)
        case "print_clipboard":
            return try encoded(try await service.printClipboard(request: try request(args)))
        case "reprint_last":
            return try encoded(try await service.reprintLast(copies: try int(args["copies"], "copies")))
        case "list_jobs":
            return try encoded(service.jobs())
        default:
            throw APIError.notFound("No tool named \(name).", code: "no_tool")
        }
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let text = String(decoding: try APIJSON.encoder.encode(value), as: UTF8.self)
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    private static func request(_ args: [String: Value]) throws -> APIPrintRequest {
        APIPrintRequest(path: args["path"]?.stringValue, printer: args["printer"]?.stringValue, size: args["size"]?.stringValue,
                        fit: args["fit"]?.stringValue, ink: args["ink"]?.stringValue, copies: try int(args["copies"], "copies"))
    }

    private static func int(_ value: Value?, _ name: String) throws -> Int? {
        guard let value, !value.isNull else { return nil }
        if let n = value.intValue { return n }
        if let d = value.doubleValue, d == d.rounded() { return Int(d) }
        if let s = value.stringValue { return try APIRoutes.int(s, name) }
        throw APIError.badRequest("\(name) must be a whole number.", code: "invalid_\(name)")
    }

    private static func fileInput(_ args: [String: Value]) throws -> APIRoutes.PrintInput {
        let r = try request(args)
        var files: [URL] = []
        var scratch: URL?
        if let path = r.path, !path.isEmpty { files.append(try APIRoutes.resolvePath(path)) }
        if let b64 = args["content_base64"]?.stringValue {
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                throw APIError.badRequest("content_base64 isn't valid base64.", code: "bad_base64")
            }
            let folder = Intake.scratchFolder()
            scratch = folder
            let url = folder.appendingPathComponent(try APIRoutes.uploadName(args["filename"]?.stringValue, contentType: Self.sniff(data), index: 0))
            try data.write(to: url)
            files.append(url)
        }
        guard !files.isEmpty else { throw APIError.badRequest("Pass path, or content_base64 with filename.", code: "no_file") }
        return APIRoutes.PrintInput(files: files, request: r, scratch: scratch)
    }

    /// Content type from the first bytes, for uploads without a usable file name.
    static func sniff(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(8))
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "application/pdf" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if String(decoding: data.prefix(256), as: UTF8.self).contains("<svg") { return "image/svg+xml" }
        return nil
    }
}
