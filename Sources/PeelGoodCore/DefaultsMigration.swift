import Foundation
import PeelGoodShared

/// Copies the settings saved under the old bundle ID into the current domain, once.
public enum DefaultsMigration {
    /// The keys stored in a UserDefaults domain for the current user.
    public static func keys(in domain: String) -> [String] {
        CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
    }

    /// When `to` has no keys and `from` has some, copies every key of `from` into `to` and returns how
    /// many were copied; otherwise 0. `from` is left as it was.
    @discardableResult
    public static func copy(from: String = AppIdentity.legacyBundleID, to: String = AppIdentity.bundleID) -> Int {
        guard keys(in: to).isEmpty else { return 0 }
        let old = keys(in: from)
        guard !old.isEmpty,
              let values = CFPreferencesCopyMultiple(old as CFArray, from as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any],
              !values.isEmpty else { return 0 }
        CFPreferencesSetMultiple(values as CFDictionary, nil, to as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(to as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return values.count
    }
}
