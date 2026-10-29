import CoreGraphics
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

/// Limits for anything that arrives over the API.
enum APILimits {
    static let maxFileBytes = 25 * 1024 * 1024
    static let maxFiles = 10
    /// Labels per request: pages across all files.
    static let maxLabels = 50
    /// Whole request body; base64 MCP uploads are a third larger than the file.
    static let maxBodyBytes = 64 * 1024 * 1024
    /// Per minute, for all `/v1` requests and for print or preview.
    static let requestsPerMinute = 120
    static let printsPerMinute = 30
}

/// The `/v1` endpoints. Authentication and origin checks happen before this, in `APIServer`.
/// The HTTP API only prints or previews files sent with the request: no paths, clipboard, reprint or history.
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
                var job: APIJob?
                defer { input.cleanUp(after: job) }
                job = try await service.print(files: input.files, request: input.request, source: APIJob.Source.upload)
                return .json(job!.redacted, status: job!.status == .waiting ? 202 : 200)
            case ("POST", ["v1", "preview"]):
                let input = try await parse(r)
                defer { input.cleanUp() }
                let preview = try await service.preview(files: input.files, request: input.request)
                return try previewReply(preview, r)
            case ("GET", ["v1", "jobs"]):
                return .json(service.jobs().filter { $0.source == APIJob.Source.upload }.map(\.redacted))
            default:
                let known = OpenAPI.endpoints.contains { e in
                    e.path.split(separator: "/").count == parts.count
                        && zip(e.path.split(separator: "/"), parts).allSatisfy { $0.hasPrefix("{") || $0 == $1 }
                }
                if known { return .error(APIError(status: 405, code: "method_not_allowed", message: "\(r.method) isn't allowed on \(r.path).")) }
                return .error(.notFound("No endpoint at \(r.path).", code: "no_endpoint"))
            }
        } catch let e as APIError {
            // Print-system errors can name files in the history folder; keep them out of HTTP replies.
            return .error(e.status >= 500 ? APIError(status: e.status, code: e.code, message: "Printing failed. See the Peel Good Inc. log for details.") : e)
        } catch {
            return .error(.failed("Printing failed. See the Peel Good Inc. log for details.", code: "internal"))
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
        ], body: .data(image.png ?? Data()))
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

        /// A job still waiting for Print may re-read its files (a size change in the preview), so keep them a while.
        func cleanUp(after job: APIJob?) {
            guard job?.status == .waiting, let scratch else { return cleanUp() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3600) { try? FileManager.default.removeItem(at: scratch) }
        }
    }

    /// Files sent with the request: multipart form data (parts named file) or a raw PDF or image body.
    /// Options come as form fields or query parameters. Paths on this Mac are refused.
    static func parse(_ r: APIRequest) async throws -> PrintInput {
        try await Task.detached(priority: .userInitiated) { try parseSync(r) }.value
    }

    nonisolated static func parseSync(_ r: APIRequest) throws -> PrintInput {
        let type = r.header("content-type") ?? ""
        var request = APIPrintRequest()
        var uploads: [(name: String, data: Data)] = []

        if let boundary = Multipart.boundary(from: type) {
            let form = try Multipart(data: r.body, boundary: boundary)
            if form.field("path") != nil { throw pathRefused }
            request.printer = form.field("printer")
            request.size = form.field("size")
            request.fit = form.field("fit")
            request.ink = form.field("ink")
            request.copies = try APIPrintRequest.given(form.field("copies")).map { try int($0, "copies") }
            for (i, part) in form.files.enumerated() {
                uploads.append((try uploadName(part.filename, contentType: part.contentType, index: i), part.data))
            }
        } else if type.lowercased().hasPrefix("application/json") || type.lowercased().hasPrefix("application/x-www-form-urlencoded") {
            throw APIError(status: 415, code: "upload_required", message: "Send the file as multipart form data (field file) or as the request body.")
        } else if !r.body.isEmpty {
            uploads.append((try uploadName(r.query["filename"], contentType: type, index: 0), r.body))
        }
        if r.query["path"] != nil { throw pathRefused }
        request = try merge(request, query: r.query)
        request.path = nil

        guard !uploads.isEmpty else {
            throw APIError.badRequest("Send a file as multipart form data (field file) or as the request body.", code: "no_file")
        }
        return try save(uploads, request: request)
    }

    nonisolated static let pathRefused = APIError(status: 400, code: "path_not_allowed",
                                                  message: "The HTTP API only prints files sent with the request.")

    /// Checks the limits, then writes uploads to a temporary folder.
    nonisolated static func save(_ uploads: [(name: String, data: Data)], request: APIPrintRequest, local: [URL] = []) throws -> PrintInput {
        guard uploads.count + local.count <= APILimits.maxFiles else {
            throw APIError(status: 413, code: "too_many_files", message: "Send at most \(APILimits.maxFiles) files at a time.")
        }
        for u in uploads where u.data.count > APILimits.maxFileBytes {
            throw APIError(status: 413, code: "file_too_large", message: "\(u.name) is larger than \(APILimits.maxFileBytes / 1_048_576) MB.")
        }
        let folder = uploads.isEmpty ? nil : Intake.scratchFolder()
        var files = local
        do {
            for (name, data) in uploads {
                var url = folder!.appendingPathComponent(name)
                if files.contains(url) { url = folder!.appendingPathComponent("\(files.count + 1) \(name)") }
                try data.write(to: url)
                files.append(url)
            }
            let pages = files.reduce(0) { $0 + pageCount($1) }
            guard pages <= APILimits.maxLabels else {
                throw APIError(status: 413, code: "too_many_pages", message: "That's \(pages) labels. Send at most \(APILimits.maxLabels) pages at a time.")
            }
        } catch {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
        return PrintInput(files: files, request: request, scratch: folder)
    }

    /// Pages in a PDF; 1 for images (unreadable files fail later, when composing).
    nonisolated static func pageCount(_ url: URL) -> Int {
        guard url.pathExtension.lowercased() == "pdf" else { return 1 }
        return CGPDFDocument(url as CFURL)?.numberOfPages ?? 1
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
        guard let ext = Intake.format(mimeType: contentType)?.ext else {
            throw APIError(status: 415, code: "unsupported_type", message: "\(filename ?? "The upload") isn't a PDF, SVG or image.")
        }
        return "\(name).\(ext)"
    }

    nonisolated static func merge(_ r: APIPrintRequest, query: [String: String]) throws -> APIPrintRequest {
        let given = APIPrintRequest.given
        var r = r.normalized
        r.path = r.path ?? given(query["path"])
        r.printer = r.printer ?? given(query["printer"])
        r.size = r.size ?? given(query["size"])
        r.fit = r.fit ?? given(query["fit"])
        r.ink = r.ink ?? given(query["ink"])
        if r.copies == nil, let c = given(query["copies"]) { r.copies = try int(c, "copies") }
        return r
    }

    nonisolated static func int(_ text: String, _ name: String) throws -> Int {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else {
            throw APIError.badRequest("\(name) must be a whole number.", code: "invalid_\(name)")
        }
        return n
    }
}
