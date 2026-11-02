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

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(AppIdentity.bundleID).remote",
         kSecAttrAccount as String: account]
    }

    func secret(for source: UUID) throws -> String? { try read(source.uuidString) }
    func setSecret(_ secret: String?, for source: UUID) throws { try write(secret, source.uuidString) }
    func privateKey(for source: UUID) throws -> String? { try read("\(source.uuidString).private-key") }
    func setPrivateKey(_ key: String?, for source: UUID) throws { try write(key, "\(source.uuidString).private-key") }

    private func read(_ account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failed(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ secret: String?, _ account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        guard let secret else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrLabel as String] = "\(AppIdentity.appName) remote source"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failed(status: status) }
    }
}
