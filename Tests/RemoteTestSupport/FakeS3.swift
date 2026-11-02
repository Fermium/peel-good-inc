import CoreGraphics
import Foundation
import Network
import PeelGoodRemote

/// A small S3 on loopback: paged listings and GETs, with the clock and failures under test control.
public final class FakeS3: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var objects: [String: (data: Data, modified: Date, etag: String)] = [:]
    private var listener: NWListener!
    private var _clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var _status: Int?
    private var _redirect = false
    private var _requests: [String] = []
    public var pageSize = 1000
    public private(set) var port: UInt16 = 0

    public var clock: Date { get { lock.withLock { _clock } } set { lock.withLock { _clock = newValue } } }
    public var failWith: Int? { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
    public var redirects: Bool { get { lock.withLock { _redirect } } set { lock.withLock { _redirect = newValue } } }
    public var requests: [String] { lock.withLock { _requests } }

    public func put(_ key: String, _ data: Data = FakeS3.pdf(), at date: Date? = nil) {
        lock.withLock { objects[key] = (data, date ?? _clock, "etag-\(data.count)-\(objects.count)") }
    }

    public func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .global())
            self?.serve(c)
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

    public func stop() { listener.cancel() }

    public var source: S3Source {
        S3Source(endpoint: "http://127.0.0.1:\(port)", region: "us-east-1", bucket: "labels", prefix: "out/", accessKey: "KEY", pathStyle: true)
    }

    public func feed() throws -> S3Feed { S3Feed(client: try S3Client(source: source, secret: "SECRET", now: { [weak self] in self?.clock ?? Date() })) }

    private func serve(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8) else { return c.cancel() }
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            lock.withLock { self._requests.append(target) }
            let reply = respond(target: target, signed: head.lowercased().contains("authorization: aws4-hmac-sha256"))
            c.send(content: reply, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    private func respond(target: String, signed: Bool) -> Data {
        lock.lock(); defer { lock.unlock() }
        let parts = URLComponents(string: target)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = f.string(from: _clock)
        func http(_ code: Int, _ body: Data, extra: String = "") -> Data {
            Data("HTTP/1.1 \(code) X\r\nDate: \(date)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extra)\r\n".utf8) + body
        }
        if _redirect { return http(301, Data(), extra: "Location: http://127.0.0.1:1/stolen\r\n") }
        if !signed { return http(403, Data("<Error><Code>AccessDenied</Code></Error>".utf8)) }
        if let code = _status { return http(code, Data("<Error><Code>Nope</Code></Error>".utf8)) }
        let path = parts?.path ?? ""
        if parts?.queryItems?.contains(where: { $0.name == "list-type" }) == true {
            let prefix = parts?.queryItems?.first { $0.name == "prefix" }?.value ?? ""
            let start = parts?.queryItems?.first { $0.name == "continuation-token" }?.value.flatMap(Int.init) ?? 0
            let keys = objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
            let page = keys.dropFirst(start).prefix(pageSize)
            let more = start + page.count < keys.count
            let iso = ISO8601DateFormatter()
            let items = page.map { k -> String in
                let o = objects[k]!
                return "<Contents><Key>\(k.replacingOccurrences(of: "&", with: "&amp;"))</Key><LastModified>\(iso.string(from: o.modified))</LastModified><ETag>&quot;\(o.etag)&quot;</ETag><Size>\(o.data.count)</Size></Contents>"
            }.joined()
            let xml = "<ListBucketResult><IsTruncated>\(more)</IsTruncated>\(more ? "<NextContinuationToken>\(start + page.count)</NextContinuationToken>" : "")\(items)</ListBucketResult>"
            return http(200, Data(xml.utf8))
        }
        let key = String(path.dropFirst("/labels/".count))
        guard let o = objects[key] else { return http(404, Data("<Error><Code>NoSuchKey</Code></Error>".utf8)) }
        return http(200, o.data)
    }

    public static func pdf(pages: Int = 1, padding: Int = 0) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 288, height: 432)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data + Data(repeating: 0x20, count: padding)
    }
}
