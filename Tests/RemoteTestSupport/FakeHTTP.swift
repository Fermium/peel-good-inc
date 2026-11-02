import Foundation
import Network

/// A small web server on loopback for a feed to talk to: scripted replies, recorded requests, and event
/// streams that stay open until told otherwise.
public final class FakeHTTP: @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        public var path: String
        public var headers: [String: String]
        public var body: Data
    }

    public enum Reply: Sendable {
        case full(Int, [String: String], Data)
        case stream
    }

    private let lock = NSLock()
    private var listener: NWListener!
    private var _requests: [Request] = []
    private var _handler: @Sendable (Request) -> Reply = { _ in .full(404, [:], Data()) }
    private var streams: [NWConnection] = []
    public private(set) var port: UInt16 = 0

    public init() {}

    public var requests: [Request] { lock.withLock { _requests } }
    public var openStreams: Int { lock.withLock { streams.count } }
    public func handle(_ handler: @escaping @Sendable (Request) -> Reply) { lock.withLock { _handler = handler } }
    public var base: String { "http://127.0.0.1:\(port)" }

    public func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .global())
            self?.read(c, Data())
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let self, self.port == 0 {
                    self.port = self.listener.port!.rawValue
                    done.resume()
                }
            }
            listener.start(queue: .global())
        }
    }

    public func stop() {
        listener.cancel()
        closeStreams()
    }

    /// Sends to every open stream.
    public func push(_ text: String) {
        for c in lock.withLock({ streams }) { c.send(content: Data(text.utf8), completion: .contentProcessed { _ in }) }
    }

    public func closeStreams() {
        let open = lock.withLock { () -> [NWConnection] in defer { streams = [] }; return streams }
        for c in open { c.cancel() }
    }

    private func read(_ c: NWConnection, _ soFar: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, _ in
            guard let self else { return c.cancel() }
            let all = soFar + (data ?? Data())
            guard let end = all.range(of: Data("\r\n\r\n".utf8)) else {
                if done { c.cancel() } else { self.read(c, all) }
                return
            }
            let lines = String(decoding: all[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { headers[parts[0].lowercased()] = parts[1] }
            }
            let body = Data(all[end.upperBound...])
            if let length = headers["content-length"].flatMap(Int.init), body.count < length {
                self.read(c, all)
                return
            }
            let request = Request(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
            let reply = self.lock.withLock { () -> Reply in
                self._requests.append(request)
                return self._handler(request)
            }
            switch reply {
            case .full(let status, let extra, let bytes):
                var head = "HTTP/1.1 \(status) X\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n"
                for (k, v) in extra { head += "\(k): \(v)\r\n" }
                c.send(content: Data((head + "\r\n").utf8) + bytes, completion: .contentProcessed { _ in c.cancel() })
            case .stream:
                self.lock.withLock { self.streams.append(c) }
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                c.send(content: Data(": connected\n\n".utf8), completion: .contentProcessed { _ in })
            }
        }
    }
}
