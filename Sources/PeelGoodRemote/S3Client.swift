import Foundation

public struct S3Object: Equatable, Sendable {
    public var key: String
    public var etag: String
    public var size: Int
    public var modified: Date
}

/// The little of the S3 API a read-only watcher needs: ListObjectsV2 and GET.
public final class S3Client: Sendable {
    private let source: S3Source
    private let signer: SigV4
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(source: S3Source, secret: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
        _ = try SecureURL.check(source.endpoint)
        self.source = source
        signer = SigV4(accessKey: source.accessKey, secretKey: secret, region: source.region)
        self.now = now
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// Every object under the prefix, with the server's clock at the first page.
    public func listAll() async throws -> (objects: [S3Object], serverDate: Date) {
        var objects: [S3Object] = [], token: String?, serverDate: Date?
        repeat {
            var query = ["list-type": "2", "max-keys": "1000", "prefix": source.prefix]
            if let token { query["continuation-token"] = token }
            let (data, reply) = try await send(key: nil, query: query)
            serverDate = serverDate ?? reply.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate)
            guard data.count <= RemoteLimits.replyBytes else { throw RemoteError.unreadableReply("listing too large") }
            let page = try ListingParser.parse(data)
            objects += page.objects
            token = page.nextToken
        } while token != nil
        // Dates set how far along this source is, for good. One far ahead would lose every label until then.
        guard let serverDate, serverDate < now().addingTimeInterval(86_400) else { throw RemoteError.unreadableReply("its date is missing or far ahead of this Mac") }
        // Folder markers aren't files.
        return (objects.filter { !$0.key.hasSuffix("/") }, serverDate)
    }

    /// Checks access: lists one key and reads the start of it. True when there was one to read.
    public func probe() async throws -> Bool {
        let (data, _) = try await send(key: nil, query: ["list-type": "2", "max-keys": "1", "prefix": source.prefix])
        guard let first = try ListingParser.parse(data).objects.first(where: { !$0.key.hasSuffix("/") }) else { return false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await download(key: first.key, to: file, limit: 1024)
        } catch RemoteError.tooLarge {
            // It read that far, which is all this asks.
        }
        return true
    }

    /// Downloads an object to `file`, stopping at `limit` bytes.
    public func download(key: String, to file: URL, limit: Int) async throws {
        let (request, _) = try makeRequest(key: key, query: [:])
        let (bytes, reply) = try await session.bytes(for: request)
        try Self.check(reply as? HTTPURLResponse, body: nil)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var count = 0, buffer = Data(capacity: 64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            count += 1
            if count > limit { throw RemoteError.tooLarge(limit: limit) }
            if buffer.count == 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
    }

    private func send(key: String?, query: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let (request, _) = try makeRequest(key: key, query: query)
        let (data, reply) = try await session.data(for: request)
        try Self.check(reply as? HTTPURLResponse, body: data)
        return (data, reply as! HTTPURLResponse)
    }

    private func makeRequest(key: String?, query: [String: String]) throws -> (URLRequest, URL) {
        var parts = try SecureURL.check(source.endpoint)
        var host = parts.host ?? ""
        var path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        if source.pathStyle {
            path += "/\(source.bucket)"
        } else {
            host = "\(source.bucket).\(host)"
            parts.host = host
        }
        if let key { path += "/\(key)" }
        if path.isEmpty { path = "/" }
        parts.percentEncodedPath = SigV4.encodePath(path)
        parts.percentEncodedQuery = query.isEmpty ? nil : SigV4.encodeQuery(query)
        guard let url = parts.url else { throw RemoteError.insecureURL(source.endpoint) }
        let hostHeader = parts.port.map { "\(host):\($0)" } ?? host
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in signer.headers(method: "GET", host: hostHeader, path: path, query: query, date: now()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return (request, url)
    }

    private static func check(_ reply: HTTPURLResponse?, body: Data?) throws {
        guard let reply else { throw RemoteError.unreadableReply("not HTTP") }
        guard !(200...299).contains(reply.statusCode) else { return }
        let reason = body.flatMap(ListingParser.errorCode) ?? ""
        if reply.statusCode == 401 || reply.statusCode == 403 { throw RemoteError.denied(reason.isEmpty ? "access denied" : reason) }
        throw RemoteError.server(reply.statusCode, reason)
    }

    static var httpFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }

    static func httpDate(_ text: String) -> Date? { httpFormatter.date(from: text) }
}

/// A store's redirect could carry signed headers somewhere else: treat it as an answer instead.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// ListObjectsV2 XML. XMLParser doesn't resolve external entities unless asked.
final class ListingParser: NSObject, XMLParserDelegate {
    private(set) var objects: [S3Object] = []
    private(set) var nextToken: String?
    private var truncated = false
    private var text = ""
    private var current: [String: String]?
    private var code: String?

    static func parse(_ data: Data) throws -> (objects: [S3Object], nextToken: String?) {
        let parser = XMLParser(data: data), listing = ListingParser()
        parser.delegate = listing
        guard parser.parse() else { throw RemoteError.unreadableReply("listing") }
        return (listing.objects, listing.truncated ? listing.nextToken : nil)
    }

    /// The `<Code>` of an S3 error reply.
    static func errorCode(_ data: Data) -> String? {
        let parser = XMLParser(data: data), listing = ListingParser()
        parser.delegate = listing
        parser.parse()
        return listing.code
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "Contents" { current = [:] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if current != nil, name != "Contents" {
            current?[name] = text
        } else if name == "Contents", let c = current {
            current = nil
            if let key = c["Key"], let etag = c["ETag"], let size = c["Size"].flatMap(Int.init), let modified = c["LastModified"].flatMap(Self.date) {
                objects.append(S3Object(key: key, etag: etag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), size: size, modified: modified))
            }
        } else if name == "IsTruncated" {
            truncated = text == "true"
        } else if name == "NextContinuationToken" {
            nextToken = text
        } else if name == "Code" {
            code = text
        }
    }

    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
