import Foundation
import Testing
@testable import PeelGoodRemote
import RemoteTestSupport

/// A stand-in for the app's print step: records what arrives and answers from a script.
private final class Printer: @unchecked Sendable {
    private let lock = NSLock()
    private var _got: [Delivery] = []
    private var _answer: @Sendable (Delivery) -> DeliveryResult = { _ in .sent(labels: 1) }
    var got: [Delivery] { lock.withLock { _got } }
    var names: [String] { got.map(\.name) }
    func answer(_ a: @escaping @Sendable (Delivery) -> DeliveryResult) { lock.withLock { _answer = a } }
    func deliver(_ d: Delivery) -> DeliveryResult {
        guard d.fits(copies: d.copies ?? 1) else { return .overLimit }
        return lock.withLock { _got.append(d); return _answer(d) }
    }
}

private struct Rig {
    let s3 = FakeS3()
    let printer = Printer()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID().uuidString)", isDirectory: true)

    func inbox() throws -> RemoteInbox {
        let printer = printer
        let s3 = s3
        return try RemoteInbox(feed: try s3.feed(), directory: dir, now: { s3.clock }, deliver: { printer.deliver($0) })
    }

    func advance(_ s: TimeInterval = 60) { s3.clock = s3.clock.addingTimeInterval(s) }
}

private func rig() async throws -> Rig {
    let r = Rig()
    try await r.s3.start()
    return r
}

@Test func firstCheckLeavesWhatsThereAndNewFilesPrintOnce() async throws {
    let r = try await rig()
    r.s3.put("out/old.pdf", at: r.s3.clock.addingTimeInterval(-86_400))
    r.s3.put("out/just-before.pdf")   // inside the overlap, same second as the first listing
    r.s3.put("elsewhere/other.pdf")
    let inbox = try r.inbox()
    await inbox.check()
    #expect(r.printer.got.isEmpty)
    #expect(await inbox.status.skippedOnFirstCheck == 2)

    r.advance()
    r.s3.put("out/new.pdf")
    await inbox.check()
    #expect(r.printer.names == ["new.pdf"])

    r.advance()
    await inbox.check()
    #expect(r.printer.names == ["new.pdf"], "the overlap doesn't print it again")

    // A restart remembers both the printed one and the baseline.
    let again = try r.inbox()
    r.advance()
    await again.check()
    #expect(r.printer.names == ["new.pdf"])
    r.s3.stop()
}

@Test func rewritingAKeyPrintsAgain() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    r.s3.put("out/a.pdf", FakeS3.pdf())
    await inbox.check()
    r.advance()
    r.s3.put("out/a.pdf", FakeS3.pdf(padding: 10))
    await inbox.check()
    #expect(r.printer.names == ["a.pdf", "a.pdf"])
    r.s3.stop()
}

@Test func readsEveryPageOfAListing() async throws {
    let r = try await rig()
    r.s3.pageSize = 2
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    for i in 0..<5 { r.s3.put("out/\(i).pdf") }
    await inbox.check()
    #expect(Set(r.printer.names) == Set((0..<5).map { "\($0).pdf" }))
    r.s3.stop()
}

@Test func aFailedSendIsNeverRetriedAlone() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    r.s3.put("out/a.pdf")
    r.printer.answer { _ in .failed("out of ribbon") }
    await inbox.check()
    r.advance()
    await inbox.check()
    #expect(r.printer.got.count == 1, "it may have printed")
    #expect(await inbox.entries.first { $0.key == "out/a.pdf" }?.state == .failed)

    r.printer.answer { _ in .sent(labels: 1) }
    let id = try #require(await inbox.entries.first { $0.key == "out/a.pdf" }?.id)
    await inbox.printNow(id)
    #expect(r.printer.got.count == 2)
    #expect(r.printer.got.last?.forced == true)
    #expect(await inbox.entries.first { $0.id == id }?.state == .sent)
    r.s3.stop()
}

@Test func aPrinterThatCantTakeItHoldsTheQueueAndNothingIsLost() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    r.s3.put("out/a.pdf", at: r.s3.clock)
    r.s3.put("out/b.pdf", at: r.s3.clock.addingTimeInterval(1))
    r.printer.answer { _ in .notReady("out of labels") }
    await inbox.check()
    #expect(r.printer.names == ["a.pdf"], "b waits behind a")
    r.printer.answer { _ in .sent(labels: 1) }
    r.advance()
    await inbox.check()
    #expect(r.printer.names == ["a.pdf", "a.pdf", "b.pdf"], "in order, and nothing went out the first time")
    r.s3.stop()
}

@Test func stoppingMidPrintAsksAPerson() async throws {
    let r = try await rig()
    let first = try r.inbox()
    await first.check()
    r.advance()
    r.s3.put("out/a.pdf")
    r.printer.answer { _ in .notReady("") }
    await first.check()
    // As a crash during the send leaves it.
    let ledger = try Ledger(file: r.dir.appendingPathComponent("ledger.jsonl"))
    var e = try #require(ledger.all.first { $0.key == "out/a.pdf" })
    e.state = .printing
    try ledger.record(e)

    let count = r.printer.got.count
    r.printer.answer { _ in .sent(labels: 1) }
    let second = try r.inbox()
    #expect(await second.entries.first { $0.id == e.id }?.state == .unclear)
    r.advance()
    await second.check()
    #expect(r.printer.got.count == count, "no reprint by itself")
    await second.markPrinted(e.id)
    #expect(await second.entries.first { $0.id == e.id }?.state == .sent)
    r.s3.stop()
}

@Test func runawaySourcesAreHeldNotDropped() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    for i in 0..<(RemoteLimits.labelsPerWindow + 5) { r.s3.put("out/\(String(format: "%03d", i)).pdf", at: r.s3.clock.addingTimeInterval(Double(i))) }
    await inbox.check()
    #expect(r.printer.got.count == RemoteLimits.labelsPerWindow)
    let held = await inbox.entries.filter { $0.state == .held }
    #expect(held.count == 5)
    // A person can let one through.
    await inbox.printNow(held[0].id)
    #expect(r.printer.got.count == RemoteLimits.labelsPerWindow + 1)
    r.s3.stop()
}

@Test func checksFilesBeforeTheyGoNearAJob() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    r.s3.put("out/fake.pdf", Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8))
    r.s3.put("out/long.pdf", FakeS3.pdf(pages: RemoteLimits.labelsPerWindow + 1))
    r.s3.put("out/huge.pdf", FakeS3.pdf(padding: RemoteLimits.fileBytes + 1))
    r.s3.put("out/photo.txt", Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]))
    r.s3.put("out/.. ..:evil.pdf")
    await inbox.check()
    let states = await Dictionary(uniqueKeysWithValues: inbox.entries.filter { $0.state != .skipped }.map { ($0.key, $0.state) })
    #expect(states["out/fake.pdf"] == .failed)
    #expect(states["out/long.pdf"] == .held)
    #expect(states["out/huge.pdf"] == .failed)
    #expect(r.printer.names.contains("photo.txt.jpg"), "the bytes decide the type, not the name")
    let evil = try #require(r.printer.got.first { $0.name.contains("evil") })
    #expect(evil.file.standardizedFileURL.path.hasPrefix(r.dir.standardizedFileURL.path))
    #expect(!evil.name.contains(":"))
    r.s3.stop()
}

@Test func askingWaitsForAPerson() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    r.s3.put("out/a.pdf")
    r.printer.answer { $0.forced ? .sent(labels: 1) : .waiting }
    await inbox.check()
    let e = try #require(await inbox.entries.first { $0.key == "out/a.pdf" })
    #expect(e.state == .waiting)
    r.advance()
    await inbox.check()
    #expect(r.printer.got.count == 1)
    await inbox.printNow(e.id)
    #expect(await inbox.entries.first { $0.id == e.id }?.state == .sent)
    r.s3.stop()
}

@Test func overlappingChecksPrintEachItemOnce() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    for i in 0..<6 { r.s3.put("out/\(i).pdf", at: r.s3.clock.addingTimeInterval(Double(i))) }
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<6 { group.addTask { await inbox.check() } }
    }
    await inbox.check()
    #expect(r.printer.names.sorted() == (0..<6).map { "\($0).pdf" })
    r.s3.stop()
}

@Test func pausingStopsABatchAndResumingFinishesIt() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    for i in 0..<5 { r.s3.put("out/\(i).pdf", at: r.s3.clock.addingTimeInterval(Double(i))) }
    let stop = Task { await inbox.check() }
    stop.cancel()
    await stop.value
    #expect(r.printer.got.count < 5)
    await inbox.check()
    #expect(r.printer.names.sorted() == (0..<5).map { "\($0).pdf" }, "nothing lost, nothing twice")
    r.s3.stop()
}

@Test func refusedCredentialsAndRedirectsDontFollowThrough() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    r.s3.failWith = 403
    await inbox.check()
    #expect(await inbox.status.needsAttention)
    r.s3.failWith = nil
    r.s3.redirects = true
    await inbox.check()
    #expect(await inbox.status.lastError != nil)
    #expect(r.s3.requests.allSatisfy { !$0.contains("stolen") })
    r.s3.redirects = false
    await inbox.check()
    #expect(await inbox.status.lastError == nil, "it recovers by itself")
    r.s3.stop()
}

@Test func aTornLedgerLineIsIgnoredAndCompactionForgetsOnlyWhatsSafe() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)", isDirectory: true)
    let file = dir.appendingPathComponent("ledger.jsonl")
    let old = Date(timeIntervalSince1970: 1_000), recent = Date(timeIntervalSince1970: 2_000)
    let ledger = try Ledger(file: file)
    func entry(_ id: String, _ state: Ledger.State, _ modified: Date) -> Ledger.Entry {
        Ledger.Entry(id: id, key: id, name: id, size: 1, modified: modified, state: state, at: modified)
    }
    try ledger.record(entry("done-old", .sent, old))
    try ledger.record(entry("done-new", .sent, recent))
    try ledger.record(entry("unclear-old", .unclear, old))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"id\":\"torn".utf8))
    try handle.close()

    let reread = try Ledger(file: file)
    #expect(reread.all.map(\.id) == ["done-old", "done-new", "unclear-old"])
    try reread.compact(droppingDoneBefore: Date(timeIntervalSince1970: 1_500))
    #expect(try Ledger(file: file).all.map(\.id) == ["done-new", "unclear-old"], "what still needs someone stays")
}

@Test func theRemoteCodeNeverListens() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = root.appendingPathComponent("Sources/PeelGoodRemote")
    for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        let text = try String(contentsOf: file, encoding: .utf8)
        for word in ["NWListener", "Hummingbird", "bind(", "listen("] {
            #expect(!text.contains(word), "\(file.lastPathComponent) mentions \(word)")
        }
    }
}

@Test func aFarFutureDateCantLoseLaterLabels() async throws {
    let r = try await rig()
    let s3 = r.s3
    let inbox = try RemoteInbox(feed: S3Feed(client: try S3Client(source: s3.source, secret: "SECRET", now: { s3.clock.addingTimeInterval(-10 * 86_400) })),
                                directory: r.dir, now: { s3.clock }, deliver: { r.printer.deliver($0) })
    await inbox.check()
    #expect(await inbox.status.lastError != nil, "a date 10 days ahead of this Mac is refused")
    #expect(await inbox.status.skippedOnFirstCheck == 0, "and moves nothing forward")
    r.s3.stop()
}

@Test func longKeysDontShareASpoolFolder() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    let long = String(repeating: "k", count: 300)
    let first = FakeS3.pdf(), second = FakeS3.pdf(pages: 2)
    r.s3.put("out/\(long)-1.pdf", first)
    r.s3.put("out/\(long)-2.pdf", second)
    r.printer.answer { _ in .notReady("") }   // Both wait, downloaded, side by side.
    await inbox.check()
    #expect(r.printer.got.count == 1)
    r.printer.answer { _ in .sent(labels: 1) }
    r.advance()
    await inbox.check()
    #expect(r.printer.got.count == 3, "a, again, then b")
    #expect(Set(r.printer.got.map(\.file.path)).count == 2, "each key has its own file")
    r.s3.stop()
}

@Test func printAllAndDiscardAllClearABatch() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    for i in 0..<(RemoteLimits.labelsPerWindow + 4) { r.s3.put("out/\(String(format: "%03d", i)).pdf", at: r.s3.clock.addingTimeInterval(Double(i))) }
    await inbox.check()
    #expect(await inbox.entries.filter { $0.state == .held }.count == 4)
    r.s3.put("out/more.pdf", at: r.s3.clock.addingTimeInterval(100))
    await inbox.printAll([.held])
    #expect(await inbox.entries.filter { $0.state == .held }.isEmpty)
    #expect(r.printer.got.count == RemoteLimits.labelsPerWindow + 4)

    r.advance()
    await inbox.check()
    #expect(await inbox.entries.filter { $0.state == .held }.count == 1, "still over the limit")
    await inbox.discardAll([.held])
    #expect(await inbox.entries.filter { $0.state == .held }.isEmpty)
    r.s3.stop()
}

@Test func aStoppedPrinterIsVisibleAndClears() async throws {
    let r = try await rig()
    let inbox = try r.inbox()
    await inbox.check()
    r.advance()
    r.s3.put("out/a.pdf")
    r.printer.answer { _ in .notReady("it's out of labels") }
    await inbox.check()
    #expect(await inbox.status.printerProblem == "it's out of labels")
    r.printer.answer { _ in .sent(labels: 1) }
    r.advance()
    await inbox.check()
    #expect(await inbox.status.printerProblem == nil)
    r.s3.stop()
}
