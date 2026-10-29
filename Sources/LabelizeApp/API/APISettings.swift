import Foundation
import Security
import PeelGoodShared

/// Files and defaults the local API shares with clients: the bearer token (mode 0600)
/// and server.json, which says where the server is listening.
enum APISettings {
    static let defaultPort = 47311

    static var folder: URL {
        let url = AppPaths.support
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var tokenURL: URL { _ = folder; return AppPaths.token }
    static var serverInfoURL: URL { _ = folder; return AppPaths.serverInfo }

    // MARK: Token

    /// The saved token, or a new one if there is none.
    static func loadOrCreateToken() -> String {
        if let data = try? Data(contentsOf: tokenURL),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           token.count >= 32 {
            restrictPermissions(tokenURL)
            return token
        }
        return regenerateToken()
    }

    /// 32 random bytes as hex, saved readable only by this user.
    @discardableResult
    static func regenerateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        writePrivate(Data((token + "\n").utf8), to: tokenURL)
        Log.notice(.api, "new API token saved to \(tokenURL.path)")
        return token
    }

    // MARK: server.json

    /// PeelGoodShared's, which Doctor and the MCP relay read.
    typealias ServerInfo = PeelGoodShared.ServerInfo

    static func writeServerInfo(port: Int, http: Bool, mcp: Bool) {
        let info = ServerInfo(port: port, pid: ProcessInfo.processInfo.processIdentifier, http: http, mcp: mcp,
                              tokenPath: tokenURL.path, version: OpenAPI.appVersion)
        guard let data = try? APIJSON.encoder.encode(info) else { return }
        writePrivate(data, to: serverInfoURL)
    }

    static func removeServerInfo() {
        try? FileManager.default.removeItem(at: serverInfoURL)
    }

    // MARK: Files

    /// Writes to a temporary file with mode 0600, then moves it into place.
    private static func writePrivate(_ data: Data, to url: URL) {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            Log.error(.api, "can't write \(url.path)")
            return
        }
        restrictPermissions(temp)
        if rename(temp.path, url.path) != 0 {
            Log.error(.api, "can't save \(url.path): \(String(cString: strerror(errno)))")
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private static func restrictPermissions(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
