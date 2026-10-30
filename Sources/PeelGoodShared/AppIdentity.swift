// Names and identifiers every part of Peel Good Inc. agrees on. Foundation only and self-contained,
// so the Share extension can compile this one file directly (scripts/make-app.sh).

/// The app's names and IDs.
public enum AppIdentity {
    /// Bundle identifier, UserDefaults domain and os_log subsystem.
    public static let bundleID = "com.fermium.peelgood"
    /// Bundle identifier (and UserDefaults domain) of the old name; the app copies its settings over once.
    public static let legacyBundleID = "com.fermiumlabs.labelize"  // old name
    /// The name people see.
    public static let appName = "Peel Good Inc."
    /// Folder name in ~/Library/Application Support and ~/Library/Logs.
    public static let folderName = "Peel Good"
    /// Folder name used before the rename; moved over once by the app.
    public static let legacyFolderName = "Labelize"  // old name
    public static let logFileName = "Peel Good.log"
    /// The stdio MCP relay inside the app bundle (Contents/MacOS).
    public static let mcpRelayName = "peel-good-mcp"
    /// The data folder as people type it, for help text: "~/Library/Application Support/Peel Good".
    public static let supportFolderDisplay = "~/Library/Application Support/" + folderName
}
