import AppKit
import LabelKit

/// What happens to the original file after its labels print.
enum AfterPrintAction: String, CaseIterable, Identifiable {
    case leave, rename, move, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .leave: "Leave it"
        case .rename: "Add suffix"
        case .move: "Move to folder"
        case .trash: "Move to Trash"
        }
    }
}

@MainActor
enum AfterPrint {
    /// Tags and then renames, moves or trashes each original file. Temporary copies
    /// (clipboard, promised files, the Share extension, test labels) are left alone.
    static func apply(to files: [URL], store: Store, tag: Bool = true) {
        for file in files where isUserFile(file) {
            Log.info(.files, "after printing \(file.lastPathComponent): tag \(store.tagAfterPrint ? store.tagName : "none"), then \(store.afterPrintAction.rawValue)")
            if tag, store.tagAfterPrint, !store.tagName.isEmpty { FinderTag(name: store.tagName, color: store.tagColor).apply(to: file) }
            do {
                switch store.afterPrintAction {
                case .leave:
                    break
                case .rename:
                    let ext = file.pathExtension
                    let base = file.deletingPathExtension().lastPathComponent
                    guard !base.hasSuffix(store.renameSuffix) else { break }
                    let name = base + store.renameSuffix + (ext.isEmpty ? "" : ".\(ext)")
                    try FileManager.default.moveItem(at: file, to: unique(file.deletingLastPathComponent().appendingPathComponent(name)))
                case .move:
                    guard let folder = store.moveFolder else { break }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: file, to: unique(folder.appendingPathComponent(file.lastPathComponent)))
                case .trash:
                    try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                }
            } catch {
                Log.error(.files, "\(store.afterPrintAction.rawValue) failed for \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    static func isUserFile(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return !path.hasPrefix(temp) && !path.contains("/Library/Containers/") && !path.hasPrefix(Store.historyFolder.path)
    }

    static func addTag(_ tag: String, to url: URL) {
        let existing = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        guard !existing.contains(tag) else { return }
        try? (url as NSURL).setResourceValue(existing + [tag], forKey: .tagNamesKey)
    }

    /// "name.pdf", then "name 2.pdf", "name 3.pdf"…
    static func unique(_ url: URL) -> URL {
        var candidate = url, n = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }
}

enum History {
    /// Deletes saved prints older than `days`; 0 keeps everything.
    static func prune(keepingDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: Store.historyFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
            if created < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func deleteAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Store.historyFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    static var summary: String {
        let files = (try? FileManager.default.contentsOfDirectory(at: Store.historyFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return "\(files.count) label file\(files.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }
}

enum PrinterRemoval {
    /// Deletes the print queue from this Mac. macOS may ask for an administrator password.
    nonisolated static func removeFromMac(_ name: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lpadmin")
        process.arguments = ["-x", name]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self)
            throw NSError(domain: "Labelize", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Couldn't remove the printer.",
                NSLocalizedRecoverySuggestionErrorKey: message.isEmpty ? "Try removing it in System Settings › Printers & Scanners." : message,
            ])
        }
    }
}
