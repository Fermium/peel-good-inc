import CryptoKit
import Darwin
import Foundation

/// Which addresses a source may reach. A job can name a URL, so a compromised source
/// could otherwise aim this Mac at its own network. Only the configured host gets the token.
struct LinkPolicy: Sendable {
    let origin: URLComponents
    let downloadHosts: Set<String>

    init(primary: String, downloadHosts: [String]) throws {
        origin = try SecureURL.check(primary)
        self.downloadHosts = Set(downloadHosts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    func isOrigin(_ url: URL) -> Bool {
        url.host()?.lowercased() == origin.host?.lowercased() && url.scheme == origin.scheme && url.port == origin.port
    }

    /// Throws unless this is an address files can come from.
    func check(_ url: URL) throws {
        let host = url.host()?.lowercased() ?? ""
        guard !host.isEmpty, url.user == nil, url.password == nil else { throw RemoteError.refusedAddress(host.isEmpty ? "an address with no host" : host) }
        if host == origin.host?.lowercased() {
            // Plain http only where the source itself was set up that way: loopback.
            guard url.scheme == "https" || url.scheme == origin.scheme else { throw RemoteError.refusedAddress(host) }
            return
        }
        guard url.scheme == "https", downloadHosts.contains(host), !Self.isPrivate(host) else { throw RemoteError.refusedAddress(host) }
    }

    /// Whether a host is, or resolves to, this Mac, its network or a cloud metadata address. A name
    /// could still change between this check and the connection; the https requirement limits that.
    static func isPrivate(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return false }
        defer { freeaddrinfo(info) }
        for ai in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = ai.pointee.ai_addr else { continue }
            if address.pointee.sa_family == sa_family_t(AF_INET) {
                let v4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if isPrivateIPv4(v4) { return true }
            } else if address.pointee.sa_family == sa_family_t(AF_INET6) {
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
                if isPrivateIPv6(bytes) { return true }
            }
        }
        return false
    }

    static func isPrivateIPv4(_ a: UInt32) -> Bool {
        let top = a >> 24, second = (a >> 16) & 0xFF
        return top == 0 || top == 10 || top == 127 || (top == 169 && second == 254) || (top == 172 && (16...31).contains(second))
            || (top == 192 && second == 168) || (top == 100 && (64...127).contains(second))
    }

    static func isPrivateIPv6(_ b: [UInt8]) -> Bool {
        if b[..<15].allSatisfy({ $0 == 0 }) && b[15] <= 1 { return true }   // :: and ::1
        if b[0] & 0xFE == 0xFC { return true }                              // fc00::/7
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }              // fe80::/10
        if b[..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {   // IPv4-mapped
            return isPrivateIPv4(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
        }
        return false
    }
}

/// Follows redirects only to addresses the policy allows, and never carries the token off the origin.
private final class SafeRedirects: NSObject, URLSessionTaskDelegate {
    let policy: LinkPolicy
    init(policy: LinkPolicy) { self.policy = policy }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, (try? policy.check(url)) != nil else { return nil }
        var next = request
        if !policy.isOrigin(url) { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        return next
    }
}

/// One entry in a jobs list, or one stream event's data. See docs/REMOTE-SOURCES.md.
struct RemoteJob: Decodable {
    var id: String
    var url: String?
    var name: String?
    var sha256: String?
    var copies: Int?
    var content_base64: String?

    /// 1 to 256 of A-Z, a-z, 0-9, `-`, `_` and `.`, as docs/REMOTE-SOURCES.md says.
    static func isValidID(_ id: String) -> Bool {
        (1...256).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E: true
            default: false
            }
        }
    }

    func item(now: Date) -> RemoteItem? {
        guard Self.isValidID(id), copies.map(RemoteLimits.copies.contains) != false else { return nil }
        var inline: Data?
        if let content_base64 {
            guard let data = Data(base64Encoded: content_base64, options: .ignoreUnknownCharacters), data.count <= RemoteLimits.inlineBytes else { return nil }
            inline = data
        } else if url == nil {
            return nil
        }
        let fromURL = url.flatMap(URLComponents.init(string:))?.path.split(separator: "/").last.map(String.init)
        return RemoteItem(id: id, key: url ?? "inline:\(id)", name: name ?? fromURL ?? id, size: inline?.count ?? 0, modified: now,
                          copies: copies, inline: inline, sha256: sha256)
    }
}

/// A URL to fetch on an interval, a stream to follow, or both. Anything can answer: an app, or a file on a CDN.
public final class HTTPFeed: RemoteFeed, Sendable {
    private struct JobList: Decodable { var jobs: [Lenient] }
    /// One bad job doesn't lose the others.
    private struct Lenient: Decodable {
        var job: RemoteJob?
        init(from decoder: Decoder) { job = try? RemoteJob(from: decoder) }
    }

    private let source: HTTPSource
    private let token: String?
    private let policy: LinkPolicy
    private let session: URLSession
    private let streamSession: URLSession
    private let now: @Sendable () -> Date
    public let sendsAcknowledgements: Bool

    public init(source: HTTPSource, token: String?, sendAcknowledgements: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.source = source
        self.token = token?.isEmpty == true ? nil : token
        self.now = now
        policy = try LinkPolicy(primary: source.primaryURL, downloadHosts: source.downloadHosts)
        if let stream = source.streamURL, let jobs = source.jobsURL {
            let a = try SecureURL.check(stream), b = try SecureURL.check(jobs)
            // The token only goes to one origin, so a stream anywhere else could never sign in.
            guard a.host?.lowercased() == b.host?.lowercased(), a.scheme == b.scheme, a.port == b.port else { throw RemoteError.streamOnAnotherHost }
        }
        sendsAcknowledgements = sendAcknowledgements && source.sendsAcknowledgements && source.jobsURL != nil
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil   // A cache would answer 304s itself and hide them.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: SafeRedirects(policy: policy), delegateQueue: nil)
        let stream = URLSessionConfiguration.ephemeral
        stream.urlCache = nil
        stream.httpCookieStorage = nil
        stream.httpShouldSetCookies = false
        stream.timeoutIntervalForRequest = Self.deadStream   // No bytes for this long: reconnect.
        stream.timeoutIntervalForResource = 60 * 60 * 24 * 365
        streamSession = URLSession(configuration: stream, delegate: SafeRedirects(policy: policy), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
        streamSession.invalidateAndCancel()
    }

    /// The contract asks for a comment every 30 s.
    static let deadStream: TimeInterval = 90

    func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let token, policy.isOrigin(url) { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private static func check(_ reply: URLResponse) throws -> HTTPURLResponse {
        guard let http = reply as? HTTPURLResponse else { throw RemoteError.unreadableReply("not HTTP") }
        switch http.statusCode {
        case 200...299, 304: return http
        case 401, 403: throw RemoteError.denied("HTTP \(http.statusCode)")
        case 429, 503:
            // Whole seconds only. Double() also takes "nan", which would trap in the sleep.
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 60
            throw RemoteError.tryLater(TimeInterval(min(max(wait, 1), 3600)))
        default: throw RemoteError.server(http.statusCode, "")
        }
    }

    public func reconcile(cursor: FeedCursor) async throws -> FeedPage {
        var next = cursor
        next.started = true
        guard let text = source.jobsURL else {
            return FeedPage(items: [], baseline: [], skippedCount: 0, cursor: next)   // A stream has no backlog to skip.
        }
        guard let url = try URL(string: text).flatMap({ try policy.check($0); return $0 }) else { throw RemoteError.insecureURL(text) }
        var r = request(url)
        if let etag = cursor.etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (bytes, reply) = try await session.bytes(for: r)
        let http = try Self.check(reply)
        if http.statusCode == 304 { return FeedPage(items: [], baseline: [], skippedCount: 0, cursor: next) }
        let body = try await Self.collect(bytes, limit: RemoteLimits.fileBytes)
        let (items, rejected) = try parse(body, etag: http.value(forHTTPHeaderField: "ETag"))
        // It goes back in every request, so a reply can't make that request huge.
        next.etag = http.value(forHTTPHeaderField: "ETag").flatMap { $0.utf8.count <= 1024 ? $0 : nil }
        // The first answer is what was already there.
        guard cursor.started else { return FeedPage(items: [], baseline: items, skippedCount: items.count, cursor: next, rejected: rejected) }
        return FeedPage(items: items, baseline: [], skippedCount: 0, cursor: next, rejected: rejected)
    }

    /// A jobs list, or a label itself when the URL simply serves one.
    private func parse(_ body: Data, etag: String?) throws -> (items: [RemoteItem], rejected: Int) {
        if let kind = FileKindSniffer.kind(of: body) {
            let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            let name = source.jobsURL.flatMap(URLComponents.init(string:))?.path.split(separator: "/").last.map(String.init) ?? "Remote label.\(kind)"
            return ([RemoteItem(id: "direct#\(etag ?? hash)", key: "inline:direct", name: name, size: body.count, modified: now(), inline: body)], 0)
        }
        guard body.count <= RemoteLimits.replyBytes, let list = try? JSONDecoder().decode(JobList.self, from: body) else {
            throw RemoteError.unreadableReply("it isn't a jobs list or a label")
        }
        let items = list.jobs.compactMap { $0.job?.item(now: now()) }
        return (items, list.jobs.count - items.count)
    }

    public func download(_ item: RemoteItem, to file: URL, limit: Int) async throws {
        if let inline = item.inline {
            try inline.write(to: file)
            return
        }
        guard !item.key.hasPrefix("inline:") else { throw RemoteError.gone }
        guard let url = URL(string: item.key) else { throw RemoteError.refusedAddress("an unreadable address") }
        try policy.check(url)
        let (bytes, reply) = try await session.bytes(for: request(url))
        _ = try Self.check(reply)
        try await Self.collect(bytes, limit: limit).write(to: file)
    }

    public func acknowledge(id: String, status: JobStatus, labels: Int?, at date: Date) async throws {
        guard let jobs = source.jobsURL, var parts = URLComponents(string: jobs) else { return }
        // Always derived from the configured URL, never taken from a message.
        parts.percentEncodedPath = parts.percentEncodedPath + (parts.percentEncodedPath.hasSuffix("/") ? "" : "/") + SigV4.encode(id) + "/ack"
        guard let url = parts.url else { return }
        var r = request(url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["status": status.rawValue, "at": ISO8601DateFormatter().string(from: date)]
        if let labels { body["labels"] = labels }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, reply) = try await session.data(for: r)
        if let http = reply as? HTTPURLResponse, http.statusCode == 404 || http.statusCode == 410 { return }   // It forgot the job: done.
        _ = try Self.check(reply)
    }

    public func follow(from lastEventID: String?, connected: @Sendable () async -> Void, event: @Sendable (StreamEvent) async -> Void) async throws {
        guard let text = source.streamURL else { return }
        guard let url = try URL(string: text).flatMap({ try policy.check($0); return $0 }) else { throw RemoteError.insecureURL(text) }
        var r = request(url)
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID { r.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        let (bytes, reply) = try await streamSession.bytes(for: r)
        let http = try Self.check(reply)
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw RemoteError.unreadableReply("it isn't an event stream")
        }
        await connected()
        var parser = SSEParser()
        for try await byte in bytes {
            guard let message = parser.feed(byte) else { continue }
            // Other event types are for someone else; their ids still count as read.
            var item: RemoteItem?
            if message.event == "label", let job = try? JSONDecoder().decode(RemoteJob.self, from: Data(message.data.utf8)) { item = job.item(now: now()) }
            await event(StreamEvent(item: item, id: message.id, rejected: message.event == "label" && item == nil))
        }
    }

    /// Answers Test Connection without printing, acknowledging or moving a cursor.
    public func test() async throws -> String {
        var notes: [String] = []
        if let text = source.jobsURL, let url = URL(string: text) {
            try policy.check(url)
            let (bytes, reply) = try await session.bytes(for: request(url))
            _ = try Self.check(reply)
            let count = try parse(try await Self.collect(bytes, limit: RemoteLimits.fileBytes), etag: nil).items.count
            notes.append("The URL lists \(count) job\(count == 1 ? "" : "s").")
        }
        if let text = source.streamURL, let url = URL(string: text) {
            try policy.check(url)
            var r = request(url)
            r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            // URLSession answers only once the first bytes of the body arrive, so a silent stream shows up as waiting.
            let session = streamSession
            let task = Task { () throws -> Bool in
                let (_, reply) = try await session.bytes(for: r)
                let http = try Self.check(reply)
                guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                    throw RemoteError.unreadableReply("it isn't an event stream")
                }
                return true
            }
            let timer = Task { try await Task.sleep(for: .seconds(5)); task.cancel() }
            defer { timer.cancel() }
            do {
                _ = try await task.value
                notes.append("The stream is open and sending.")
            } catch where task.isCancelled {
                notes.append("The stream sent nothing in 5 seconds. It needs to send a comment line as soon as Peel Good connects, and every 30 seconds after.")
            }
        }
        return notes.joined(separator: " ")
    }

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw RemoteError.tooLarge(limit: limit) }
        }
        return data
    }
}
