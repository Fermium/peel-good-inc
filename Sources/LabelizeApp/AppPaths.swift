import Foundation

/// Where Peel Good Inc. keeps its files. Versions before the rename used "Labelize" folders;
/// `migrate()` moves them over once, before anything else reads or writes them.
enum AppPaths {
    static let folderName = "Peel Good"
    private static let oldFolderName = "Labelize"

    nonisolated static var support: URL { isScratchRun ? scratch("Application Support") : library("Application Support") }
    nonisolated static var logs: URL { isScratchRun ? scratch("Logs") : library("Logs") }

    /// Tests and development runs (`-apiMock`, `-apiDryRun`) use temporary folders, never the user's data.
    nonisolated static let isScratchRun: Bool = {
        let env = ProcessInfo.processInfo.environment, args = ProcessInfo.processInfo.arguments
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || args.contains("-apiMock") || args.contains("-apiDryRun") || NSClassFromString("XCTestCase") != nil
    }()

    nonisolated private static func scratch(_ sub: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Peel Good test", isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true)
    }

    nonisolated private static func library(_ sub: String, name: String = folderName) -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(sub, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Moves ~/Library/Application Support/Labelize and ~/Library/Logs/Labelize to the new names.
    static func migrate() {
        guard !isScratchRun else { return }
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
