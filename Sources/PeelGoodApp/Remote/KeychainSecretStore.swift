import Foundation
import PeelGoodRemote
import PeelGoodShared
import Security

/// Remote sources' secret keys, in the login Keychain. On ad hoc signed builds macOS asks once after
/// each update before handing a key to the new build, and the call waits for that answer: never call
/// this on the main thread.
struct KeychainSecretStore: SecretStore {
    struct Failed: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
    }

    private func query(_ source: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(AppIdentity.bundleID).remote",
         kSecAttrAccount as String: source.uuidString]
    }

    func secret(for source: UUID) throws -> String? {
        var q = query(source)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failed(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    func setSecret(_ secret: String?, for source: UUID) throws {
        SecItemDelete(query(source) as CFDictionary)
        guard let secret else { return }
        var item = query(source)
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrLabel as String] = "\(AppIdentity.appName) remote source"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failed(status: status) }
    }
}
