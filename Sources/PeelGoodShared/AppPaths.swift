import Foundation

/// Where Peel Good Inc. keeps its files, for the app, the command line, the MCP relay and Doctor.
///
/// `LABELIZE_SUPPORT_DIR` replaces the data folder (the CLI's tests use it). Tests and development runs
/// of the app (`-apiMock`, `-apiDryRun`, XCTest) use a temporary folder, never the user's data.
public enum AppPaths {
    public static var support: URL {
        if let dir = override { return dir }
        return isScratchRun ? scratch("Application Support") : library("Application Support")
    }

    public static var logs: URL { isScratchRun ? scratch("Logs") : library("Logs") }

    /// Saved copies of printed labels, for Reprint Last Label and `peelgood history`.
    public static var history: URL { support.appendingPathComponent("History", isDirectory: true) }
    /// The rule list the app edits and the CLI reads.
    public static var rulesFile: URL { support.appendingPathComponent("rules.json") }
    /// The local API's bearer token (mode 0600).
    public static var token: URL { support.appendingPathComponent("token") }
    /// Where the local API listens, written by the app while it runs (`ServerInfo`).
    public static var serverInfo: URL { support.appendingPathComponent("server.json") }
    public static var logFile: URL { logs.appendingPathComponent(AppIdentity.logFileName) }

    /// `LABELIZE_SUPPORT_DIR`, when set.
    public static var override: URL? {
        guard let dir = ProcessInfo.processInfo.environment["LABELIZE_SUPPORT_DIR"], !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static let isScratchRun: Bool = {
        let env = ProcessInfo.processInfo.environment, args = ProcessInfo.processInfo.arguments
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || args.contains("-apiMock") || args.contains("-apiDryRun") || NSClassFromString("XCTestCase") != nil
    }()

    private static func scratch(_ sub: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Peel Good test", isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true)
    }

    /// ~/Library/<sub>/<name>.
    public static func library(_ sub: String, name: String = AppIdentity.folderName) -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(sub, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }
}
