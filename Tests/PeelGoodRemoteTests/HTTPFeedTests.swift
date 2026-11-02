import CryptoKit
import Foundation
import Testing
@testable import PeelGoodRemote
import RemoteTestSupport

private final class Printer: @unchecked Sendable {
    private let lock = NSLock()
    private var _got: [Delivery] = []
    var got: [Delivery] { lock.withLock { _got } }
    var names: [String] { got.map(\.name) }
    func deliver(_ d: Delivery) -> DeliveryResult { lock.withLock { _got.append(d) }; return .sent(labels: d.copies ?? 1) }
}

private func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
private let pdf = FakeS3.pdf()

private func rig(acks: Bool = false, stream: Bool = false, jobs: Bool = true) async throws -> (FakeHTTP, Printer, RemoteInbox, HTTPFeed) {
    let server = FakeHTTP()
    try await server.start()
    let printer = Printer()
    let source = HTTPSource(jobsURL: jobs ? "\(server.base)/jobs" : nil, streamURL: stream ? "\(server.base)/events" : nil, sendsAcknowledgements: acks)
    let feed = try HTTPFeed(source: source, token: "TOKEN")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("http-\(UUID().uuidString)", isDirectory: true)
    let inbox = try RemoteInbox(feed: feed, directory: dir, deliver: { printer.deliver($0) })
    return (server, printer, inbox, feed)
}

private func until(_ what: @Sendable () async -> Bool) async throws {
    for _ in 0..<300 {
        if await what() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out")
}

// MARK: Polling

@Test func jobsPrintOnceWithTheirCopiesAndTheFirstAnswerIsLeftAlone() async throws {
    let (server, printer, inbox, _) = try await rig()
    let base = server.base
    server.handle { r in
        switch r.path {
        case "/jobs": .full(200, [:], json(["jobs": [["id": "old", "url": "\(base)/old.pdf"]]]))
        default: .full(200, [:], pdf)
        }
    }
    await inbox.check()
    #expect(printer.got.isEmpty)
    #expect(await inbox.status.skippedOnFirstCheck == 1)

    server.handle { r in
        switch r.path {
        case "/jobs": .full(200, [:], json(["jobs": [["id": "old", "url": "\(base)/old.pdf"], ["id": "new", "url": "\(base)/new.pdf", "name": "order 1459.pdf", "copies": 3]]]))
        default: .full(200, [:], pdf)
        }
    }
    await inbox.check()
    await inbox.check()
    #expect(printer.names == ["order 1459.pdf"])
    #expect(printer.got[0].copies == 3)
    #expect(server.requests.first?.headers["authorization"] == "Bearer TOKEN")
    server.stop()
}

@Test func thePrintThemButtonPrintsTheBacklog() async throws {
    let (server, printer, inbox, _) = try await rig()
    let base = server.base
    server.handle { r in r.path == "/jobs" ? .full(200, [:], json(["jobs": [["id": "a", "url": "\(base)/a.pdf"], ["id": "b", "url": "\(base)/b.pdf"]]])) : .full(200, [:], pdf) }
    await inbox.check()
    await inbox.printSkipped()
    #expect(printer.names.sorted() == ["a.pdf", "b.pdf"])
    #expect(await inbox.status.skippedOnFirstCheck == 0)
    server.stop()
}

@Test func usesEtagsAndHonoursRetryAfter() async throws {
    let (server, printer, inbox, _) = try await rig()
    server.handle { r in
        r.headers["if-none-match"] == "\"v1\"" ? .full(304, [:], Data()) : .full(200, ["ETag": "\"v1\""], json(["jobs": []]))
    }
    await inbox.check()
    await inbox.check()
    #expect(server.requests.last?.headers["if-none-match"] == "\"v1\"")
    #expect(await inbox.status.lastError == nil, "304 isn't an error")

    server.handle { _ in .full(429, ["Retry-After": "120"], Data()) }
    await inbox.check()
    #expect(await inbox.status.retryAfter == 120)
    #expect(await inbox.status.lastError == nil)
    #expect(printer.got.isEmpty)
    server.stop()
}

@Test func aURLThatSimplyServesALabelWorks() async throws {
    let (server, printer, inbox, _) = try await rig()
    let first = FakeS3.pdf(), second = first + Data([0x20])
    server.handle { _ in .full(200, [:], first) }
    await inbox.check()
    #expect(printer.got.isEmpty, "the first answer is what was there")
    server.handle { _ in .full(200, [:], second) }
    await inbox.check()
    await inbox.check()
    #expect(printer.names == ["jobs.pdf"], "a new file prints, the same one doesn't again")
    server.stop()
}

@Test func inlineFilesAndChecksums() async throws {
    let (server, printer, inbox, _) = try await rig()
    let base = server.base
    server.handle { _ in .full(200, [:], json(["jobs": []])) }
    await inbox.check()
    let good = SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined()
    server.handle { r in
        r.path == "/jobs" ? .full(200, [:], json(["jobs": [
            ["id": "inline", "content_base64": pdf.base64EncodedString(), "name": "inline.pdf"],
            ["id": "right", "url": "\(base)/f.pdf", "name": "right.pdf", "sha256": good],
            ["id": "wrong", "url": "\(base)/f.pdf", "name": "wrong.pdf", "sha256": String(repeating: "0", count: 64)],
            ["nonsense": true],
        ]])) : .full(200, [:], pdf)
    }
    await inbox.check()
    #expect(printer.names.sorted() == ["inline.pdf", "right.pdf"])
    #expect(await inbox.entries.first { $0.id == "wrong" }?.state == .failed)
    #expect(await inbox.status.lastError == nil, "one bad job doesn't lose the others")
    server.stop()
}

@Test func copiesOutOfRangeAreHeld() async throws {
    let (server, printer, inbox, _) = try await rig()
    let base = server.base
    server.handle { _ in .full(200, [:], json(["jobs": []])) }
    await inbox.check()
    server.handle { r in
        r.path == "/jobs" ? .full(200, [:], json(["jobs": [
            ["id": "many", "url": "\(base)/f.pdf", "copies": 5000],
            ["id": "none", "url": "\(base)/f.pdf", "copies": 0],
            ["id": "big", "url": "\(base)/f.pdf", "copies": RemoteLimits.labelsPerWindow + 1],
        ]])) : .full(200, [:], pdf)
    }
    await inbox.check()
    #expect(printer.got.isEmpty)
    let held = await inbox.entries.filter { $0.state == .held }.map(\.id).sorted()
    #expect(held == ["big", "many", "none"], "a sender can't spend the rate limit in one job")
    server.stop()
}

@Test func messagesCantAimThisMacElsewhere() async throws {
    let (server, printer, inbox, _) = try await rig()
    server.handle { _ in .full(200, [:], json(["jobs": []])) }
    await inbox.check()
    server.handle { r in
        .full(200, [:], json(["jobs": [
            ["id": "metadata", "url": "http://169.254.169.254/latest/meta-data/"],
            ["id": "elsewhere", "url": "https://evil.example/a.pdf"],
            ["id": "creds", "url": "https://user:pw@evil.example/a.pdf"],
            ["id": "file", "url": "file:///etc/passwd"],
        ]]))
    }
    await inbox.check()
    #expect(printer.got.isEmpty)
    let failed = await inbox.entries.filter { $0.state == .failed }.map(\.id).sorted()
    #expect(failed == ["creds", "elsewhere", "file", "metadata"])
    #expect(server.requests.allSatisfy { $0.path == "/jobs" })
    server.stop()
}

@Test func linkRules() throws {
    let policy = try LinkPolicy(primary: "https://labels.example.com/jobs", downloadHosts: ["files.example.net", " "])
    try policy.check(URL(string: "https://labels.example.com/a.pdf")!)
    #expect(throws: RemoteError.self) { try policy.check(URL(string: "http://labels.example.com/a.pdf")!) }
    #expect(throws: RemoteError.self) { try policy.check(URL(string: "https://other.example.com/a.pdf")!) }
    #expect(throws: RemoteError.self) { try policy.check(URL(string: "http://files.example.net/a.pdf")!) }
    #expect(throws: RemoteError.self) { try LinkPolicy(primary: "https://a.example", downloadHosts: ["127.0.0.1", "169.254.169.254", "localhost"]).check(URL(string: "https://169.254.169.254/x")!) }
    #expect(throws: RemoteError.self) { try LinkPolicy(primary: "https://a.example", downloadHosts: ["localhost"]).check(URL(string: "https://localhost/x")!) }
    #expect(throws: RemoteError.self) { try LinkPolicy(primary: "http://labels.example.com", downloadHosts: []) }
    for a: UInt32 in [0x0A000001, 0x7F000001, 0xA9FEA9FE, 0xAC100001, 0xC0A80101, 0x64400001] { #expect(LinkPolicy.isPrivateIPv4(a)) }
    #expect(!LinkPolicy.isPrivateIPv4(0x08080808))
    var v6 = [UInt8](repeating: 0, count: 16); v6[15] = 1
    #expect(LinkPolicy.isPrivateIPv6(v6))
    v6 = [UInt8](repeating: 0, count: 16); v6[10] = 0xFF; v6[11] = 0xFF; v6[12] = 169; v6[13] = 254; v6[14] = 169; v6[15] = 254
    #expect(LinkPolicy.isPrivateIPv6(v6), "IPv4 in IPv6 clothing")
}

@Test func theTokenOnlyGoesToTheConfiguredHost() throws {
    let feed = try HTTPFeed(source: HTTPSource(jobsURL: "https://labels.example.com/jobs", downloadHosts: ["files.example.net"]), token: "TOKEN")
    #expect(feed.request(URL(string: "https://labels.example.com/a.pdf")!).value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
    #expect(feed.request(URL(string: "https://files.example.net/a.pdf")!).value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func errorsDontRevealSignedLinks() {
    let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://s.example/a.pdf?X-Amz-Signature=SECRET"])
    #expect(!RemoteError.describe(error).contains("SECRET"))
}

// MARK: Acknowledgements

@Test func theServerHearsWhatBecameOfEachJob() async throws {
    let (server, printer, inbox, _) = try await rig(acks: true)
    let base = server.base
    server.handle { _ in .full(200, [:], json(["jobs": []])) }
    await inbox.check()
    server.handle { r in
        if r.method == "POST" { return .full(503, [:], Data()) }
        return r.path == "/jobs" ? .full(200, [:], json(["jobs": [["id": "order/1", "url": "\(base)/f.pdf", "copies": 2]]])) : .full(200, [:], pdf)
    }
    await inbox.check()
    #expect(printer.got.count == 1)
    server.handle { r in
        if r.method == "POST" { return .full(200, [:], Data()) }
        return r.path == "/jobs" ? .full(200, [:], json(["jobs": [["id": "order/1", "url": "\(base)/f.pdf", "copies": 2]]])) : .full(200, [:], pdf)
    }
    await inbox.check()
    #expect(printer.got.count == 1, "a retry of the message, never of the print")
    let posts = server.requests.filter { $0.method == "POST" }
    #expect(posts.last?.path == "/jobs/order%2F1/ack")
    let body = try #require(posts.last.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] })
    #expect(body["status"] as? String == "sent")
    #expect(body["labels"] as? Int == 2)
    #expect(Set(body.keys) == ["status", "labels", "at"], "no printer names or file paths")

    await inbox.check()
    #expect(server.requests.filter { $0.method == "POST" }.count == posts.count, "said once")
    server.stop()
}

@Test func noAcknowledgementsUnlessAskedFor() async throws {
    let (server, printer, inbox, _) = try await rig(acks: false)
    let base = server.base
    server.handle { _ in .full(200, [:], json(["jobs": []])) }
    await inbox.check()
    server.handle { r in r.path == "/jobs" ? .full(200, [:], json(["jobs": [["id": "a", "url": "\(base)/f.pdf"]]])) : .full(200, [:], pdf) }
    await inbox.check()
    #expect(printer.got.count == 1)
    #expect(server.requests.allSatisfy { $0.method == "GET" })
    server.stop()
}

// MARK: Streams

@Test func parsesTheEventStreamFormat() throws {
    func parse(_ text: String) throws -> ([SSEParser.Message], SSEParser) {
        var parser = SSEParser(), out: [SSEParser.Message] = []
        for byte in text.utf8 { if let m = try parser.feed(byte) { out.append(m) } }
        return (out, parser)
    }
    var (m, p) = try parse("\u{FEFF}event: label\nid: 7\ndata: one\ndata: two\n\n")
    #expect(m == [.init(event: "label", data: "one\ntwo", id: "7")])
    (m, p) = try parse(": keepalive\r\n\r\nevent:label\r\ndata:x\r\n\r\ndata: y\r\rretry: 5000\n")
    #expect(m == [.init(event: "label", data: "x", id: nil), .init(event: "message", data: "y", id: nil)])
    #expect(p.retry == 5)
    (m, p) = try parse("id: bad\u{0}id\ndata: z\n\nretry: nope\n")
    #expect(m[0].id == nil, "an id with NUL is ignored")
    #expect(p.retry == nil)
    (_, p) = try parse("retry: 1\nretry: 99999999\n")
    #expect(p.retry == 300, "clamped")
    (m, _) = try parse("event: label\n\n")
    #expect(m.isEmpty, "no data, no event")
    #expect(throws: RemoteError.self) { try parse("data: " + String(repeating: "x", count: RemoteLimits.eventBytes + 1)) }
}

@Test func backoffDoublesAndResets() {
    var b = Backoff()
    #expect([b.next(connectedFor: 0, jitter: 1), b.next(connectedFor: 0, jitter: 1), b.next(connectedFor: 0, jitter: 1)] == [1, 2, 4])
    for _ in 0..<12 { _ = b.next(connectedFor: 0, jitter: 1) }
    #expect(b.next(connectedFor: 0, jitter: 1) == 300)
    #expect(b.next(connectedFor: 61, jitter: 1) == 1)
}

@Test func aStreamPrintsAsEventsArriveAndResumesWhereItStopped() async throws {
    let (server, printer, inbox, _) = try await rig(stream: true, jobs: false)
    let base = server.base
    server.handle { r in r.path == "/events" ? .stream : .full(200, [:], pdf) }
    let first = Task { try await inbox.follow() }
    try await until { server.openStreams == 1 }
    try await until { await inbox.status.isStreaming }
    #expect(server.requests.first?.headers["accept"] == "text/event-stream")
    #expect(server.requests.first?.headers["authorization"] == "Bearer TOKEN")

    server.push(": keepalive\n\nevent: ping\nid: 1\ndata: {}\n\n")
    server.push("event: label\nid: 2\ndata: {\"id\":\"a\",\"url\":\"\(base)/a.pdf\",\"copies\":2}\n\n")
    try await until { printer.got.count == 1 }
    #expect(printer.got[0].copies == 2)
    server.push("event: label\nid: 3\ndata: {\"id\":\"a\",\"url\":\"\(base)/a.pdf\"}\n\n")   // sent twice
    server.push("event: label\nid: 4\ndata: not json\n\n")
    server.push("event: label\nid: 5\ndata: {\"id\":\"b\",\"content_base64\":\"\(pdf.base64EncodedString())\",\"name\":\"b.pdf\"}\n\n")
    try await until { printer.got.count == 2 }
    #expect(printer.names == ["a.pdf", "b.pdf"])

    try await Task.sleep(for: .milliseconds(100))
    server.closeStreams()
    _ = try? await first.value
    #expect(await inbox.status.isStreaming == false)

    // Reconnecting says where it got to.
    let second = Task { try await inbox.follow() }
    try await until { server.openStreams == 1 }
    let reconnect = try #require(server.requests.last { $0.path == "/events" })
    #expect(reconnect.headers["last-event-id"] == "5")
    second.cancel()
    server.stop()
}

@Test func aStreamAndAPollAgreeOnWhatsBeenPrinted() async throws {
    let (server, printer, inbox, _) = try await rig(stream: true)
    let base = server.base
    server.handle { r in
        switch r.path {
        case "/events": .stream
        case "/jobs": .full(200, [:], json(["jobs": [["id": "a", "url": "\(base)/a.pdf"]]]))
        default: .full(200, [:], pdf)
        }
    }
    // Connecting checks too: this first answer is the baseline.
    let follow = Task { try await inbox.follow() }
    try await until {
        let status = await inbox.status
        return status.isStreaming && status.lastCheck != nil
    }
    server.push("event: label\nid: 9\ndata: {\"id\":\"b\",\"url\":\"\(base)/b.pdf\"}\n\n")
    try await until { printer.got.count == 1 }
    server.handle { r in
        switch r.path {
        case "/events": .stream
        case "/jobs": .full(200, [:], json(["jobs": [["id": "a", "url": "\(base)/a.pdf"], ["id": "b", "url": "\(base)/b.pdf"]]]))
        default: .full(200, [:], pdf)
        }
    }
    await inbox.check()
    #expect(printer.names == ["b.pdf"], "the poll sees b and doesn't print it again")
    follow.cancel()
    server.stop()
}

@Test func aRefusedStreamNeedsAttention() async throws {
    let (server, _, inbox, _) = try await rig(stream: true, jobs: false)
    server.handle { _ in .full(401, [:], Data()) }
    await #expect(throws: RemoteError.self) { try await inbox.follow() }
    #expect(await inbox.status.streamNeedsAttention)
    server.handle { _ in .full(200, ["Content-Type": "text/html"], Data("<html>".utf8)) }
    await #expect(throws: RemoteError.self) { try await inbox.follow() }
    server.stop()
}

@Test func testConnectionDoesntWaitOnASilentStreamOrChangeAnything() async throws {
    let (server, printer, inbox, feed) = try await rig(acks: true, stream: true)
    let base = server.base
    server.handle { r in
        r.path == "/events" ? .stream : .full(200, [:], json(["jobs": [["id": "a", "url": "\(base)/a.pdf"]]]))
    }
    let answer = try await feed.test()
    #expect(answer.contains("lists 1 job"))
    #expect(answer.contains("stream is open"))
    #expect(printer.got.isEmpty)
    #expect(server.requests.allSatisfy { $0.method == "GET" })
    #expect(await inbox.entries.isEmpty)
    server.stop()
}
