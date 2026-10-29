import Foundation
import LabelKit
import LabelizeCore
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

/// What a tool needs beyond MCP being on. Both permissions are off by default and only Settings can turn them on.
enum MCPPermission: String, Sendable {
    case none
    /// Paths on this Mac, the clipboard, reprinting.
    case localFiles
    /// Settings, rules, watched folders, HTTP API switch and port.
    case settings

    var settingTitle: String {
        switch self {
        case .none: ""
        case .localFiles: "Let MCP print files from this Mac"
        case .settings: "Let MCP change settings"
        }
    }

    var refusal: APIError {
        let how = self == .settings ? "Set \u{201C}\(settingTitle)\u{201D} to For 45 Minutes or Always"
                                    : "Turn on \u{201C}\(settingTitle)\u{201D}"
        return APIError(status: 403, code: "permission_required", message: "\(how) in Peel Good Inc. Settings > API, then try again.")
    }

    @MainActor var isGranted: Bool {
        switch self {
        case .none: true
        case .localFiles: APIController.shared.mcpCanUseLocalFiles
        case .settings: APIController.shared.mcpCanChangeSettings
        }
    }
}

enum MCPTools {
    static let instructions = """
    Peel Good Inc. prints shipping labels on this Mac's label printer. Every page of every file becomes one label. \
    Use preview_label to check the result and whether barcodes still scan before printing. \
    Prints go through the app's rules and show on screen like a dropped file: a short countdown the user can cancel, \
    or a preview that waits for Print when the user asked for that. A print call returns when the job ends \
    (printed, cancelled or failed) or after 120 seconds with status waiting; list_jobs shows how it ended. \
    Send files as content_base64. Paths on this Mac, the clipboard and reprinting need the user to turn on \
    "Let MCP print files from this Mac"; changing settings and rules needs "Let MCP change settings". \
    Both are in Peel Good Inc. Settings > API. Tools that need a permission say so in their error.
    """

    static func makeServer() async -> Server {
        let server = Server(name: "peel-good", version: OpenAPI.appVersion, title: "Peel Good Inc.", instructions: instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in await call(params) }
        return server
    }

    // MARK: Schemas

    private static let options: [String: Value] = [
        "printer": ["type": "string", "description": "Queue name or display name from list_printers. Defaults to the default printer set in Peel Good Inc."],
        "size": ["type": "string", "description": "Label size like 4x6, 2.25x1.25 or 100x150mm. Defaults to the printer's size."],
        "fit": ["type": "string", "enum": .array(Limits.fits.map { .string($0) })],
        "ink": ["type": "string", "enum": .array(Limits.inks.map { .string($0) }), "description": .string(inkDescription)],
    ]

    /// "auto picks per page, crisp hard cutoff, sharp text and codes, …", from LabelKit.
    static var inkDescription: String { InkMode.allCases.map { "\($0.rawValue): \($0.help)" }.joined(separator: "; ") + "." }

    private static let fileInput: [String: Value] = [
        "content_base64": ["type": "string", "description": "The file, base64. Up to 25 MB."],
        "filename": ["type": "string", "description": "Name for content_base64, with extension, for example label.pdf."],
        "path": ["type": "string", "description": "Absolute path to a PDF, SVG or image on this Mac. Needs \"Let MCP print files from this Mac\"."],
    ]

    private static let copies: [String: Value] = ["copies": ["type": "integer", "minimum": .int(Limits.copies.lowerBound), "maximum": .int(Limits.copies.upperBound)]]

    private static func schema(_ props: [String: Value]..., required: [String] = []) -> Value {
        var o: [String: Value] = ["type": "object", "properties": .object(props.reduce(into: [:]) { $0.merge($1) { a, _ in a } })]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    private static let settingsProps: [String: Value] = [
        "defaultPrinter": ["type": "string", "description": "Queue name or display name."],
        "countdownSeconds": ["type": "number", "minimum": .double(Limits.countdownSeconds.lowerBound), "maximum": .double(Limits.countdownSeconds.upperBound), "description": "Wait before printing a dropped file. 0 prints right away."],
        "alwaysPreview": ["type": "boolean", "description": "Before printing: Show preview instead of counting down."],
        "newFilesAction": ["type": "string", "enum": .array(RuleAction.allCases.map { .string($0.rawValue) }),
                           "description": "Rules > New files: what files in watched folders do when no rule says. ask sends a notification, review shows the preview."],
        "playSounds": ["type": "boolean"],
        "hiddenPrinters": ["type": "array", "items": ["type": "string"], "description": "Queue names hidden from the app's lists."],
        "tagAfterPrint": ["type": "boolean", "description": "Add Finder tag to printed files."],
        "tagName": ["type": "string", "maxLength": .int(Limits.tagNameLength)],
        "tagColor": ["type": "string", "enum": .array(FinderTag.Color.allCases.map { .string($0.name) })],
        "afterPrint": ["type": "string", "enum": .array(AfterPrintAction.allCases.map { .string($0.rawValue) }), "description": "What happens to the original file after printing."],
        "renameSuffix": ["type": "string", "description": "For afterPrint rename."],
        "moveFolder": ["type": ["string", "null"], "description": "Existing folder, for afterPrint move."],
        "keepHistoryDays": ["type": "integer", "minimum": .int(Limits.historyDays.lowerBound), "maximum": .int(Limits.historyDays.upperBound), "description": "Days to keep printed labels for reprinting. 0 keeps them forever."],
        "httpEnabled": ["type": "boolean", "description": "The local HTTP API."],
        "port": ["type": "integer", "minimum": 1024, "maximum": 65535, "description": "Changes a second after the reply; reconnect on the new port."],
    ]

    private static let printerProps: [String: Value] = [
        "printer": ["type": "string", "description": "Queue name or display name."],
        "size": ["type": "string", "description": "Label size, like 4x6."],
        "fit": ["type": "string", "enum": .array(Limits.fits.map { .string($0) })],
        "ink": ["type": "string", "enum": .array(Limits.inks.map { .string($0) })],
        "cutoff": ["type": "number", "minimum": .double(Limits.cutoff.lowerBound), "maximum": .double(Limits.cutoff.upperBound), "description": "Gray level below which a dot prints black."],
        "toneGamma": ["type": "number", "minimum": .double(Limits.toneGamma.lowerBound), "maximum": .double(Limits.toneGamma.upperBound), "description": "Dot gain for photo and halftone. 1 turns tone correction off."],
        "nudgeXmm": ["type": "number", "minimum": .double(Limits.nudgeMM.lowerBound), "maximum": .double(Limits.nudgeMM.upperBound), "description": "Alignment, + moves right."],
        "nudgeYmm": ["type": "number", "minimum": .double(Limits.nudgeMM.lowerBound), "maximum": .double(Limits.nudgeMM.upperBound), "description": "Alignment, + moves down."],
    ]

    /// The rule format, generated from the rule model so it can't drift.
    static var ruleFormat: String {
        let fields = RuleCondition.Field.allCases.map { f -> String in
            let choices = f.choices.isEmpty ? "" : " values one of \(f.choices.map(\.0).joined(separator: "|"))"
            return "\(f.rawValue) (ops \(f.ops.map(\.rawValue).joined(separator: "|"))\(choices))"
        }.joined(separator: "; ")
        return """
        A rule is {name, isEnabled, matchAll, conditions: [{field, op, values: [text], number}], \
        outcome: {printer, size, fit, ink, action: print|review|ask, copies, tag: default|none|{name, color}}}. \
        Outcome fields left out use the default printer and its settings; action review shows the preview. \
        tag default uses the tag in General, none adds no tag; nothing is tagged while General's Finder tag is off. \
        Rules run top to bottom; the first match wins, else Everything else, which always uses the default printer and its settings. \
        Fields: \(fields).
        """
    }

    private static let ruleInput: Value = ["type": "object", "description": "Fields to set. Fields left out keep their value."]

    private static func readOnly() -> Tool.Annotations { .init(readOnlyHint: true, openWorldHint: false) }
    private static func prints() -> Tool.Annotations { .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true) }
    private static func edits(destructive: Bool = false) -> Tool.Annotations { .init(readOnlyHint: false, destructiveHint: destructive, idempotentHint: !destructive, openWorldHint: false) }

    private static let localNote = " Needs \"Let MCP print files from this Mac\" in Settings > API."
    private static let settingsNote = " Needs \"Let MCP change settings\" in Settings > API."

    /// Every tool, and the permission it needs. print_label and preview_label need localFiles only when given a path.
    static let catalog: [(tool: Tool, permission: MCPPermission)] = [
        (Tool(name: "list_printers", title: "List printers", description: "Printers that can take a 4x6 label or smaller, with their current size and settings.",
              inputSchema: schema(), annotations: readOnly()), .none),
        (Tool(name: "list_sizes", title: "List label sizes", description: "Label sizes for a printer, each marked supported or not.",
              inputSchema: schema(["printer": options["printer"]!]), annotations: readOnly()), .none),
        (Tool(name: "print_label", title: "Print label",
              description: "Prints a PDF, SVG or image. Every page becomes a label. Goes through the rules and the on-screen countdown, or waits for Print when Before printing is Show preview or the rule shows the preview or asks. Returns when the job ends, or after 120 seconds with status waiting (see list_jobs). The reply names the matching rule and, per label, the ink used, scale, rotation and codes. A path" + localNote,
              inputSchema: schema(fileInput, options, copies), annotations: prints()), .none),
        (Tool(name: "preview_label", title: "Preview label",
              description: "Shows each label as it would print, with the matching rule, the ink used, scale, rotation, and whether its barcodes and QR codes still scan. Nothing prints. A path" + localNote,
              inputSchema: schema(fileInput, options), annotations: readOnly()), .none),
        (Tool(name: "print_clipboard", title: "Print clipboard", description: "Prints the PDF, image or files on the clipboard. Goes through the rules and the on-screen countdown, or waits for Print when Before printing is Show preview or the rule shows the preview or asks. Returns when the job ends, or after 120 seconds with status waiting (see list_jobs). The reply names the matching rule and, per label, the ink used, scale, rotation and codes." + localNote,
              inputSchema: schema(options, copies), annotations: prints()), .localFiles),
        (Tool(name: "reprint_last", title: "Reprint last label", description: "Sends the last printed labels again to the same printer, 1:1, with the on-screen countdown (or Print, when Before printing is Show preview). Returns when the job ends, or after 120 seconds with status waiting." + localNote,
              inputSchema: schema(copies), annotations: prints()), .localFiles),
        (Tool(name: "list_jobs", title: "List recent jobs", description: "Jobs sent through the API or MCP since Peel Good Inc. opened, newest first, with how each ended: printed, cancelled, failed or still waiting.",
              inputSchema: schema(), annotations: readOnly()), .none),
        (Tool(name: "get_settings", title: "Get settings",
              description: "All settings: general, files, per printer, watched folders, and the API switches and permissions.",
              inputSchema: schema(), annotations: readOnly()), .none),
        (Tool(name: "update_settings", title: "Change settings",
              description: "Changes app settings. Only the fields given change. MCP can't change the MCP switch, its permissions or the token." + settingsNote,
              inputSchema: schema(settingsProps), annotations: edits()), .settings),
        (Tool(name: "set_printer_settings", title: "Change printer settings",
              description: "Changes one printer's label size, scaling, ink, threshold or alignment." + settingsNote,
              inputSchema: schema(printerProps, required: ["printer"]), annotations: edits()), .settings),
        (Tool(name: "set_watched_folders", title: "Set watched folders",
              description: "Replaces the folders watched for new labels. Pass an empty list to stop watching." + settingsNote,
              inputSchema: schema(["folders": ["type": "array", "items": ["type": "string"], "description": "Existing folders, absolute or starting with ~."]], required: ["folders"]),
              annotations: edits()), .settings),
        (Tool(name: "list_rules", title: "List rules", description: "Rules in order, and Everything else. " + ruleFormat,
              inputSchema: schema(), annotations: readOnly()), .none),
        (Tool(name: "add_rule", title: "Add rule", description: "Adds a rule at the end of the list." + settingsNote + " " + ruleFormat,
              inputSchema: schema(["rule": ruleInput], required: ["rule"]), annotations: edits()), .settings),
        (Tool(name: "update_rule", title: "Change rule",
              description: "Changes a rule by id. Passing conditions replaces them all. Everything else can't be changed; it uses the default printer and its settings." + settingsNote,
              inputSchema: schema(["id": ["type": "string"], "rule": ruleInput], required: ["id", "rule"]), annotations: edits()), .settings),
        (Tool(name: "delete_rule", title: "Delete rule", description: "Deletes a rule by id." + settingsNote,
              inputSchema: schema(["id": ["type": "string"]], required: ["id"]), annotations: edits(destructive: true)), .settings),
        (Tool(name: "reorder_rules", title: "Reorder rules", description: "Sets the rule order. List every rule id once." + settingsNote,
              inputSchema: schema(["ids": ["type": "array", "items": ["type": "string"]]], required: ["ids"]), annotations: edits()), .settings),
    ]

    static var tools: [Tool] { catalog.map(\.tool) }

    // MARK: Calling

    @MainActor
    static func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        let started = Date()
        let result: CallTool.Result
        do {
            guard let service = APIController.shared.service else { throw APIError.failed("Peel Good Inc. isn't ready.", code: "not_ready") }
            guard let entry = catalog.first(where: { $0.tool.name == params.name }) else {
                throw APIError.notFound("No tool named \(params.name).", code: "no_tool")
            }
            guard entry.permission.isGranted else {
                Log.warning(.api, "MCP tool \(params.name) refused: needs \(entry.permission.settingTitle)")
                throw entry.permission.refusal
            }
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
        let api = APIController.shared
        func config() throws -> AppConfigurator {
            guard let c = api.configurator else { throw APIError.failed("Peel Good Inc. isn't ready.", code: "not_ready") }
            return c
        }
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
            var job: APIJob?
            defer { input.cleanUp(after: job) }
            let source = input.scratch == nil ? APIJob.Source.localFile : APIJob.Source.upload
            job = try await service.print(files: input.files, request: input.request, source: source)
            return try encoded(job!)
        case "preview_label":
            let input = try fileInput(args)
            defer { input.cleanUp() }
            let preview = try await service.preview(files: input.files, request: input.request)
            var summary = preview
            summary.images = summary.images.map { var i = $0; i.png = nil; return i }   // the images follow as image content
            let text = String(decoding: try APIJSON.encoder.encode(summary), as: UTF8.self)
            let images = preview.images.prefix(20).map { Tool.Content.image(data: ($0.png ?? Data()).base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil) }
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)] + images)
        case "print_clipboard":
            var request = try request(args)
            request.path = nil
            return try encoded(try await service.printClipboard(request: request))
        case "reprint_last":
            return try encoded(try await service.reprintLast(copies: try int(args["copies"], "copies")))
        case "list_jobs":
            let jobs = service.jobs()
            return try encoded(api.mcpCanUseLocalFiles ? jobs : jobs.map { var j = $0; j.savedPDF = nil; return j })
        case "get_settings":
            return text(AppConfigurator.json(try config().settings()))
        case "update_settings":
            return text(try config().updateSettings(try plain(args)).joined(separator: "\n"))
        case "set_printer_settings":
            return text(try config().setPrinterSettings(try plain(args)).joined(separator: "\n"))
        case "set_watched_folders":
            return text(try config().setWatchedFolders(try plain(args)["folders"] ?? NSNull()).joined(separator: "\n"))
        case "list_rules":
            return text(AppConfigurator.json(try config().listRules()))
        case "add_rule":
            return text(AppConfigurator.json(try config().addRule(try ruleArg(args))))
        case "update_rule":
            return text(AppConfigurator.json(try config().updateRule(try idArg(args), try ruleArg(args))))
        case "delete_rule":
            return text(try config().deleteRule(try idArg(args)))
        case "reorder_rules":
            guard let ids = try plain(args)["ids"] as? [String] else { throw APIError.badRequest("ids must be a list of rule ids.", code: "invalid_ids") }
            return text(try config().reorderRules(ids).joined(separator: "\n"))
        default:
            throw APIError.notFound("No tool named \(name).", code: "no_tool")
        }
    }

    private static func text(_ s: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: s, annotations: nil, _meta: nil)])
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> CallTool.Result {
        text(String(decoding: try APIJSON.encoder.encode(value), as: UTF8.self))
    }

    /// Arguments as Foundation JSON objects, for the configuration tools.
    private static func plain(_ args: [String: Value]) throws -> [String: Any] {
        let data = try JSONEncoder().encode(args)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func ruleArg(_ args: [String: Value]) throws -> [String: Any] {
        guard let rule = try plain(args)["rule"] as? [String: Any] else { throw APIError.badRequest("rule must be an object.", code: "invalid_rule") }
        return rule
    }

    private static func idArg(_ args: [String: Value]) throws -> String {
        guard let id = args["id"]?.stringValue, !id.isEmpty else { throw APIError.badRequest("id is required.", code: "invalid_id") }
        return id == "everything-else" ? "everything else" : id
    }

    private static func request(_ args: [String: Value]) throws -> APIPrintRequest {
        APIPrintRequest(path: args["path"]?.stringValue, printer: args["printer"]?.stringValue, size: args["size"]?.stringValue,
                        fit: args["fit"]?.stringValue, ink: args["ink"]?.stringValue, copies: try int(args["copies"], "copies"))
    }

    private static func int(_ value: Value?, _ name: String) throws -> Int? {
        guard let value, !value.isNull else { return nil }
        if let n = value.intValue { return n }
        if let d = value.doubleValue, d == d.rounded() { return Int(d) }
        if let s = value.stringValue { return try APIPrintRequest.given(s).map { try APIRoutes.int($0, name) } }
        throw APIError.badRequest("\(name) must be a whole number.", code: "invalid_\(name)")
    }

    /// Uploads (content_base64) always; a path only with the local files permission.
    @MainActor
    private static func fileInput(_ args: [String: Value]) throws -> APIRoutes.PrintInput {
        var r = try request(args)
        var local: [URL] = []
        if let path = r.path, !path.isEmpty {
            guard MCPPermission.localFiles.isGranted else {
                Log.warning(.api, "MCP path refused: needs \(MCPPermission.localFiles.settingTitle)")
                throw MCPPermission.localFiles.refusal
            }
            local.append(try APIRoutes.resolvePath(path))
        }
        r.path = nil
        var uploads: [(name: String, data: Data)] = []
        if let b64 = args["content_base64"]?.stringValue {
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                throw APIError.badRequest("content_base64 isn't valid base64.", code: "bad_base64")
            }
            uploads.append((try APIRoutes.uploadName(args["filename"]?.stringValue, contentType: Self.sniff(data), index: 0), data))
        }
        guard !uploads.isEmpty || !local.isEmpty else {
            throw APIError.badRequest("Pass content_base64 with filename, or a path.", code: "no_file")
        }
        return try APIRoutes.save(uploads, request: r, local: local)
    }

    /// Content type from the first bytes, for uploads without a usable file name.
    static func sniff(_ data: Data) -> String? { Intake.format(of: data)?.mimeType }
}
