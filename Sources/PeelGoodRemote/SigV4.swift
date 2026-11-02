import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3 and stores that speak its API (R2, B2, MinIO).
struct SigV4 {
    var accessKey: String
    var secretKey: String
    var sessionToken: String?
    var region: String
    var service = "s3"

    static let emptyPayload = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// The headers to send, Authorization included. `path` and `query` are not yet percent-encoded.
    func headers(method: String, host: String, path: String, query: [String: String], extra: [String: String] = [:],
                 payloadHash: String = emptyPayload, date: Date) -> [String: String] {
        let (stamp, day) = Self.stamps(date)
        var headers = extra.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value.trimmingCharacters(in: .whitespaces) }
        headers["host"] = host
        headers["x-amz-date"] = stamp
        headers["x-amz-content-sha256"] = payloadHash
        if let sessionToken { headers["x-amz-security-token"] = sessionToken }

        let names = headers.keys.sorted()
        let signed = names.joined(separator: ";")
        let canonical = [
            method,
            Self.encodePath(path),
            Self.encodeQuery(query),
            names.map { "\($0):\(headers[$0]!)\n" }.joined(),
            signed,
            payloadHash,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")

        var key = Self.hmac(Data("AWS4\(secretKey)".utf8), day)
        for part in [region, service, "aws4_request"] { key = Self.hmac(key, part) }
        let signature = Self.hex(Self.hmac(key, toSign))

        headers["authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signed), Signature=\(signature)"
        headers.removeValue(forKey: "host")   // URLSession sets it from the URL.
        return headers
    }

    /// RFC 3986 unreserved characters stay; everything else is encoded, with `/` kept in paths.
    static func encode(_ s: String, keepSlash: Bool = false) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: out.unicodeScalars.append(Unicode.Scalar(byte))
            case 0x2F where keepSlash: out += "/"
            default: out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func encodePath(_ path: String) -> String { encode(path, keepSlash: true) }

    static func encodeQuery(_ query: [String: String]) -> String {
        query.map { (encode($0.key), encode($0.value)) }.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    private static func stamps(_ date: Date) -> (stamp: String, day: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = f.string(from: date)
        return (stamp, String(stamp.prefix(8)))
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
