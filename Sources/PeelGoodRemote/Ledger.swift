import Foundation

/// What became of each remote item, in an append-only file that survives crashes: every change is
/// a line, flushed to disk, and the newest line for an item wins. A torn last line is ignored.
public final class Ledger: @unchecked Sendable {
    public enum State: String, Codable, Sendable {
        case new, downloading, ready
        /// Asked first, waiting for a person.
        case waiting
        /// Over a limit, waiting for a person.
        case held
        case printing, sent, cancelled, failed
        /// The app stopped while printing: it may or may not have printed.
        case unclear
        /// Was there before this source started.
        case skipped
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var key: String
        /// The file name to show.
        public var name: String
        public var size: Int
        public var modified: Date
        public var state: State
        public var at: Date
        public var detail: String?
        public var labels: Int?
        public var copies: Int?
        public var sha256: String?
        /// The server hasn't heard what became of it yet.
        public var ackPending: Bool?

        public init(id: String, key: String, name: String, size: Int, modified: Date, state: State, at: Date,
                    detail: String? = nil, labels: Int? = nil, copies: Int? = nil, sha256: String? = nil) {
            self.id = id
            self.key = key
            self.name = name
            self.size = size
            self.modified = modified
            self.state = state
            self.at = at
            self.detail = detail
            self.labels = labels
            self.copies = copies
            self.sha256 = sha256
        }

        public var isDone: Bool { [.sent, .cancelled, .skipped].contains(state) }
    }

    private let file: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init(file: URL) throws {
        self.file = file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for line in data.split(separator: 0x0A) {
                guard let e = try? decoder.decode(Entry.self, from: line) else { continue }
                if entries[e.id] == nil { order.append(e.id) }
                entries[e.id] = e
            }
        } else {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
    }

    public subscript(id: String) -> Entry? { lock.withLock { entries[id] } }

    public var all: [Entry] { lock.withLock { order.compactMap { entries[$0] } } }

    public func record(_ entry: Entry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try lock.withLock {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            if entries[entry.id] == nil { order.append(entry.id) }
            entries[entry.id] = entry
        }
    }

    /// Rewrites the file with one line per item, leaving out finished items a listing can no longer
    /// return (`cutoff` is behind the watermark, so they can't print again).
    public func compact(droppingDoneBefore cutoff: Date) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try lock.withLock {
            let keep = order.compactMap { entries[$0] }.filter { !($0.isDone && $0.modified < cutoff) }
            var data = Data()
            for e in keep {
                data.append(try encoder.encode(e))
                data.append(0x0A)
            }
            try data.write(to: file, options: .atomic)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
            order = keep.map(\.id)
        }
    }
}
