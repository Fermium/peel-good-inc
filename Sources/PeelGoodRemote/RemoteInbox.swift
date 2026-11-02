import CoreGraphics
import CryptoKit
import Foundation
import PeelGoodShared

/// What the inbox hands the app to print, and what the app answers.
public struct Delivery: Sendable {
    public var id: String
    public var name: String
    public var file: URL
    /// What the sender asked for; nil leaves it to the rules.
    public var copies: Int?
    /// A person pressed Print: skip Ask and print.
    public var forced: Bool

    public init(id: String, name: String, file: URL, copies: Int?, forced: Bool) {
        self.id = id
        self.name = name
        self.file = file
        self.copies = copies
        self.forced = forced
    }
}

public enum DeliveryResult: Equatable, Sendable {
    case sent(labels: Int)
    /// The rules said Ask.
    case waiting
    case cancelled
    /// Sent or attempted, and it failed. Never retried without a person: it may have printed.
    case failed(String)
    /// The printer can't take it right now and nothing went out: stops here, resumes on the next check.
    case notReady(String)
}

/// One source's labels from discovery to printer. The ledger is the truth, so a restart resumes where
/// this stopped. It prints nothing twice by itself: whatever might have printed waits for a person.
public actor RemoteInbox {
    public struct Status: Equatable, Sendable {
        public var lastCheck: Date?
        public var lastError: String?
        public var needsAttention = false
        public var skippedOnFirstCheck = 0
        public var shouldPause = false
        /// The server asked to wait this long before the next check.
        public var retryAfter: TimeInterval?
        public var isStreaming = false
        public var streamError: String?
        public var streamNeedsAttention = false
        public init() {}
    }

    private let feed: any RemoteFeed
    private let ledger: Ledger
    private let spool: URL
    private let cursorFile: URL
    private let deliver: @Sendable (Delivery) async -> DeliveryResult
    private let now: @Sendable () -> Date
    private var cursor: FeedCursor
    /// Checks and streams overlap, and an actor can be re-entered at each await: only one pass at a time
    /// picks items, or two would both print the same one.
    private var isDraining = false
    private var drainAgain = false
    public private(set) var status = Status()

    /// `directory` is this source's own folder. Starting up turns an interrupted print into `unclear`.
    public init(feed: any RemoteFeed, directory: URL, now: @escaping @Sendable () -> Date = { Date() },
                deliver: @escaping @Sendable (Delivery) async -> DeliveryResult) throws {
        self.feed = feed
        self.deliver = deliver
        self.now = now
        spool = directory.appendingPathComponent("spool", isDirectory: true)
        cursorFile = directory.appendingPathComponent("cursor.json")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        ledger = try Ledger(file: directory.appendingPathComponent("ledger.jsonl"))
        cursor = (try? Data(contentsOf: cursorFile)).flatMap { try? JSONDecoder().decode(FeedCursor.self, from: $0) } ?? FeedCursor()
        for var e in ledger.all where e.state == .printing {
            e.state = .unclear
            e.at = now()
            e.detail = "Peel Good stopped while this was printing. It may have printed."
            try ledger.record(e)
        }
        if let watermark = cursor.watermark { try ledger.compact(droppingDoneBefore: watermark) }
    }

    public var entries: [Ledger.Entry] { ledger.all }

    /// Looks for new items and works through everything that's ready.
    public func check() async {
        do {
            let page = try await feed.reconcile(cursor: cursor)
            for item in page.baseline where ledger[item.id] == nil { try ledger.record(entry(item, .skipped)) }
            for item in page.items where ledger[item.id] == nil {
                try ledger.record(entry(item, .new))
            }
            // A stream may have moved on during this check.
            var next = page.cursor
            next.lastEventID = cursor.lastEventID
            cursor = next
            try JSONEncoder().encode(cursor).write(to: cursorFile, options: .atomic)
            if page.skippedCount > 0 { status.skippedOnFirstCheck = page.skippedCount }
            status.lastCheck = now()
            status.lastError = nil
            status.needsAttention = false
            status.retryAfter = nil
            await drain(page.items)
            await sendAcknowledgements()
        } catch RemoteError.tryLater(let seconds) {
            status.retryAfter = seconds
        } catch {
            // Pausing or waking cancels a check in progress, which isn't a failure.
            guard !Task.isCancelled else { return }
            status.lastError = RemoteError.describe(error)
            status.needsAttention = (error as? RemoteError)?.needsAttention ?? false
        }
    }

    /// Follows the feed's stream until it ends, and checks at each connect for anything sent while away.
    /// Returns how long the server asked to wait before reconnecting.
    public func follow() async throws -> TimeInterval? {
        defer { status.isStreaming = false }
        do {
            let retry = try await feed.follow(from: cursor.lastEventID, connected: { [self] in
                await streamConnected()
            }, event: { [self] event in
                await receive(event)
            })
            return retry
        } catch {
            guard !Task.isCancelled else { return nil }
            status.streamError = RemoteError.describe(error)
            status.streamNeedsAttention = (error as? RemoteError)?.needsAttention ?? false
            throw error
        }
    }

    private func streamConnected() async {
        status.isStreaming = true
        status.streamError = nil
        status.streamNeedsAttention = false
        await check()
    }

    func receive(_ event: StreamEvent) async {
        do {
            if let item = event.item, ledger[item.id] == nil { try ledger.record(entry(item, .new)) }
            // Only once it's in the ledger: reconnecting from here can't lose it.
            if let id = event.id {
                cursor.lastEventID = id
                try JSONEncoder().encode(cursor).write(to: cursorFile, options: .atomic)
            }
            await drain(event.item.map { [$0] } ?? [])
            await sendAcknowledgements()
        } catch {
            status.lastError = RemoteError.describe(error)
        }
    }

    /// Prints what the first check left alone, for a source you've just added and do want the backlog of.
    public func printSkipped() async {
        for var e in ledger.all where e.state == .skipped {
            e.state = .new
            e.at = now()
            try? ledger.record(e)
        }
        status.skippedOnFirstCheck = 0
        await drain([])
    }

    private func sendAcknowledgements() async {
        guard feed.sendsAcknowledgements else { return }
        for var e in ledger.all where e.ackPending == true {
            guard let job = Self.jobStatus(e.state) else { continue }
            do {
                try await feed.acknowledge(id: e.id, status: job, labels: e.labels, at: e.at)
                e.ackPending = false
                try ledger.record(e)
            } catch {
                // Still pending: the next check tries again. It never reprints.
                return
            }
        }
    }

    private static func jobStatus(_ state: Ledger.State) -> JobStatus? {
        switch state {
        case .sent: .sent
        case .cancelled: .cancelled
        case .failed: .failed
        default: nil
        }
    }

    /// Print, Print Again or Mark as Printed from a person, for what's waiting, held, failed or unclear.
    public func printNow(_ id: String) async {
        guard var e = ledger[id], !e.isDone, e.state != .printing else { return }
        if e.state == .failed && !FileManager.default.fileExists(atPath: spoolFile(e).path) {
            e.state = .new
            try? ledger.record(e)
            await drain([])
            return
        }
        await send(e, forced: true)
    }

    public func markPrinted(_ id: String) async {
        update(id, .sent, detail: "Marked as printed")
        removeSpool(id)
        await sendAcknowledgements()
    }

    public func discard(_ id: String) async {
        update(id, .cancelled, detail: nil)
        removeSpool(id)
        await sendAcknowledgements()
    }

    // MARK: Working through items

    private func drain(_ fresh: [RemoteItem]) async {
        guard !isDraining else {
            drainAgain = true
            return
        }
        isDraining = true
        defer { isDraining = false }
        repeat {
            drainAgain = false
            await drainOnce(fresh)
        } while drainAgain && !Task.isCancelled
    }

    private func drainOnce(_ fresh: [RemoteItem]) async {
        for var e in ledger.all where [.new, .downloading, .ready].contains(e.state) {
            // Pausing cancels the runner: the rest wait, and carry on when it resumes.
            if Task.isCancelled { return }
            if e.state != .ready {
                guard let downloaded = await download(e, fresh: fresh) else { continue }
                e = downloaded
            }
            guard let pages = checked(e) else { continue }
            let copies = e.copies ?? 1
            if !RemoteLimits.copies.contains(copies) {
                update(e.id, .held, detail: "It asks for \(copies) copies")
                continue
            }
            if pages > RemoteLimits.pagesPerDocument {
                update(e.id, .held, detail: "It has \(pages) pages")
                continue
            }
            if labelsInWindow() + pages * copies > RemoteLimits.labelsPerWindow {
                update(e.id, .held, detail: "This source sent more than \(RemoteLimits.labelsPerWindow) labels in \(Int(RemoteLimits.window / 60)) minutes")
                continue
            }
            if await !send(e, forced: false) { break }
        }
        status.shouldPause = ledger.all.filter { $0.state == .held }.count >= RemoteLimits.heldBeforePausing
    }

    /// False when the printer can't take it now, so the rest wait as well.
    @discardableResult
    private func send(_ entry: Ledger.Entry, forced: Bool) async -> Bool {
        let file = spoolFile(entry)
        update(entry.id, .printing, detail: nil)
        switch await deliver(Delivery(id: entry.id, name: entry.name, file: file, copies: entry.copies, forced: forced)) {
        case .sent(let labels):
            var e = ledger[entry.id] ?? entry
            e.state = .sent
            e.labels = labels
            e.at = now()
            e.detail = nil
            e.ackPending = feed.sendsAcknowledgements ? true : nil
            try? ledger.record(e)
            removeSpool(entry.id)
        case .waiting:
            update(entry.id, .waiting, detail: nil)
        case .cancelled:
            update(entry.id, .cancelled, detail: nil)
            removeSpool(entry.id)
        case .failed(let reason):
            update(entry.id, .failed, detail: reason)
        case .notReady(let reason):
            update(entry.id, .ready, detail: reason)
            return false
        }
        return true
    }

    private func download(_ entry: Ledger.Entry, fresh: [RemoteItem]) async -> Ledger.Entry? {
        update(entry.id, .downloading, detail: nil)
        let item = fresh.first { $0.id == entry.id }
            ?? RemoteItem(id: entry.id, key: entry.key, name: entry.name, size: entry.size, modified: entry.modified, copies: entry.copies, sha256: entry.sha256)
        guard item.size <= RemoteLimits.fileBytes else {
            update(entry.id, .failed, detail: "\(RemoteError.tooLarge(limit: RemoteLimits.fileBytes))")
            return nil
        }
        let part = spool.appendingPathComponent("\(Self.fileStem(entry.id)).part")
        do {
            try await feed.download(item, to: part, limit: RemoteLimits.fileBytes)
            if let expected = item.sha256?.lowercased(), Self.sha256(part) != expected { throw RemoteError.checksumMismatch }
            guard let kind = FileKindSniffer.kind(of: part) else {
                try? FileManager.default.removeItem(at: part)
                update(entry.id, .failed, detail: "It isn't a PDF, PNG or JPEG")
                return nil
            }
            var e = ledger[entry.id] ?? entry
            e.name = SafeFileName.make(entry.name, fileExtension: kind, fallback: "Remote label")
            let target = spoolFile(e)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: part, to: target)
            e.state = .ready
            e.at = now()
            try ledger.record(e)
            return e
        } catch {
            try? FileManager.default.removeItem(at: part)
            // A passing failure goes back to the start, for the next check.
            update(entry.id, (error as? RemoteError)?.isPermanentForFile == true ? .failed : .new, detail: RemoteError.describe(error))
            return nil
        }
    }

    /// Its page count, or nil when it can't be opened. Looks at PDFs before they go near a job.
    private func checked(_ entry: Ledger.Entry) -> Int? {
        let file = spoolFile(entry)
        guard file.pathExtension == "pdf" else { return 1 }
        guard let document = CGPDFDocument(file as CFURL), document.numberOfPages > 0 else {
            update(entry.id, .failed, detail: "The PDF can't be opened")
            return nil
        }
        return document.numberOfPages
    }

    private func labelsInWindow() -> Int {
        let since = now().addingTimeInterval(-RemoteLimits.window)
        return ledger.all.filter { $0.state == .sent && $0.at >= since }.reduce(0) { $0 + ($1.labels ?? 0) }
    }

    // MARK: Records

    private func entry(_ item: RemoteItem, _ state: Ledger.State) -> Ledger.Entry {
        Ledger.Entry(id: item.id, key: item.key, name: item.name, size: item.size, modified: item.modified, state: state, at: now(), copies: item.copies, sha256: item.sha256)
    }

    private func update(_ id: String, _ state: Ledger.State, detail: String?) {
        guard var e = ledger[id] else { return }
        e.state = state
        e.at = now()
        e.detail = detail
        if Self.jobStatus(state) != nil, feed.sendsAcknowledgements { e.ackPending = true }
        try? ledger.record(e)
    }

    private static func sha256(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// In a folder of its own, so the name the rules see stays the sender's.
    private func spoolFile(_ entry: Ledger.Entry) -> URL {
        spool.appendingPathComponent(Self.fileStem(entry.id), isDirectory: true).appendingPathComponent(entry.name)
    }

    private func removeSpool(_ id: String) {
        try? FileManager.default.removeItem(at: spool.appendingPathComponent(Self.fileStem(id), isDirectory: true))
    }

    private static func fileStem(_ id: String) -> String {
        Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").prefix(120).description
    }
}

/// PDF, PNG and JPEG only, by their first bytes. The extension comes from here, not the sender.
enum FileKindSniffer {
    static func kind(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return kind(of: (try? handle.read(upToCount: 8)) ?? Data())
    }

    static func kind(of data: Data) -> String? {
        let head = [UInt8](data.prefix(8))
        if head.starts(with: Array("%PDF-".utf8)) { return "pdf" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        return nil
    }
}
