import Foundation
import LabelizeCore
import PeelGoodShared

extension AppPaths {
    /// Moves ~/Library/Application Support/Labelize and ~/Library/Logs/Labelize to the new names, once,
    /// before anything else reads or writes them. Only the app does this.
    static func migrate() {
        guard !isScratchRun, override == nil else { return }
        let fm = FileManager.default
        for sub in ["Application Support", "Logs"] {
            let old = library(sub, name: AppIdentity.legacyFolderName), new = library(sub)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            try? fm.moveItem(at: old, to: new)
            // Saved paths that pointed into the old folder (Reprint Last Label).
            let settings = AppSettings.userDefaults(.standard)
            if let last = settings.string(SettingsKey.lastFile.rawValue), last.hasPrefix(old.path) {
                settings.set(new.path + last.dropFirst(old.path.count), SettingsKey.lastFile.rawValue)
            }
        }
        let oldLog = logs.appendingPathComponent("Labelize.log")
        if fm.fileExists(atPath: oldLog.path) { try? fm.moveItem(at: oldLog, to: logFile) }
    }
}
