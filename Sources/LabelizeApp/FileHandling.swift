import AppKit
import LabelKit
import LabelizeCore

@MainActor
enum AfterPrint {
    /// Tags (with the tag `RuleTag.resolve` picked, if any) and then renames, moves or trashes each
    /// original file. Temporary copies (clipboard, promised files, the Share extension, test labels) are left alone.
    static func apply(to files: [URL], store: Store, tag: FinderTag?) {
        for file in files where isUserFile(file) {
            Log.info(.files, "after printing \(file.lastPathComponent): tag \(tag?.name ?? "none"), then \(store.afterPrintAction.rawValue)")
            tag?.apply(to: file)
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

    nonisolated static func isUserFile(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return !path.hasPrefix(temp) && !path.contains("/Library/Containers/") && !path.hasPrefix(Store.historyFolder.resolvingSymlinksInPath().path)
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
