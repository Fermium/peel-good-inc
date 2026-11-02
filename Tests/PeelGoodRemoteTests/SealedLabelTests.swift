import CryptoKit
import Foundation
import Testing
@testable import PeelGoodRemote
import RemoteTestSupport

/// The sender's side, as docs/REMOTE-SOURCES.md describes it.
private func seal(_ file: Data, name: String? = nil, copies: Int? = nil, to mac: String, from sender: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
    var details: [String: Any] = [:]
    if let name { details["name"] = name }
    if let copies { details["copies"] = copies }
    let json = try JSONSerialization.data(withJSONObject: details)
    let length = withUnsafeBytes(of: UInt32(json.count).bigEndian) { Data($0) }
    var s = try HPKE.Sender(recipientKey: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: mac)!),
                            ciphersuite: SealedLabel.suite, info: SealedLabel.info, authenticatedBy: sender)
    return SealedLabel.magic + s.encapsulatedKey + (try s.seal(length + json + file, authenticating: SealedLabel.magic))
}

private final class Printer: @unchecked Sendable {
    private let lock = NSLock()
    private var _got: [Delivery] = []
    var got: [Delivery] { lock.withLock { _got } }
    func deliver(_ d: Delivery) -> DeliveryResult {
        lock.withLock { _got.append(d) }
        return .sent(labels: d.copies ?? 1)
    }
}

private struct Rig {
    let s3 = FakeS3()
    let printer = Printer()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-\(UUID().uuidString)", isDirectory: true)
    let sender = Curve25519.KeyAgreement.PrivateKey()
    let mac = SealedLabel.newKeys()

    var keys: SealedLabel.Keys { get throws { try SealedLabel.Keys(privateKey: mac.privateKey, sender: sender.publicKey.rawRepresentation.base64EncodedString()) } }

    func inbox() throws -> RemoteInbox {
        let printer = printer, s3 = s3
        return try RemoteInbox(feed: try s3.feed(), directory: dir, keys: try keys, now: { s3.clock }, deliver: { printer.deliver($0) })
    }

    func started() async throws -> RemoteInbox {
        try await s3.start()
        let inbox = try inbox()
        await inbox.check()
        s3.clock = s3.clock.addingTimeInterval(60)
        return inbox
    }

    func sealed(name: String? = nil, copies: Int? = nil) throws -> Data {
        try seal(FakeS3.pdf(), name: name, copies: copies, to: mac.publicKey, from: sender)
    }
}

private func failure(_ inbox: RemoteInbox) async -> String? {
    await inbox.entries.first { $0.state == .failed }?.detail
}

@Test func aSealedLabelPrintsUnderTheNameAndCopiesInsideIt() async throws {
    let r = Rig()
    let inbox = try await r.started()
    r.s3.put("out/9f2c1e", try r.sealed(name: "order 1459.pdf", copies: 2))
    await inbox.check()
    #expect(r.printer.got.map(\.name) == ["order 1459.pdf"])
    #expect(r.printer.got.first?.copies == 2)
}

@Test func aPlainFileOnAnEncryptedSourceNeverPrints() async throws {
    let r = Rig()
    let inbox = try await r.started()
    r.s3.put("out/plain.pdf")
    await inbox.check()
    #expect(r.printer.got.isEmpty)
    #expect(await failure(inbox) == RemoteError.notEncrypted.description)

    // Print Again goes back through the same check.
    let id = try #require(await inbox.entries.first { $0.state == .failed }?.id)
    await inbox.printNow(id)
    #expect(r.printer.got.isEmpty)
}

@Test func onlyThePairedSenderAndThisMacWork() async throws {
    let r = Rig()
    let inbox = try await r.started()
    r.s3.put("out/stranger", try seal(FakeS3.pdf(), to: r.mac.publicKey, from: Curve25519.KeyAgreement.PrivateKey()))
    r.s3.put("out/other-mac", try seal(FakeS3.pdf(), to: SealedLabel.newKeys().publicKey, from: r.sender))
    await inbox.check()
    #expect(r.printer.got.isEmpty)
    #expect(await inbox.entries.filter { $0.detail == RemoteError.cantDecrypt.description }.count == 2)
}

@Test func anyChangedByteFails() async throws {
    let r = Rig()
    let inbox = try await r.started()
    let good = try r.sealed()
    for (i, at) in [SealedLabel.magic.count, SealedLabel.magic.count + 40, good.count - 1].enumerated() {
        var bad = good
        bad[at] ^= 1
        r.s3.put("out/tampered-\(i)", bad)
    }
    r.s3.put("out/cut", good.prefix(SealedLabel.magic.count + 10))
    await inbox.check()
    #expect(r.printer.got.isEmpty)
    #expect(await inbox.entries.filter { $0.detail == RemoteError.cantDecrypt.description }.count == 4)
}

@Test func theSourceCantChangeNameOrCopies() async throws {
    let server = FakeHTTP()
    try await server.start()
    defer { server.stop() }
    let r = Rig()
    let blob = try r.sealed(name: "real.pdf", copies: 1)
    let base = server.base
    server.handle { _ in .full(200, [:], Data(#"{"jobs": []}"#.utf8)) }
    let feed = try HTTPFeed(source: HTTPSource(jobsURL: "\(base)/jobs"), token: nil)
    let printer = r.printer
    let inbox = try RemoteInbox(feed: feed, directory: r.dir, keys: try r.keys, deliver: { printer.deliver($0) })
    await inbox.check()
    let list = Data(#"{"jobs": [{"id": "job-1", "url": "\#(base)/blob", "name": "evil.pdf", "copies": 100}]}"#.utf8)
    server.handle { request in request.path == "/blob" ? .full(200, [:], blob) : .full(200, [:], list) }
    await inbox.check()
    #expect(printer.got.map(\.name) == ["real.pdf"])
    #expect(printer.got.first?.copies == 1)
}

@Test func aReplayedLabelDoesntPrintAgainEvenAfterARestart() async throws {
    let r = Rig()
    let first = try await r.started()
    let blob = try r.sealed(name: "order.pdf")
    r.s3.put("out/one", blob)
    await first.check()
    #expect(r.printer.got.count == 1)

    r.s3.clock = r.s3.clock.addingTimeInterval(60)
    r.s3.put("out/same-again", blob)
    await first.check()
    #expect(r.printer.got.count == 1)
    #expect(await failure(first) == RemoteError.replayedLabel.description)

    let reopened = try r.inbox()
    r.s3.clock = r.s3.clock.addingTimeInterval(60)
    r.s3.put("out/and-again", blob)
    await reopened.check()
    #expect(r.printer.got.count == 1)
}

@Test func aFailedJobCanOpenItsOwnSealAgain() async throws {
    let r = Rig()
    let inbox = try await r.started()
    // Opens fine, then fails as not a label: Print Again has to get past the seal it already used.
    r.s3.put("out/not-a-label", try seal(Data("hello".utf8), to: r.mac.publicKey, from: r.sender))
    await inbox.check()
    #expect(await failure(inbox) == "It isn't a PDF, PNG or JPEG")
    let id = try #require(await inbox.entries.first { $0.state == .failed }?.id)
    await inbox.printNow(id)
    #expect(await failure(inbox) == "It isn't a PDF, PNG or JPEG")
}

@Test func outOfRangeCopiesInsideFail() async throws {
    let r = Rig()
    let inbox = try await r.started()
    r.s3.put("out/many", try r.sealed(copies: 101))
    await inbox.check()
    #expect(r.printer.got.isEmpty)
    #expect(await failure(inbox) == RemoteError.invalidEncryptedJob.description)
}

@Test func aURLCanServeASealedLabelDirectly() async throws {
    let server = FakeHTTP()
    try await server.start()
    defer { server.stop() }
    let r = Rig()
    let printer = r.printer
    let inbox = try RemoteInbox(feed: try HTTPFeed(source: HTTPSource(jobsURL: "\(server.base)/label"), token: nil), directory: r.dir, keys: try r.keys, deliver: { printer.deliver($0) })
    server.handle { _ in .full(200, ["ETag": "\"zero\""], FakeS3.pdf()) }
    await inbox.check()
    let blob = try r.sealed(name: "direct.pdf")
    server.handle { _ in .full(200, ["ETag": "\"one\""], blob) }
    await inbox.check()
    #expect(printer.got.map(\.name) == ["direct.pdf"])
}

@Test func aStreamEventCanCarryASealedLabel() async throws {
    let server = FakeHTTP()
    try await server.start()
    defer { server.stop() }
    let r = Rig()
    let printer = r.printer, blob = try r.sealed(name: "streamed.pdf", copies: 3)
    server.handle { request in request.path == "/events" ? .stream : .full(200, [:], blob) }
    let inbox = try RemoteInbox(feed: try HTTPFeed(source: HTTPSource(streamURL: "\(server.base)/events"), token: nil), directory: r.dir, keys: try r.keys, deliver: { printer.deliver($0) })
    let follow = Task { try await inbox.follow() }
    defer { follow.cancel() }
    for _ in 0..<300 where server.openStreams == 0 { try await Task.sleep(for: .milliseconds(20)) }
    server.push("event: label\nid: 1\ndata: {\"id\": \"s1\", \"url\": \"\(server.base)/blob\", \"name\": \"evil.pdf\", \"copies\": 100}\n\n")
    for _ in 0..<300 where printer.got.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(printer.got.map(\.name) == ["streamed.pdf"])
    #expect(printer.got.first?.copies == 3)
}

/// Everything above seals using CryptoKit. This seals using the documented format, written separately in Node.
@Test func theExampleScriptInteroperates() async throws {
    let node = "/opt/homebrew/bin/node"
    guard FileManager.default.isExecutableFile(atPath: node) else { return }
    let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "examples/seal/seal.mjs").path
    func run(_ args: [String], env: [String: String] = [:]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(filePath: node)
        p.arguments = [script] + args
        p.environment = env
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    let lines = try run(["keygen"]).split(separator: "\n").map { String($0.split(separator: " ").last!) }
    let mac = SealedLabel.newKeys()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let input = dir.appendingPathComponent("in.pdf"), output = dir.appendingPathComponent("out")
    let label = FakeS3.pdf()
    try label.write(to: input)
    _ = try run(["seal", mac.publicKey, input.path, output.path, "--name", "from node.pdf", "--copies", "3"], env: ["SENDER_KEY": lines[1]])
    let opened = try SealedLabel.open(try Data(contentsOf: output), keys: try SealedLabel.Keys(privateKey: mac.privateKey, sender: lines[0]))
    #expect(opened.file == label)
    #expect(opened.name == "from node.pdf")
    #expect(opened.copies == 3)
}
