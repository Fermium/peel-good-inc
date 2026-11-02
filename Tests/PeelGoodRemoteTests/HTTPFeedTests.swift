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
    func deliver(_ d: Delivery) -> DeliveryResult {
        guard d.fits(copies: d.copies ?? 1) else { return .overLimit }
        lock.withLock { _got.append(d) }
        return .sent(labels: d.copies ?? 1)
    }
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

@Test func copiesOutOfRangeAreInvalidAndOverTheLimitAreHeld() async throws {
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
    #expect(await inbox.status.rejectedJobs == 2)
    #expect(await inbox.entries.filter { $0.state == .held }.map(\.id) == ["big"], "a sender can't spend the rate limit in one job")
    await inbox.printNow("big")
    #expect(printer.got.count == 1, "a person can let it through")
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

@Test func idsUseTheDocumentedCharacters() async throws {
    #expect(RemoteJob.isValidID("Order-1459_v2.0"))
    #expect(RemoteJob.isValidID(String(repeating: "a", count: 256)))
    for bad in ["", String(repeating: "a", count: 257), "order 1", "order/1", "a#b", "é", "../x", "a\nb"] { #expect(!RemoteJob.isValidID(bad), "\(bad)") }

    let (server, printer, inbox, _) = try await rig(stream: true)
    let base = server.base
    server.handle { _ in .full(200, [:], json(["jobs": []])) }
    await inbox.check()
    #expect(await inbox.status.rejectedJobs == 0)
    server.handle { r in
        r.path == "/jobs" ? .full(200, [:], json(["jobs": [
            ["id": "good.1", "url": "\(base)/f.pdf"],
            ["id": "bad id", "url": "\(base)/f.pdf"],
            ["id": "no-file"],
        ]])) : .full(200, [:], pdf)
    }
    await inbox.check()
    #expect(printer.names == ["f.pdf"], "the valid one still prints")
    #expect(await inbox.status.rejectedJobs == 2, "and Settings hears about the others")
    server.stop()
}

// MARK: Acknowledgements

@Test func theServerHearsWhatBecameOfEachJob() async throws {
    let (server, printer, inbox, _) = try await rig(acks: true)
    let base = server.base
    server.handle { _ in .full(200, [:], json(["jobs": []])) }
    await inbox.check()
    server.handle { r in
        if r.method == "POST" { return .full(503, [:], Data()) }
        return r.path == "/jobs" ? .full(200, [:], json(["jobs": [["id": "order-1", "url": "\(base)/f.pdf", "copies": 2]]])) : .full(200, [:], pdf)
    }
    await inbox.check()
    #expect(printer.got.count == 1)
    server.handle { r in
        if r.method == "POST" { return .full(200, [:], Data()) }
        return r.path == "/jobs" ? .full(200, [:], json(["jobs": [["id": "order-1", "url": "\(base)/f.pdf", "copies": 2]]])) : .full(200, [:], pdf)
    }
    await inbox.check()
    #expect(printer.got.count == 1, "a retry of the message, never of the print")
    let posts = server.requests.filter { $0.method == "POST" }
    #expect(posts.last?.path == "/jobs/order-1/ack")
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

@Test func parsesTheEventStreamFormat() {
    func parse(_ text: String) -> [SSEParser.Message] {
        var parser = SSEParser()
        return text.utf8.compactMap { parser.feed($0) }
    }
    #expect(parse("\u{FEFF}event: label\nid: 7\ndata: one\ndata: two\n\n") == [.init(event: "label", data: "one\ntwo", id: "7")])
    #expect(parse(": keepalive\r\n\r\nevent:label\r\ndata:x\r\n\r\ndata: y\r\r") == [.init(event: "label", data: "x", id: nil), .init(event: "message", data: "y", id: nil)])
    #expect(parse("id: bad\u{0}id\ndata: z\n\n")[0].id == nil, "an id with NUL is ignored")
    #expect(parse("event: label\n\n").isEmpty, "no data, no event")
}

@Test func anOversizedEventDoesntJamTheStream() {
    var parser = SSEParser()
    let huge = "event: label\nid: 8\ndata: " + String(repeating: "x", count: RemoteLimits.eventBytes + 1) + "\ndata: more\n\nevent: label\nid: 9\ndata: {}\n\n"
    let out = huge.utf8.compactMap { parser.feed($0) }
    #expect(out == [.init(event: "label", data: "", id: "8"), .init(event: "label", data: "{}", id: "9")], "it counts as a bad job, its id moves the cursor on, and the next event arrives")
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

// MARK: Hostile headers

@Test func aBadRetryAfterCantBreakTheWait() async throws {
    let (server, _, inbox, _) = try await rig()
    for value in ["nan", "inf", "-5", "soon", "1e308"] {
        server.handle { _ in .full(429, ["Retry-After": value], Data()) }
        await inbox.check()
        let wait = try #require(await inbox.status.retryAfter)
        #expect(wait.isFinite && (1...3600).contains(wait), "\(value) gave \(wait)")
    }
    server.stop()
}

@Test func cookiesAreIgnored() async throws {
    let (server, _, inbox, _) = try await rig()
    server.handle { _ in .full(200, ["Set-Cookie": "tracker=1"], json(["jobs": []])) }
    await inbox.check()
    await inbox.check()
    #expect(server.requests.count == 2)
    #expect(server.requests.allSatisfy { $0.headers["cookie"] == nil })
    server.stop()
}

@Test func oversizedEtagsAndEventIDsArentKept() async throws {
    let (server, _, inbox, _) = try await rig()
    let huge = "\"" + String(repeating: "x", count: 5000) + "\""
    server.handle { _ in .full(200, ["ETag": huge], json(["jobs": []])) }
    await inbox.check()
    await inbox.check()
    #expect(server.requests.last?.headers["if-none-match"] == nil)
    server.stop()

    var parser = SSEParser(), out: [SSEParser.Message] = []
    for byte in ("id: " + String(repeating: "y", count: 2000) + "\ndata: z\n\n").utf8 { if let m = parser.feed(byte) { out.append(m) } }
    #expect(out.first?.id == nil)
}

// MARK: From the cross-check

@Test func anInlineJobSurvivesAStuckPrinterAndARestart() async throws {
    let server = FakeHTTP()
    try await server.start()
    let source = HTTPSource(jobsURL: "\(server.base)/jobs")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inline-\(UUID().uuidString)", isDirectory: true)
    let list: @Sendable ([String]) -> Data = { ids in json(["jobs": ids.map { ["id": $0, "content_base64": pdf.base64EncodedString(), "name": "\($0).pdf"] }]) }
    final class Answer: @unchecked Sendable { let lock = NSLock(); var ready = false; var got: [String] = [] }
    let answer = Answer()
    let deliver: @Sendable (Delivery) async -> DeliveryResult = { d in
        answer.lock.withLock {
            answer.got.append(d.name)
            return answer.ready ? .sent(labels: 1) : .notReady("out of labels")
        }
    }
    let first = try RemoteInbox(feed: try HTTPFeed(source: source, token: nil), directory: dir, deliver: deliver)
    server.handle { _ in .full(200, [:], list([])) }
    await first.check()
    server.handle { _ in .full(200, [:], list(["a", "b"])) }
    await first.check()
    // The URL moves on, and the app restarts. The bytes only ever came in that one reply.
    server.handle { _ in .full(200, [:], list([])) }
    answer.lock.withLock { answer.ready = true }
    let second = try RemoteInbox(feed: try HTTPFeed(source: source, token: nil), directory: dir, deliver: deliver)
    await second.check()
    #expect(answer.lock.withLock { answer.got.filter { $0 == "b.pdf" }.count } == 1)
    #expect(await second.entries.allSatisfy { $0.state == .sent })
    server.stop()
}

@Test func aRetryAfterDoesntOutliveTheNextReply() async throws {
    let (server, _, inbox, _) = try await rig()
    server.handle { _ in .full(429, ["Retry-After": "120"], Data()) }
    await inbox.check()
    #expect(await inbox.status.retryAfter == 120)
    server.handle { _ in .full(401, [:], Data()) }
    await inbox.check()
    #expect(await inbox.status.retryAfter == nil)
    #expect(await inbox.status.needsAttention)
    server.handle { _ in .full(429, ["Retry-After": "5"], Data()) }
    await inbox.check()
    #expect(await inbox.status.lastError == nil, "being asked to wait isn't an error")
    server.stop()
}

@Test func aStreamHonoursRetryAfter() async throws {
    let (server, _, inbox, _) = try await rig(stream: true, jobs: false)
    server.handle { _ in .full(503, ["Retry-After": "90"], Data()) }
    let wait = try await inbox.follow()
    #expect(wait == 90)
    #expect(await inbox.status.streamError == nil)
    server.stop()
}

@Test func aStreamOnAnotherHostIsExplained() {
    for stream in ["https://b.example/events", "https://a.example:8443/events"] {
        #expect(throws: RemoteError.streamOnAnotherHost) { try HTTPFeed(source: HTTPSource(jobsURL: "https://a.example/jobs", streamURL: stream), token: nil) }
    }
}
