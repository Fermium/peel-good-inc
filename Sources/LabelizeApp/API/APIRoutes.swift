import Foundation

/// A request as the routes see it, independent of the HTTP server.
struct APIRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String] = [:]
    /// Lowercased names.
    var headers: [String: String] = [:]
    var body = Data()

    init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, b in "\(a), \(b)" })
        self.body = body
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct APIReply: Sendable {
    enum Body: Sendable {
        case data(Data)
        case stream(AsyncThrowingStream<Data, Error>)
    }

    var status: Int
    var headers: [(String, String)] = []
    var body: Body = .data(Data())
    /// Stable error code, for the request log.
    var errorCode: String?

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> APIReply {
        let data = (try? APIJSON.encoder.encode(value)) ?? Data()
        return APIReply(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: .data(data + Data("\n".utf8)))
    }

    static func error(_ e: APIError, headers: [(String, String)] = []) -> APIReply {
        var reply = json(APIErrorBody(error: .init(code: e.code, message: e.message)), status: e.status)
        reply.headers += headers
        reply.errorCode = e.code
        return reply
    }

    static func text(_ text: String, type: String, status: Int = 200) -> APIReply {
        APIReply(status: status, headers: [("Content-Type", type)], body: .data(Data(text.utf8)))
    }
}

/// The `/v1` endpoints. Authentication and origin checks happen before this, in `APIServer`.
enum APIRoutes {
    struct ServerFlags: Sendable {
        var http: Bool
        var mcp: Bool
        var port: Int
    }

    @MainActor
    static func handle(_ r: APIRequest, service: LabelService, flags: ServerFlags) async -> APIReply {
        let parts = r.path.split(separator: "/", omittingEmptySubsequences: true).map { $0.removingPercentEncoding ?? String($0) }
        do {
            switch (r.method, parts) {
            case ("GET", ["v1", "health"]):
                return .json(APIHealth(status: "ok", version: OpenAPI.appVersion, http: flags.http, mcp: flags.mcp, port: flags.port))
            case ("GET", ["v1", "printers"]):
                return .json(service.printers())
            case ("GET", let p) where p.count == 4 && p[0] == "v1" && p[1] == "printers" && p[3] == "sizes":
                return .json(try service.sizes(printer: p[2]))
            case ("POST", ["v1", "print"]):
                let input = try await parse(r)
                defer { input.cleanUp() }
                return .json(try await service.print(files: input.files, request: input.request, source: "file"))
            case ("POST", ["v1", "preview"]):
                let input = try await parse(r)
                defer { input.cleanUp() }
                let preview = try await service.preview(files: input.files, request: input.request)
                return try previewReply(preview, r)
            case ("POST", ["v1", "print", "clipboard"]):
                let request = try decodeJSON(APIPrintRequest.self, r) ?? APIPrintRequest()
                return .json(try await service.printClipboard(request: merge(request, query: r.query)))
            case ("POST", ["v1", "reprint"]):
                let body = try decodeJSON(APIReprintRequest.self, r)
                let copies = try body?.copies ?? r.query["copies"].map { try int($0, "copies") }
                return .json(try await service.reprintLast(copies: copies))
            case ("GET", ["v1", "jobs"]):
                return .json(service.jobs())
            default:
                let known = OpenAPI.endpoints.contains { e in
                    e.path.split(separator: "/").count == parts.count
                        && zip(e.path.split(separator: "/"), parts).allSatisfy { $0.hasPrefix("{") || $0 == $1 }
                }
                if known { return .error(APIError(status: 405, code: "method_not_allowed", message: "\(r.method) isn't allowed on \(r.path).")) }
                return .error(.notFound("No endpoint at \(r.path).", code: "no_endpoint"))
            }
        } catch let e as APIError {
            return .error(e)
        } catch {
            return .error(.failed("\(error)", code: "internal"))
        }
    }

    // MARK: Preview

    private static func previewReply(_ preview: APIPreview, _ r: APIRequest) throws -> APIReply {
        let wantsPNG = r.query["format"]?.lowercased() == "png" || (r.header("accept")?.lowercased().hasPrefix("image/png") ?? false)
        guard wantsPNG else { return .json(preview) }
        let index = try r.query["index"].map { try int($0, "index") } ?? 0
        guard preview.images.indices.contains(index) else {
            throw APIError.badRequest("Index \(index) is out of range: there are \(preview.images.count) labels.", code: "invalid_index")
        }
        let image = preview.images[index]
        return APIReply(status: 200, headers: [
            ("Content-Type", "image/png"),
            ("X-Label-Count", String(preview.images.count)),
            ("X-Codes-Found", String(preview.codesFound)),
            ("X-Codes-Verified", String(preview.codesVerified)),
        ], body: .data(image.png))
    }

    // MARK: Parsing input

    struct PrintInput: Sendable {
        var files: [URL]
        var request: APIPrintRequest
        /// Folder holding uploaded files, removed after the request.
        var scratch: URL?

        func cleanUp() {
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
        }
    }

    /// Multipart upload, JSON with a path, or a raw PDF or image body. Options can also come as query parameters.
    static func parse(_ r: APIRequest) async throws -> PrintInput {
        try await Task.detached(priority: .userInitiated) { try parseSync(r) }.value
    }

    nonisolated static func parseSync(_ r: APIRequest) throws -> PrintInput {
        let type = r.header("content-type") ?? ""
        var request = APIPrintRequest()
        var uploads: [(name: String, data: Data)] = []

        if let boundary = Multipart.boundary(from: type) {
            let form = try Multipart(data: r.body, boundary: boundary)
            request.path = form.field("path")
            request.printer = form.field("printer")
            request.size = form.field("size")
            request.fit = form.field("fit")
            request.ink = form.field("ink")
            request.copies = try form.field("copies").map { try int($0, "copies") }
            for (i, part) in form.files.enumerated() {
                uploads.append((try uploadName(part.filename, contentType: part.contentType, index: i), part.data))
            }
        } else if type.lowercased().hasPrefix("application/json") || (type.isEmpty && r.body.first == UInt8(ascii: "{")) {
            request = try decodeJSON(APIPrintRequest.self, r) ?? APIPrintRequest()
        } else if !r.body.isEmpty {
            uploads.append((try uploadName(r.query["filename"], contentType: type, index: 0), r.body))
        }
        request = try merge(request, query: r.query)

        var files: [URL] = []
        var scratch: URL?
        if !uploads.isEmpty {
            let folder = Intake.scratchFolder()
            scratch = folder
            for (name, data) in uploads {
                let url = folder.appendingPathComponent(name)
                try data.write(to: url)
                files.append(url)
            }
        }
        if let path = request.path, !path.isEmpty {
            files.insert(try resolvePath(path), at: 0)
        }
        guard !files.isEmpty else {
            throw APIError.badRequest("Send a file as multipart form data (field file), or JSON with a path.", code: "no_file")
        }
        return PrintInput(files: files, request: request, scratch: scratch)
    }

    nonisolated static func resolvePath(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw APIError.badRequest("Path must be absolute: \(path)", code: "relative_path") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue else {
            throw APIError.notFound("No file at \(expanded).", code: "file_not_found")
        }
        let url = URL(fileURLWithPath: expanded)
        guard Intake.isSupported(url) else {
            throw APIError(status: 415, code: "unsupported_type", message: "\(url.lastPathComponent) isn't a PDF, SVG or image.")
        }
        return url
    }

    /// A safe file name with an extension Labelize can read.
    nonisolated static func uploadName(_ filename: String?, contentType: String?, index: Int) throws -> String {
        var name = (filename.map { ($0 as NSString).lastPathComponent } ?? "").replacingOccurrences(of: ":", with: "-")
        if name.isEmpty || name.hasPrefix(".") { name = "Upload \(index + 1)" }
        if Intake.isSupported(URL(fileURLWithPath: name)) { return name }
        let ext: String? = switch contentType?.lowercased().split(separator: ";").first.map(String.init) {
        case "application/pdf": "pdf"
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/svg+xml": "svg"
        case "image/tiff": "tiff"
        case "image/gif": "gif"
        case "image/heic": "heic"
        default: nil
        }
        guard let ext else {
            throw APIError(status: 415, code: "unsupported_type", message: "\(filename ?? "The upload") isn't a PDF, SVG or image.")
        }
        return "\(name).\(ext)"
    }

    nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, _ r: APIRequest) throws -> T? {
        let body = r.body.drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        guard !body.isEmpty else { return nil }
        do {
            return try APIJSON.decoder.decode(T.self, from: Data(body))
        } catch {
            throw APIError.badRequest("Body isn't valid JSON for this endpoint: \(error.localizedDescription)", code: "bad_json")
        }
    }

    nonisolated static func merge(_ r: APIPrintRequest, query: [String: String]) throws -> APIPrintRequest {
        var r = r
        r.path = r.path ?? query["path"]
        r.printer = r.printer ?? query["printer"]
        r.size = r.size ?? query["size"]
        r.fit = r.fit ?? query["fit"]
        r.ink = r.ink ?? query["ink"]
        if r.copies == nil, let c = query["copies"] { r.copies = try int(c, "copies") }
        return r
    }

    nonisolated static func int(_ text: String, _ name: String) throws -> Int {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else {
            throw APIError.badRequest("\(name) must be a whole number.", code: "invalid_\(name)")
        }
        return n
    }
}
