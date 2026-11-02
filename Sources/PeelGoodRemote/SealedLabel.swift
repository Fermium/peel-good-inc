import CryptoKit
import Foundation

/// The public keys of a source that only accepts encrypted labels. This Mac's private key lives in the Keychain.
public struct SourceEncryption: Codable, Equatable, Sendable {
    public var macKey: String
    public var senderKey: String

    public init(macKey: String, senderKey: String) {
        self.macKey = macKey
        self.senderKey = senderKey
    }
}

/// A label only the paired sender could have made and only this Mac can read: HPKE in auth mode, so the
/// source or anyone between sees ciphertext and can't forge a job. The format is in docs/REMOTE-SOURCES.md.
public enum SealedLabel {
    static let magic = Data("PGSEAL1\n".utf8)
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let info = Data("peel-good sealed label".utf8)
    private static let keyBytes = 32
    private static let detailsLimit = 4096

    /// What a source needs to open labels. Raw bytes, so an inbox can hold them across actors.
    public struct Keys: Sendable {
        let privateKey: Data
        let sender: Data

        public init(privateKey: String, sender: String) throws {
            guard let mac = Data(base64Encoded: privateKey), (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: mac)) != nil,
                  isValidKey(sender), let from = Data(base64Encoded: sender.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw RemoteError.invalidKey
            }
            self.privateKey = mac
            self.sender = from
        }
    }

    public struct Contents: Sendable {
        var file: Data
        var name: String?
        var copies: Int?
        /// Unique to each sealing, so a replayed label shows up whatever job it arrives as.
        var seal: String
    }

    private struct Details: Decodable {
        var name: String?
        var copies: Int?
    }

    /// Both in base64: the private key for the Keychain, the public key to give the sender.
    public static func newKeys() -> (privateKey: String, publicKey: String) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
    }

    public static func isValidKey(_ text: String) -> Bool {
        guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)) != nil
    }

    static func isSealed(_ data: Data) -> Bool { data.starts(with: magic) }

    /// Nothing inside gets read until the sender's key proves it's theirs.
    static func open(_ data: Data, keys: Keys) throws -> Contents {
        guard isSealed(data) else { throw RemoteError.notEncrypted }
        let body = data.dropFirst(magic.count)
        guard body.count > keyBytes else { throw RemoteError.cantDecrypt }
        let encapsulated = Data(body.prefix(keyBytes))
        let plain: Data
        do {
            var recipient = try HPKE.Recipient(privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keys.privateKey), ciphersuite: suite, info: info,
                                               encapsulatedKey: encapsulated, authenticatedBy: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keys.sender))
            plain = try recipient.open(Data(body.dropFirst(keyBytes)), authenticating: magic)
        } catch {
            throw RemoteError.cantDecrypt
        }
        guard plain.count >= 4 else { throw RemoteError.invalidEncryptedJob }
        let length = plain.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length <= detailsLimit, plain.count >= 4 + length,
              let details = try? JSONDecoder().decode(Details.self, from: plain.dropFirst(4).prefix(length)),
              details.copies.map(RemoteLimits.copies.contains) != false else { throw RemoteError.invalidEncryptedJob }
        return Contents(file: Data(plain.dropFirst(4 + length)), name: details.name, copies: details.copies,
                        seal: encapsulated.map { String(format: "%02x", $0) }.joined())
    }
}
