import Foundation
import PeelGoodCore
import PeelGoodShared

extension DefaultsMigration {
    /// Copies the old bundle ID's UserDefaults into the app's domain on first launch, before anything
    /// reads settings. Only the installed app does this (a scratch run or `swift run` has another domain).
    /// Returns a line for the log, which is written after the folders move.
    static func migrateAppDefaults() -> String? {
        guard !AppPaths.isScratchRun, AppPaths.override == nil,
              Bundle.main.bundleIdentifier == AppIdentity.bundleID else { return nil }
        let n = copy(from: AppIdentity.legacyBundleID, to: AppIdentity.bundleID)
        return n > 0 ? "Copied \(n) settings from \(AppIdentity.legacyBundleID) to \(AppIdentity.bundleID)" : nil
    }
}
