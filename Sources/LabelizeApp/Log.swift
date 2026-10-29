import Foundation
import os

/// App logging: every message goes to the unified log (Console.app, `log stream
/// --predicate 'subsystem == "com.fermiumlabs.labelize"'`) and to a readable file in
/// ~/Library/Logs/Peel Good, which the Logs window shows.
enum Log {
    enum Level: String, CaseIterable, Comparable, Sendable {
        case debug, info, notice, warning, error

        var tag: String {
            switch self {
            case .debug: "DEBUG"
            case .info: "INFO "
            case .notice: "NOTE "
            case .warning: "WARN "
            case .error: "ERROR"
            }
        }

        static func < (a: Level, b: Level) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    }

    enum Category: String, CaseIterable, Sendable {
        case app, drop, intake, job, print, files, rules, api
    }

    static let subsystem = "com.fermiumlabs.labelize"
    private static let loggers = Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })
    private static let queue = DispatchQueue(label: "labelize.log.file")
    private static let maxFileBytes = 2_000_000

    static var fileURL: URL {
        let dir = AppPaths.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Peel Good.log")
    }

    static func debug(_ c: Category, _ message: @autoclosure () -> String) { write(.debug, c, message()) }
    static func info(_ c: Category, _ message: @autoclosure () -> String) { write(.info, c, message()) }
    static func notice(_ c: Category, _ message: @autoclosure () -> String) { write(.notice, c, message()) }
    static func warning(_ c: Category, _ message: @autoclosure () -> String) { write(.warning, c, message()) }
    static func error(_ c: Category, _ message: @autoclosure () -> String) { write(.error, c, message()) }

    private static func write(_ level: Level, _ category: Category, _ message: String) {
        let logger = loggers[category]!
        // Info and debug aren't kept by the unified log, so use notice for info to make it persist.
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info, .notice: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let line = "\(timestamp())  \(level.tag)  \(category.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))  \(message)\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        let url = fileURL
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileBytes {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func timestamp() -> String { queue.sync { formatter.string(from: Date()) } }

    /// One parsed line of the log file, for the Logs window.
    struct Entry: Identifiable, Sendable {
        let id: Int
        let time: String
        let level: Level
        let category: String
        let message: String
    }

    static func readEntries(limit: Int = 2000) -> [Entry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)
        return lines.enumerated().compactMap { i, line in
            // "2026-10-29 19:52:03.123  INFO   drop    message"
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { return nil }
            let rest = parts[2].drop(while: { $0 == " " })
            let fields = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let level = Level.allCases.first(where: { $0.tag.trimmingCharacters(in: .whitespaces) == fields[0] }) else { return nil }
            let message = fields.count > 2 ? String(fields[2]).trimmingCharacters(in: .whitespaces) : ""
            return Entry(id: i, time: "\(parts[0]) \(parts[1])", level: level, category: String(fields[1]), message: message)
        }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }
}
