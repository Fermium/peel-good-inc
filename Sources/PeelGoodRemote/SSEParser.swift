import Foundation

/// The Server-Sent Events format, byte by byte, so a line can end in LF, CR or CRLF as the spec allows
/// and the blank line that ends an event is never lost.
struct SSEParser {
    struct Message: Equatable {
        var event: String
        var data: String
        var id: String?
    }

    private var line: [UInt8] = []
    private var data: [UInt8] = []
    private var hasData = false
    private var event = ""
    private var lastID: String?
    private var atStart = true
    private var afterCR = false
    /// The event passed the size limit. It still ends at its blank line, so the stream carries on.
    private var tooLarge = false
    private var discardingLine = false

    /// Feeds one byte; returns a message when it completes one.
    mutating func feed(_ byte: UInt8) -> Message? {
        if afterCR {
            afterCR = false
            if byte == 0x0A { return nil }
        }
        switch byte {
        case 0x0D:
            afterCR = true
            return endLine()
        case 0x0A:
            return endLine()
        default:
            guard !discardingLine else { return nil }
            line.append(byte)
            if line.count + data.count > RemoteLimits.eventBytes {
                tooLarge = true
                hasData = true
                discardingLine = true
                line.removeAll(keepingCapacity: false)
                data.removeAll(keepingCapacity: false)
            }
            return nil
        }
    }

    private mutating func endLine() -> Message? {
        if discardingLine {
            discardingLine = false
            return nil
        }
        defer { line.removeAll(keepingCapacity: true) }
        if atStart {
            atStart = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        if line.isEmpty {
            defer {
                data.removeAll(keepingCapacity: true)
                hasData = false
                tooLarge = false
                event = ""
            }
            guard hasData else { return nil }
            return Message(event: event.isEmpty ? "message" : event, data: String(decoding: data, as: UTF8.self), id: lastID)
        }
        if line[0] == 0x3A { return nil }   // A comment: keeps the connection alive.
        let colon = line.firstIndex(of: 0x3A)
        let name = String(decoding: line[..<(colon ?? line.endIndex)], as: UTF8.self)
        var value = colon.map { Array(line[($0 + 1)...]) } ?? []
        if value.first == 0x20 { value.removeFirst() }
        switch name {
        case "data":
            if tooLarge { break }
            if hasData { data.append(0x0A) }
            data += value
            hasData = true
        case "event":
            event = String(decoding: value, as: UTF8.self)
        case "id":
            // It goes back as a header when reconnecting, so it has to stay small.
            if !value.contains(0), value.count <= 1024 { lastID = String(decoding: value, as: UTF8.self) }
        default:
            break
        }
        return nil
    }
}

/// Waiting between reconnects: doubling with jitter up to 5 minutes, and back to the start after a
/// connection that lasted.
public struct Backoff: Sendable {
    public static let healthy: TimeInterval = 60
    private var attempt = 0

    public init() {}

    public mutating func next(connectedFor: TimeInterval, jitter: Double = Double.random(in: 0.8...1.2)) -> TimeInterval {
        if connectedFor >= Self.healthy { attempt = 0 }
        defer { attempt += 1 }
        return min(pow(2, Double(attempt)) * jitter, 300)
    }
}
