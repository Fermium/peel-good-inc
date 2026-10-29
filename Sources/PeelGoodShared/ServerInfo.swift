import Foundation

/// server.json: where the app's local API listens. The app writes it; Doctor and the MCP relay read it.
public struct ServerInfo: Codable, Sendable, Equatable {
    public var port: Int
    public var pid: Int32
    public var http: Bool
    public var mcp: Bool
    public var url: String
    public var mcpURL: String
    public var tokenPath: String
    public var version: String

    public init(port: Int, pid: Int32, http: Bool, mcp: Bool, tokenPath: String, version: String) {
        self.port = port
        self.pid = pid
        self.http = http
        self.mcp = mcp
        self.url = "http://127.0.0.1:\(port)"
        self.mcpURL = "http://127.0.0.1:\(port)/mcp"
        self.tokenPath = tokenPath
        self.version = version
    }

    /// The saved file, if there is one and it reads.
    public static func load(from url: URL = AppPaths.serverInfo) -> ServerInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ServerInfo.self, from: data)
    }

    /// True while the process that wrote it is still running.
    public var isAlive: Bool { pid > 0 && kill(pid, 0) == 0 }

    /// The token the app saved, trimmed.
    public static func token(at url: URL = AppPaths.token) -> String? {
        (try? String(contentsOf: url, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
