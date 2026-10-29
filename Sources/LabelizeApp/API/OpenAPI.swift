import Foundation

/// The REST API described once, in Swift. The OpenAPI document, the docs page, the API pane
/// and the curl examples are all generated from `OpenAPI.endpoints` and `OpenAPI.components`.
enum OpenAPI {
    // MARK: Model

    indirect enum Schema {
        case string(String? = nil, values: [String]? = nil, format: String? = nil)
        case integer(String? = nil, min: Int? = nil, max: Int? = nil)
        case number(String? = nil)
        case boolean(String? = nil)
        case array(Schema, String? = nil)
        case object([Field], String? = nil)
        case ref(String)

        var summary: String? {
            switch self {
            case .string(let d, _, _), .integer(let d, _, _), .number(let d), .boolean(let d), .array(_, let d), .object(_, let d): d
            case .ref: nil
            }
        }

        /// "string", "integer", "Job", "array of Job"
        var typeName: String {
            switch self {
            case .string(_, let values, let format):
                if format == "binary" { return "file" }
                if let values { return values.joined(separator: " | ") }
                return format.map { "string (\($0))" } ?? "string"
            case .integer: return "integer"
            case .number: return "number"
            case .boolean: return "boolean"
            case .array(let item, _): return "array of \(item.typeName)"
            case .object: return "object"
            case .ref(let name): return name
            }
        }

        /// The object's fields, following a reference or an array's items.
        var fields: [Field] {
            switch self {
            case .object(let fields, _): fields
            case .ref(let name): OpenAPI.component(name)?.fields ?? []
            case .array(let item, _): item.fields
            default: []
            }
        }

        var json: JSONValue {
            var pairs: [(String, JSONValue)] = []
            switch self {
            case .string(let d, let values, let format):
                pairs.append(("type", "string"))
                if let format { pairs.append(("format", .string(format))) }
                if let values { pairs.append(("enum", .array(values.map { .string($0) }))) }
                if let d { pairs.append(("description", .string(d))) }
            case .integer(let d, let min, let max):
                pairs.append(("type", "integer"))
                if let min { pairs.append(("minimum", .number(Double(min)))) }
                if let max { pairs.append(("maximum", .number(Double(max)))) }
                if let d { pairs.append(("description", .string(d))) }
            case .number(let d):
                pairs.append(("type", "number"))
                if let d { pairs.append(("description", .string(d))) }
            case .boolean(let d):
                pairs.append(("type", "boolean"))
                if let d { pairs.append(("description", .string(d))) }
            case .array(let item, let d):
                pairs.append(("type", "array"))
                pairs.append(("items", item.json))
                if let d { pairs.append(("description", .string(d))) }
            case .object(let fields, let d):
                pairs.append(("type", "object"))
                if let d { pairs.append(("description", .string(d))) }
                pairs.append(("properties", .object(fields.map { ($0.name, $0.schema.json) })))
                let required = fields.filter(\.required).map { JSONValue.string($0.name) }
                if !required.isEmpty { pairs.append(("required", .array(required))) }
            case .ref(let name):
                pairs.append(("$ref", .string("#/components/schemas/\(name)")))
            }
            return .object(pairs)
        }
    }

    struct Field: Identifiable {
        var name: String
        var schema: Schema
        var required = false
        var id: String { name }

        init(_ name: String, _ schema: Schema, required: Bool = false) {
            self.name = name
            self.schema = schema
            self.required = required
        }
    }

    enum Verb: String { case get = "GET", post = "POST" }

    struct Parameter: Identifiable {
        enum Location: String { case path, query }
        var name: String
        var location: Location
        var required: Bool
        var schema: Schema
        var example: String
        var id: String { name }
    }

    struct Content: Identifiable {
        var mediaType: String
        var schema: Schema
        var example: JSONValue?
        var id: String { mediaType }
    }

    struct Response: Identifiable {
        var status: Int
        var description: String
        var content: [Content] = []
        var id: Int { status }
    }

    struct Endpoint: Identifiable {
        var verb: Verb
        var path: String
        var operationID: String
        var tag: String
        var summary: String
        var detail: String
        var parameters: [Parameter] = []
        var body: [Content] = []
        var bodyRequired = false
        var responses: [Response]
        var authenticated = true
        var id: String { operationID }

        /// The path with path parameters filled in from their examples.
        var examplePath: String {
            parameters.filter { $0.location == .path }.reduce(path) { p, param in
                p.replacingOccurrences(of: "{\(param.name)}", with: param.example.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? param.example)
            }
        }
    }

    // MARK: Components

    static let components: [(String, Schema)] = [
        ("Health", .object([
            Field("status", .string("Always ok.", values: ["ok"]), required: true),
            Field("version", .string("App version."), required: true),
            Field("http", .boolean("HTTP API is on."), required: true),
            Field("mcp", .boolean("MCP server is on."), required: true),
            Field("port", .integer("Port the server listens on."), required: true),
        ])),
        ("Printer", .object([
            Field("name", .string("CUPS queue name. Use it to address the printer."), required: true),
            Field("displayName", .string("Name shown in the app."), required: true),
            Field("model", .string("Make and model."), required: true),
            Field("isDefault", .boolean("The default printer."), required: true),
            Field("isLabelPrinter", .boolean("A 4 in thermal printer (prints 1-bit labels)."), required: true),
            Field("state", .string(values: ["idle", "printing", "stopped", "unknown"]), required: true),
            Field("size", .string("Current label size, width x height in inches."), required: true),
            Field("fit", .string(values: ["fit", "fill"]), required: true),
            Field("ink", .string(values: ["auto", "crisp", "photo", "halftone"]), required: true),
        ])),
        ("Size", .object([
            Field("size", .string("Width x height in inches. Pass this as size."), required: true),
            Field("display", .string("Size as shown in the app."), required: true),
            Field("widthInches", .number(), required: true),
            Field("heightInches", .number(), required: true),
            Field("source", .string("Reported by the printer, or a standard roll size.", values: ["printer", "catalog"]), required: true),
            Field("supported", .boolean("The printer can print this size."), required: true),
            Field("reason", .string("Why the size isn't supported.")),
            Field("current", .boolean("The size set for this printer."), required: true),
        ])),
        ("PrintUpload", .object([
            Field("file", .array(.string(format: "binary")), required: true),
            Field("printer", .string()),
            Field("size", .string()),
            Field("fit", .string(values: ["fit", "fill"])),
            Field("ink", .string(values: ["auto", "crisp", "photo", "halftone"])),
            Field("copies", .integer(min: 1, max: AppLabelService.maxCopies)),
        ], "Up to \(APILimits.maxFiles) files, each sent as a part named file, up to \(APILimits.maxFileBytes / 1_048_576) MB each and \(APILimits.maxLabels) pages in all. Every page of every file prints.")),
        ("Code", .object([
            Field("symbology", .string("QR, Code128, DataMatrix, and so on."), required: true),
            Field("payload", .string(), required: true),
            Field("scannable", .boolean("Still decodes from the finished label."), required: true),
            Field("severity", .string(values: ["ok", "caution", "error"])),
            Field("message", .string()),
        ])),
        ("Job", .object([
            Field("id", .string(format: "uuid"), required: true),
            Field("created", .string(format: "date-time"), required: true),
            Field("source", .string("Files sent with the request.", values: ["upload"]), required: true),
            Field("status", .string("waiting: still counting down, or waiting for Print in the preview, when the reply was sent. List jobs to see how it ended.",
                                    values: ["printed", "cancelled", "failed", "waiting"]), required: true),
            Field("files", .array(.string()), required: true),
            Field("printer", .string(), required: true),
            Field("size", .string(), required: true),
            Field("copies", .integer(), required: true),
            Field("labels", .integer("Labels per copy: one per page."), required: true),
            Field("codesFound", .integer("Barcodes and QR codes found on the source."), required: true),
            Field("codesVerified", .integer("Codes that still scan on the label."), required: true),
            Field("codesMissing", .array(.string(), "Payloads of codes that won't scan."), required: true),
            Field("warnings", .array(.string()), required: true),
            Field("printerJobID", .string("Job id from the print system.")),
            Field("error", .string()),
            Field("rule", .string("The rule that matched, or Everything else.")),
            Field("action", .string("countdown: prints after the countdown unless cancelled. review: waits for Print in the preview.",
                                    values: ["countdown", "review"])),
            Field("labelDetails", .array(.ref("LabelInfo"), "Per label, once composed.")),
        ])),
        ("LabelInfo", .object([
            Field("index", .integer(), required: true),
            Field("ink", .string("The ink used. Auto picks one per label.", values: ["crisp", "photo", "halftone"]), required: true),
            Field("scalePercent", .number("Source to label scale."), required: true),
            Field("rotated", .boolean(), required: true),
            Field("codes", .array(.ref("Code")), required: true),
            Field("warnings", .array(.string()), required: true),
        ])),
        ("LabelPreview", .object([
            Field("index", .integer(), required: true),
            Field("width", .integer("Pixels at printer resolution."), required: true),
            Field("height", .integer(), required: true),
            Field("png", .string("PNG image, base64.", format: "byte"), required: true),
            Field("ink", .string("The ink used. Auto picks one per label.", values: ["crisp", "photo", "halftone"]), required: true),
            Field("scalePercent", .number("Source to label scale."), required: true),
            Field("rotated", .boolean(), required: true),
            Field("codes", .array(.ref("Code")), required: true),
            Field("warnings", .array(.string()), required: true),
        ])),
        ("Preview", .object([
            Field("printer", .string(), required: true),
            Field("size", .string(), required: true),
            Field("rule", .string("The rule that matched, or Everything else.")),
            Field("copies", .integer(), required: true),
            Field("action", .string("What printing would do.", values: ["countdown", "review"]), required: true),
            Field("labels", .integer(), required: true),
            Field("codesFound", .integer(), required: true),
            Field("codesVerified", .integer(), required: true),
            Field("codesMissing", .array(.string()), required: true),
            Field("warnings", .array(.string()), required: true),
            Field("images", .array(.ref("LabelPreview")), required: true),
        ])),
        ("Error", .object([
            Field("error", .object([
                Field("code", .string("Stable code, for example printer_not_found."), required: true),
                Field("message", .string(), required: true),
            ]), required: true),
        ])),
    ]

    static func component(_ name: String) -> Schema? { components.first { $0.0 == name }?.1 }

    // MARK: Examples (encoded from the real DTOs, so they match the responses)

    enum Example {
        static let printer = APIPrinter(name: "MUNBYN_ITPP941AP", displayName: "MUNBYN ITPP941AP", model: "MUNBYN ITPP941AP-AirPrint",
                                        isDefault: true, isLabelPrinter: true, state: "idle", size: "4x6", fit: "fit", ink: "auto")
        static let size = APISize(size: "4x6", display: "4 × 6 in", widthInches: 4, heightInches: 6, source: "printer",
                                  supported: true, reason: nil, current: true)
        static let job = APIJob(id: "6F1C2A8E-3B7D-4E51-9C0A-2D4E5F6A7B8C", created: Date(timeIntervalSince1970: 1_793_300_000),
                                source: "upload", status: .printed, files: ["order-1234-label.pdf"], printer: "MUNBYN_ITPP941AP",
                                size: "4x6", copies: 1, labels: 2, codesFound: 2, codesVerified: 2, codesMissing: [], warnings: [],
                                savedPDF: nil,
                                printerJobID: "MUNBYN_ITPP941AP-42", error: nil, rule: "Everything else", action: "countdown",
                                labelDetails: [info(0), info(1)])
        static func info(_ i: Int) -> APILabelInfo {
            APILabelInfo(index: i, ink: "crisp", scalePercent: 100, rotated: false, codes: [code], warnings: [])
        }
        static let code = APICode(symbology: "QR", payload: "1Z999AA10123456784", scannable: true, severity: "ok", message: nil)
        static let preview = APIPreview(printer: "MUNBYN_ITPP941AP", size: "4x6", rule: "Everything else", copies: 1, action: "countdown",
                                        labels: 1, codesFound: 1, codesVerified: 1, codesMissing: [], warnings: [],
                                        images: [APILabelPreview(index: 0, width: 812, height: 1218, png: Data("PNG…".utf8), ink: "crisp",
                                                                 scalePercent: 100, rotated: false, codes: [code], warnings: [])])
        static let health = APIHealth(status: "ok", version: "0.1", http: true, mcp: true, port: APISettings.defaultPort)
        static let error = APIErrorBody(error: .init(code: "printer_not_found", message: "Printer Zebra not found."))
    }

    // MARK: Endpoints

    private static func json(_ schema: Schema, _ example: JSONValue?) -> Content {
        Content(mediaType: "application/json", schema: schema, example: example)
    }

    private static func ok<T: Encodable>(_ description: String, _ schema: Schema, _ example: T) -> Response {
        Response(status: 200, description: description, content: [json(schema, .encoding(example))])
    }

    private static func error(_ status: Int, _ description: String) -> Response {
        Response(status: status, description: description, content: [json(.ref("Error"), .encoding(Example.error))])
    }

    private static let printBody: [Content] = [
        Content(mediaType: "multipart/form-data", schema: .ref("PrintUpload"), example: nil),
        Content(mediaType: "application/pdf", schema: .string("The file itself. Options go in the query.", format: "binary"), example: nil),
        Content(mediaType: "image/*", schema: .string("PNG, JPEG, SVG, TIFF, GIF or HEIC. Options go in the query.", format: "binary"), example: nil),
    ]

    /// Options as query parameters, for raw bodies (multipart can send them as fields instead).
    private static let optionParameters: [Parameter] = [
        Parameter(name: "printer", location: .query, required: false, schema: .string("Queue name or display name. Defaults to the default printer set in Peel Good Inc."), example: "MUNBYN_ITPP941AP"),
        Parameter(name: "size", location: .query, required: false, schema: .string("Label size like 4x6, 2.25x1.25 or 100x150mm. Defaults to the printer's size."), example: "4x6"),
        Parameter(name: "fit", location: .query, required: false, schema: .string(values: ["fit", "fill"]), example: "fit"),
        Parameter(name: "ink", location: .query, required: false, schema: .string(values: ["auto", "crisp", "photo", "halftone"]), example: "auto"),
        Parameter(name: "copies", location: .query, required: false, schema: .integer(min: 1, max: AppLabelService.maxCopies), example: "1"),
        Parameter(name: "filename", location: .query, required: false, schema: .string("Name for a raw body, shown in jobs."), example: "label.pdf"),
    ]

    private static let uploadErrors = [error(400, "Bad options, no file, or a path instead of a file."), error(404, "No such printer."),
                                       error(413, "Too many files or pages, or a file is too large."), error(415, "Not a PDF, SVG or image."),
                                       error(422, "Unreadable file or unsupported size."), error(429, "Too many requests. Wait for Retry-After seconds.")]

    private static let common = [error(401, "Missing or wrong token."), error(403, "Request from a browser or another host.")]

    static let endpoints: [Endpoint] = [
        Endpoint(verb: .get, path: "/v1/health", operationID: "health", tag: "Status", summary: "Check the server",
                 detail: "Returns ok while Peel Good Inc. is running.",
                 responses: [ok("Server is running.", .ref("Health"), Example.health)] + common),
        Endpoint(verb: .get, path: "/v1/printers", operationID: "listPrinters", tag: "Printers", summary: "List printers",
                 detail: "Printers that can take a 4x6 label or smaller, label printers first.",
                 responses: [ok("Printers.", .array(.ref("Printer")), [Example.printer])] + common),
        Endpoint(verb: .get, path: "/v1/printers/{name}/sizes", operationID: "listSizes", tag: "Printers", summary: "List label sizes",
                 detail: "The printer's presets plus standard roll sizes, each marked supported or not.",
                 parameters: [Parameter(name: "name", location: .path, required: true,
                                        schema: .string("Queue name or display name."), example: Example.printer.name)],
                 responses: [ok("Sizes.", .array(.ref("Size")), [Example.size]), error(404, "No such printer.")] + common),
        Endpoint(verb: .post, path: "/v1/print", operationID: "print", tag: "Printing", summary: "Print a file",
                 detail: "Prints files sent with the request, as multipart form data or as the raw body. Every page of every file prints. It goes through the rules (How it arrives: From another app) and the popover like a dropped file: the countdown can be cancelled, and with Ask first, or a rule that previews or asks, it waits for Print. The reply comes when the job ends, or after 120 seconds with status waiting. Files on this Mac, the clipboard and reprinting aren't available over HTTP.",
                 parameters: optionParameters,
                 body: printBody, bodyRequired: true,
                 responses: [ok("The job ended: printed or cancelled.", .ref("Job"), Example.job),
                             Response(status: 202, description: "Still waiting after 120 seconds. List jobs later to see how it ended.",
                                      content: [json(.ref("Job"), .encoding(Example.job))])] + uploadErrors
                     + [error(500, "The print system refused the job.")] + common),
        Endpoint(verb: .post, path: "/v1/preview", operationID: "preview", tag: "Printing", summary: "Preview labels",
                 detail: "Same input as print. Returns each label as it would print, with the codes found and whether they still scan. Nothing prints.",
                 parameters: [
                     Parameter(name: "format", location: .query, required: false,
                               schema: .string("json returns every label as base64; png returns one image.", values: ["json", "png"]), example: "png"),
                     Parameter(name: "index", location: .query, required: false,
                               schema: .integer("Label to return as PNG, from 0.", min: 0), example: "0"),
                 ] + optionParameters,
                 body: printBody, bodyRequired: true,
                 responses: [Response(status: 200, description: "Preview.", content: [
                     json(.ref("Preview"), .encoding(Example.preview)),
                     Content(mediaType: "image/png", schema: .string(format: "binary"), example: nil),
                 ])] + uploadErrors + common),
        Endpoint(verb: .get, path: "/v1/jobs", operationID: "listJobs", tag: "Printing", summary: "List recent jobs",
                 detail: "Jobs printed from HTTP uploads since Peel Good Inc. opened, newest first.",
                 responses: [ok("Jobs.", .array(.ref("Job")), [Example.job])] + common),
        Endpoint(verb: .get, path: "/openapi.json", operationID: "openAPI", tag: "Docs", summary: "Get this document",
                 detail: "The OpenAPI 3.1 description of this API. No token needed.",
                 responses: [Response(status: 200, description: "OpenAPI document.",
                                      content: [Content(mediaType: "application/json", schema: .object([]), example: nil)])],
                 authenticated: false),
    ]

    static var tags: [String] {
        endpoints.map(\.tag).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    // MARK: Document

    static func document(port: Int) -> JSONValue {
        var paths: [(String, JSONValue)] = []
        for path in endpoints.map(\.path).reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            let ops = endpoints.filter { $0.path == path }.map { e in (e.verb.rawValue.lowercased(), operation(e)) }
            paths.append((path, .object(ops)))
        }
        return [
            "openapi": "3.1.0",
            "info": [
                "title": "Peel Good Inc.",
                "version": .string(appVersion),
                "description": "Print shipping labels from other apps on this Mac. The server only listens on 127.0.0.1. Send the token from ~/Library/Application Support/Peel Good/token as a bearer token. Requests with an Origin header are refused. Only files sent with a request can print.",
            ],
            "servers": [["url": .string("http://127.0.0.1:\(port)")]],
            "security": [["bearer": []]],
            "tags": .array(tags.map { ["name": .string($0)] }),
            "paths": .object(paths),
            "components": [
                "securitySchemes": ["bearer": ["type": "http", "scheme": "bearer", "description": "Contents of ~/Library/Application Support/Peel Good/token."]],
                "schemas": .object(components.map { ($0.0, $0.1.json) }),
            ],
        ]
    }

    private static func operation(_ e: Endpoint) -> JSONValue {
        var op: [(String, JSONValue)] = [
            ("operationId", .string(e.operationID)),
            ("tags", [.string(e.tag)]),
            ("summary", .string(e.summary)),
            ("description", .string(e.detail)),
        ]
        if !e.authenticated { op.append(("security", [])) }
        if !e.parameters.isEmpty {
            op.append(("parameters", .array(e.parameters.map { p in
                var pairs: [(String, JSONValue)] = [("name", .string(p.name)), ("in", .string(p.location.rawValue)),
                                                    ("required", .bool(p.required)), ("schema", p.schema.json),
                                                    ("example", .string(p.example))]
                if let d = p.schema.summary { pairs.insert(("description", .string(d)), at: 3) }
                return .object(pairs)
            })))
        }
        if !e.body.isEmpty {
            op.append(("requestBody", ["required": .bool(e.bodyRequired), "content": content(e.body)]))
        }
        op.append(("responses", .object(e.responses.map { r in
            var pairs: [(String, JSONValue)] = [("description", .string(r.description))]
            if !r.content.isEmpty { pairs.append(("content", content(r.content))) }
            return (String(r.status), .object(pairs))
        })))
        return .object(op)
    }

    private static func content(_ items: [Content]) -> JSONValue {
        .object(items.map { c in
            var pairs: [(String, JSONValue)] = [("schema", c.schema.json)]
            if let example = c.example { pairs.append(("example", example)) }
            return (c.mediaType, .object(pairs))
        })
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Snippets

    /// Shell-safe path to the token, for pasting into Terminal.
    static let tokenShellPath = "~/Library/Application\\ Support/Peel\\ Good/token"
    static let authHeader = "-H \"Authorization: Bearer $(cat \(tokenShellPath))\""

    static func baseURL(port: Int) -> String { "http://127.0.0.1:\(port)" }

    /// Ready-to-run curl commands for an endpoint, one per way of calling it.
    static func curl(_ e: Endpoint, port: Int) -> [(title: String, command: String)] {
        let url = baseURL(port: port) + e.examplePath
        let auth = e.authenticated ? " \(authHeader)" : ""
        switch e.operationID {
        case "print":
            return [
                ("Upload", "curl -s\(auth) -F file=@label.pdf -F size=4x6 \(url)"),
                ("Raw body", "curl -s\(auth) -H 'Content-Type: application/pdf' --data-binary @label.pdf '\(url)?size=4x6&filename=label.pdf'"),
            ]
        case "preview":
            return [
                ("PNG", "curl -s\(auth) -F file=@label.pdf -o preview.png '\(url)?format=png&index=0'"),
                ("JSON", "curl -s\(auth) -F file=@label.pdf \(url)"),
            ]
        default:
            return [("", "curl -s\(auth) \(url)")]
        }
    }

    /// The example body for an endpoint, pretty-printed.
    static func exampleJSON(_ e: Endpoint) -> String? {
        (e.body.first { $0.mediaType == "application/json" }?.example
            ?? e.responses.first { $0.status == 200 }?.content.first { $0.mediaType == "application/json" }?.example)?.serialized()
    }

    static func responseExample(_ e: Endpoint) -> String? {
        e.responses.first { $0.status == 200 }?.content.first { $0.mediaType == "application/json" }?.example?.serialized()
    }

    static func requestExample(_ e: Endpoint) -> String? {
        e.body.first { $0.mediaType == "application/json" }?.example?.serialized()
    }

    /// Example keys that the schema doesn't list, or required keys the example lacks. Empty when they agree.
    static func selfCheck() -> [String] {
        var problems: [String] = []
        func check(_ schema: Schema, _ value: JSONValue, _ at: String) {
            switch (schema, value) {
            case (.ref(let name), _):
                if let s = component(name) { check(s, value, "\(at)<\(name)>") } else { problems.append("\(at): no component \(name)") }
            case (.array(let item, _), .array(let values)):
                values.forEach { check(item, $0, at + "[]") }
            case (.object(let fields, _), .object(let pairs)):
                for (key, v) in pairs {
                    if let f = fields.first(where: { $0.name == key }) { check(f.schema, v, "\(at).\(key)") } else if !fields.isEmpty { problems.append("\(at): \(key) not in schema") }
                }
                for f in fields where f.required && !pairs.contains(where: { $0.0 == f.name }) { problems.append("\(at): missing \(f.name)") }
            default: break
            }
        }
        for e in endpoints {
            for c in e.body + e.responses.flatMap(\.content) {
                if let ex = c.example { check(c.schema, ex, "\(e.operationID) \(c.mediaType)") }
            }
        }
        return problems
    }
}
