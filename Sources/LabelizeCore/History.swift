import CoreGraphics
import Foundation
import PeelGoodShared

/// Saved copies of printed labels: "<ISO date> <name>.label.pdf" in the History folder.
/// The app saves every print here; `peelgood print` does too unless --no-history. Reprint Last Label
/// and `peelgood history` read it.
public enum History {
    /// The folder, created on first use.
    public static var folder: URL {
        let url = AppPaths.history
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "<now> <name>.label.pdf". A reprint's source is already a history file, so its timestamps
    /// and ".label" are taken off first: names don't pile up.
    public static func fileName(for file: URL?, at date: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return "\(stamp) \(baseName(file)).label.pdf"
    }

    nonisolated(unsafe) private static let stamp = try! Regex(#"^(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(?:\.\d+)?Z)\s+"#)

    /// The name without history stamps and ".label": "order 1459".
    public static func baseName(_ file: URL?) -> String {
        parse(file?.deletingPathExtension().lastPathComponent ?? "label").name
    }

    /// A history file name's name and the date in its stamp.
    public static func parse(_ stem: String) -> (name: String, date: Date?) {
        var name = stem, date: Date?
        if let m = name.prefixMatch(of: stamp), let s = m.output[1].substring {
            let iso = String(s).replacingOccurrences(of: #"T(\d{2})-(\d{2})-(\d{2})"#, with: "T$1:$2:$3", options: .regularExpression)
            date = ISO8601DateFormatter().date(from: iso)
        }
        while let m = name.prefixMatch(of: stamp) { name.removeSubrange(m.range) }
        while name.hasSuffix(".label") { name.removeLast(".label".count) }
        name = name.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "label" : name, date)
    }

    public struct Entry: Sendable, Equatable {
        public var name: String
        public var date: Date
        public var labels: Int
        public var url: URL
    }

    /// Saved prints, newest first.
    public static func entries(in folder: URL = AppPaths.history) -> [Entry] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "pdf" }.map { url in
            let parsed = parse(url.deletingPathExtension().lastPathComponent)
            let created = (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
            return Entry(name: parsed.name, date: parsed.date ?? created, labels: CGPDFDocument(url as CFURL)?.numberOfPages ?? 0, url: url)
        }.sorted { $0.date > $1.date }
    }

    /// Copies a label PDF into History under its stamped name; returns the copy.
    @discardableResult
    public static func save(_ pdf: URL, source: URL?, in folder: URL = History.folder, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(fileName(for: source, at: date))
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: pdf, to: dest)
        return dest
    }

    /// Deletes saved prints older than `days`; 0 keeps everything.
    public static func prune(keepingDays days: Int, in folder: URL = AppPaths.history) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
            if created < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    public static func deleteAll(in folder: URL = AppPaths.history) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// "3 label files, 120 KB"
    public static func summary(in folder: URL = AppPaths.history) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return "\(files.count) label file\(files.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }
}
