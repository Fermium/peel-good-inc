import Foundation
import Network

/// HTTP/1.1 on 127.0.0.1 for IPP: what the CUPS `ipp` backend sends (keep-alive, chunked bodies,
/// `Expect: 100-continue`, which libcups otherwise waits a second for). Hummingbird doesn't answer
/// 100-continue, hence this small server. Approach after fake_printer (Apache-2.0).
/// Anything on this Mac can connect, so the input is treated as hostile: sizes are checked, connections
/// are capped and time out, and stop() closes them all.
final class IPPServer: @unchecked Sendable {
    typealias Handler = @Sendable (IPPMessage) async -> IPPMessage

    static let maxConnections = 16

    let host: String
    let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    /// Touched only on `queue`.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "PeelGood.IPPServer")

    init(host: String, port: UInt16, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.handler = handler
    }

    /// Starts listening on `host` (loopback) only. Calls `ready` once: nil when listening, or the error.
    /// No address reuse: if another process holds the port, starting fails instead of sharing it.
    func start(ready: @escaping @Sendable (Error?) -> Void) {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: params)
            let handler = handler, queue = queue
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connections.count < Self.maxConnections else { return connection.cancel() }
                let id = ObjectIdentifier(connection)
                self.connections[id] = connection
                Task {
                    await IPPConnection(connection, handler: handler).run(on: queue)
                    queue.async { self.connections[id] = nil }
                }
            }
            var reported = false
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready where !reported:
                    reported = true
                    ready(nil)
                case .failed(let error):
                    listener?.cancel()
                    if !reported { reported = true; ready(error) }
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            ready(error)
        }
    }

    /// Only this Mac, by its own name: a web page that rebinds its domain to 127.0.0.1 sends its own
    /// Host, and browsers add Origin. CUPS sends neither. Same rule as the HTTP API.
    /// `headers` has lowercased names.
    static func isLocal(_ headers: [String: String], port: UInt16) -> Bool {
        let host = headers["host"]?.lowercased()
        return (host == "127.0.0.1:\(port)" || host == "localhost:\(port)") && headers["origin"] == nil
    }

    /// Stops listening and closes every open connection.
    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            for c in self.connections.values { c.cancel() }
            self.connections.removeAll()
        }
    }
}

private actor IPPConnection {
    /// Labels are small; a print job bigger than this is refused.
    private static let maxBody = 64 * 1024 * 1024
    /// A client that sends nothing for this long is dropped.
    private static let readTimeout: TimeInterval = 30
    private let connection: NWConnection
    private let handler: IPPServer.Handler
    private var buffer = Data()

    init(_ connection: NWConnection, handler: @escaping IPPServer.Handler) {
        self.connection = connection
        self.handler = handler
    }

    func run(on queue: DispatchQueue) async {
        connection.start(queue: queue)
        defer { connection.cancel() }
        do {
            while try await serveOne() {}
        } catch {
            // The other end closing between requests is how keep-alive ends.
        }
    }

    /// One request; false when the connection should close.
    private func serveOne() async throws -> Bool {
        let head = try await readUntil("\r\n\r\n", limit: 64 * 1024)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return false }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let keepAlive = headers["connection"]?.lowercased() != "close"
        guard IPPServer.isLocal(headers, port: VirtualPrinter.port) else {
            Log.warning(.app, "printer: refused a request (Host \(headers["host"] ?? "missing")\(headers["origin"] != nil ? ", from a web page" : ""))")
            try await respond(status: "403 Forbidden", type: "text/plain", body: Data("Only this Mac can print here.\n".utf8), keepAlive: false)
            return false
        }
        if headers["expect"]?.lowercased() == "100-continue" { try await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }

        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try await readChunked()
        } else if let raw = headers["content-length"] {
            // Digits only: a sign or junk would otherwise become a negative or wrong length.
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(raw), length <= Self.maxBody else { return false }
            body = try await read(length)
        } else {
            body = Data()
        }

        guard parts[0] == "POST", headers["content-type"]?.hasPrefix("application/ipp") == true,
              let request = try? IPPCodec.decode(body) else {
            let text = Data("\(VirtualPrinter.name) prints PDFs sent here over IPP.\n".utf8)
            try await respond(status: parts[0] == "GET" ? "200 OK" : "400 Bad Request", type: "text/plain", body: text, keepAlive: keepAlive)
            return keepAlive
        }
        let response = await handler(request)
        try await respond(status: "200 OK", type: "application/ipp", body: IPPCodec.encode(response), keepAlive: keepAlive)
        return keepAlive
    }

    private func respond(status: String, type: String, body: Data, keepAlive: Bool) async throws {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
        try await send(Data(head.utf8) + body)
    }

    // MARK: Reading

    private func readUntil(_ terminator: String, limit: Int) async throws -> String {
        let t = Data(terminator.utf8)
        while true {
            if let r = buffer.range(of: t) {
                let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return line
            }
            guard buffer.count <= limit else { throw IPPCodec.Truncated() }
            try await fill()
        }
    }

    private func read(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw IPPCodec.Truncated() }
        while buffer.count < count { try await fill() }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    private func readChunked() async throws -> Data {
        var body = Data()
        while true {
            let line = try await readUntil("\r\n", limit: 1024)
            // 1 to 8 hex digits, no sign: anything else is refused before it can overflow or go negative.
            let digits = line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard (1...8).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }), let size = Int(digits, radix: 16) else {
                throw IPPCodec.Truncated()
            }
            if size == 0 {
                while try await readUntil("\r\n", limit: 16 * 1024) != "" {}
                return body
            }
            guard size <= Self.maxBody - body.count else { throw IPPCodec.Truncated() }
            body.append(try await read(size))
            _ = try await readUntil("\r\n", limit: 2)
        }
    }

    private func fill() async throws {
        let connection = connection
        // Cancelling the connection ends the pending receive with an error.
        let timeout = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.readTimeout, execute: timeout)
        defer { timeout.cancel() }
        let chunk: Data? = try await withCheckedThrowingContinuation { c in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, error in
                if let error { c.resume(throwing: error) } else if let data, !data.isEmpty { c.resume(returning: data) } else { c.resume(returning: done ? nil : Data()) }
            }
        }
        guard let chunk else { throw IPPCodec.Truncated() }
        buffer.append(chunk)
    }

    private func send(_ data: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
}
