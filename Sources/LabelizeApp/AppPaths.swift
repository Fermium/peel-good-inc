import Foundation

/// Where Peel Good Inc. keeps its files. Versions before the rename used "Labelize" folders;
/// `migrate()` moves them over once, before anything else reads or writes them.
enum AppPaths {
    static let folderName = "Peel Good"
    private static let oldFolderName = "Labelize"

    nonisolated static var support: URL { library("Application Support") }
    nonisolated static var logs: URL { library("Logs") }

    nonisolated private static func library(_ sub: String, name: String = folderName) -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(sub, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Moves ~/Library/Application Support/Labelize and ~/Library/Logs/Labelize to the new names.
    static func migrate() {
        let fm = FileManager.default
        for sub in ["Application Support", "Logs"] {
            let old = library(sub, name: oldFolderName), new = library(sub)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            try? fm.moveItem(at: old, to: new)
            // Saved paths that pointed into the old folder (Reprint Last Label).
            let defaults = UserDefaults.standard
            if let last = defaults.string(forKey: "last.file"), last.hasPrefix(old.path) {
                defaults.set(new.path + last.dropFirst(old.path.count), forKey: "last.file")
            }
        }
        let oldLog = logs.appendingPathComponent("Labelize.log")
        if fm.fileExists(atPath: oldLog.path) { try? fm.moveItem(at: oldLog, to: logs.appendingPathComponent("Peel Good.log")) }
    }
}
