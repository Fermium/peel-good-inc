import Foundation
import HTTPTypes
import Hummingbird
import Logging
import os

/// What the server needs to know on every request, readable from any thread.
final class APIServerState: Sendable {
    struct Snapshot: Sendable {
        var token = ""
        var http = false
        var mcp = false
        var port = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: Snapshot())

    var snapshot: Snapshot { lock.withLock { $0 } }
    func update(_ change: @Sendable (inout Snapshot) -> Void) { lock.withLock { change(&$0) } }
}

/// Sliding one-minute windows: one for every `/v1` request, one for print and preview.
final class RateLimiter: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (all: [ContinuousClock.Instant](), prints: [ContinuousClock.Instant]()))

    /// Seconds to wait, or nil if the request may go ahead (and is counted).
    func admit(isPrint: Bool) -> Int? {
        let now = ContinuousClock.now
        return lock.withLock { s in
            s.all.removeAll { now - $0 > .seconds(60) }
            s.prints.removeAll { now - $0 > .seconds(60) }
            if s.all.count >= APILimits.requestsPerMinute { return Self.wait(s.all, now) }
            if isPrint && s.prints.count >= APILimits.printsPerMinute { return Self.wait(s.prints, now) }
            s.all.append(now)
            if isPrint { s.prints.append(now) }
            return nil
        }
    }

    private static func wait(_ window: [ContinuousClock.Instant], _ now: ContinuousClock.Instant) -> Int {
        guard let oldest = window.first else { return 1 }
        return max(1, Int(((oldest + .seconds(60)) - now).components.seconds) + 1)
    }
}

struct APIContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    let remoteIP: String?

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        remoteIP = source.channel.remoteAddress?.ipAddress
    }

    var maxUploadSize: Int { APILimits.maxBodyBytes }
}

/// Every request: loopback peer, Host header, then per path the switch, Origin and token checks.
struct APIResponder: HTTPResponder {
    let state: APIServerState
    let mcp: MCPSessions
    let limiter = RateLimiter()

    func respond(to request: Request, context: APIContext) async throws -> Response {
        let started = ContinuousClock.now
        let path = request.uri.path
        let reply = await route(request, context, path: path)
        let ms = (ContinuousClock.now - started).components
        let elapsed = Double(ms.seconds) * 1000 + Double(ms.attoseconds) / 1e15
        let line = "\(request.method.rawValue) \(path) \(reply.status) \(String(format: "%.0f", elapsed)) ms\(reply.errorCode.map { " (\($0))" } ?? "")"
        if reply.status >= 500 { Log.error(.api, line) } else if reply.status >= 400 { Log.warning(.api, line) } else { Log.info(.api, line) }
        return Self.response(reply)
    }

    private func route(_ request: Request, _ context: APIContext, path: String) async -> APIReply {
        let s = state.snapshot
        guard Self.isLoopback(context.remoteIP) else {
            return .error(APIError(status: 403, code: "not_local", message: "Only this Mac can connect."))
        }
        let host = request.head.authority?.lowercased() ?? ""
        guard host == "127.0.0.1:\(s.port)" || host == "localhost:\(s.port)" else {
            return .error(APIError(status: 403, code: "bad_host", message: "Host must be 127.0.0.1:\(s.port)."))
        }
        let method = request.method.rawValue

        switch path {
        case "/", "/openapi.json":
            guard s.http else { return .error(.notFound("HTTP API is off.", code: "http_off")) }
            guard method == "GET" || method == "HEAD" else {
                return .error(APIError(status: 405, code: "method_not_allowed", message: "Use GET."))
            }
            if path == "/" { return .text(DocsPage.html(port: s.port), type: "text/html; charset=utf-8") }
            return .text(OpenAPI.document(port: s.port).serialized() + "\n", type: "application/json; charset=utf-8")

        case "/mcp":
            guard s.mcp else { return .error(.notFound("MCP server is off.", code: "mcp_off")) }
            if let denied = authenticate(request, s, method: method, path: path) { return denied }
            guard let r = await collect(request, context, path: path) else { return .error(Self.tooLarge) }
            return await mcp.handle(r)

        case _ where path == "/v1" || path.hasPrefix("/v1/"):
            guard s.http else { return .error(.notFound("HTTP API is off.", code: "http_off")) }
            if request.headers[.origin] != nil {
                Log.warning(.api, "refused \(method) \(path): request has an Origin header")
                return .error(APIError(status: 403, code: "origin_not_allowed", message: "Requests from web pages aren't allowed."))
            }
            if let denied = authenticate(request, s, method: method, path: path) { return denied }
            if let wait = limiter.admit(isPrint: method == "POST") {
                return .error(APIError(status: 429, code: "rate_limited", message: "Too many requests. Try again in \(wait) seconds."),
                              headers: [("Retry-After", String(wait))])
            }
            guard let r = await collect(request, context, path: path) else { return .error(Self.tooLarge) }
            return await Self.dispatch(r, APIRoutes.ServerFlags(http: s.http, mcp: s.mcp, port: s.port))

        default:
            return .error(.notFound("No endpoint at \(path).", code: "no_endpoint"))
        }
    }

    static let tooLarge = APIError(status: 413, code: "too_large", message: "Requests can be at most \(APILimits.maxBodyBytes / 1_048_576) MB.")

    @MainActor
    private static func dispatch(_ r: APIRequest, _ flags: APIRoutes.ServerFlags) async -> APIReply {
        guard let service = APIController.shared.service else { return .error(.failed("Peel Good Inc. isn't ready.", code: "not_ready")) }
        return await APIRoutes.handle(r, service: service, flags: flags)
    }

    private func authenticate(_ request: Request, _ s: APIServerState.Snapshot, method: String, path: String) -> APIReply? {
        let header = request.headers[.authorization] ?? ""
        let reason: String
        if header.isEmpty {
            reason = "missing token"
        } else if header.count > 7, header.prefix(7).lowercased() == "bearer ",
                  Self.constantTimeEqual(String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces), s.token) {
            return nil
        } else {
            reason = "wrong token"
        }
        Log.warning(.api, "auth failed for \(method) \(path): \(reason)")
        return .error(APIError(status: 401, code: "unauthorized", message: "Send the token from ~/Library/Application Support/Peel Good/token as a bearer token."),
                      headers: [("WWW-Authenticate", "Bearer realm=\"Peel Good Inc.\"")])
    }

    private func collect(_ request: Request, _ context: APIContext, path: String) async -> APIRequest? {
        let body: Data
        do {
            let buffer = try await request.body.collect(upTo: context.maxUploadSize)
            body = Data(buffer.readableBytesView)
        } catch {
            return nil
        }
        var headers: [String: String] = [:]
        for field in request.headers {
            let name = field.name.canonicalName
            headers[name] = headers[name].map { "\($0), \(field.value)" } ?? field.value
        }
        var query: [String: String] = [:]
        if let q = request.uri.query {
            for item in URLComponents(string: "?" + q)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        return APIRequest(method: request.method.rawValue, path: path, query: query, headers: headers, body: body)
    }

    static func response(_ reply: APIReply) -> Response {
        var fields = HTTPFields()
        for (name, value) in reply.headers {
            if let n = HTTPField.Name(name) { fields.append(HTTPField(name: n, value: value)) }
        }
        fields[.cacheControl] = fields[.cacheControl] ?? "no-store"
        fields[.init("X-Content-Type-Options")!] = "nosniff"
        let status = HTTPResponse.Status(code: reply.status)
        switch reply.body {
        case .data(let data):
            return Response(status: status, headers: fields, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
        case .stream(let stream):
            return Response(status: status, headers: fields, body: ResponseBody(asyncSequence: stream.map { ByteBuffer(bytes: $0) }))
        }
    }

    static func isLoopback(_ ip: String?) -> Bool {
        guard let ip else { return false }
        return ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("::ffff:127.")
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !y.isEmpty else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// One running Hummingbird server bound to 127.0.0.1.
final class APIServer: Sendable {
    let port: Int
    let mcp: MCPSessions
    private let task: Task<Void, Never>

    /// Starts listening. `onRunning` gets the bound port; `onExit` gets the error that stopped it, if any.
    init(port: Int, state: APIServerState, onRunning: @escaping @Sendable (Int) -> Void, onExit: @escaping @Sendable (Error?) -> Void) {
        self.port = port
        let mcp = MCPSessions(port: port)
        self.mcp = mcp
        var logger = Logger(label: "com.fermiumlabs.labelize.api")
        logger.logLevel = .critical   // stopping cancels open keep-alive connections, which Hummingbird logs as errors
        let app = Application(
            responder: APIResponder(state: state, mcp: mcp),
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: nil),
            onServerRunning: { channel in onRunning(channel.localAddress?.port ?? port) },
            logger: logger
        )
        task = Task {
            do {
                try await app.run()
                onExit(nil)
            } catch {
                onExit(error)
            }
        }
    }

    func stop() async {
        await mcp.closeAll()
        task.cancel()
        await task.value
    }
}
