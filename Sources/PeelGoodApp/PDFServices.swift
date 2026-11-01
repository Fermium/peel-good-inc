import Foundation
import PeelGoodShared

/// The PDF menu of every Print dialog: an alias to the app in ~/Library/PDF Services sends the printed
/// PDF to `application(_:open:)`, which prints it as a label like any other file.
enum PDFServices {
    /// The menu item's title is the alias's name.
    static let title = "Print Label with \(AppIdentity.appName)"

    static var folder: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/PDF Services", isDirectory: true) }

    /// Only a real app bundle can be put in the menu (not `swift run`).
    static var app: URL? { Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil }

    static func entry(in folder: URL = folder) -> URL { folder.appendingPathComponent(title) }

    /// Where the menu item points, if it's there.
    static func destination(in folder: URL = folder) -> URL? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: entry(in: folder).path)).map { URL(fileURLWithPath: $0) }
    }

    static func isInstalled(in folder: URL = folder) -> Bool { destination(in: folder) != nil }

    static func install(app: URL, in folder: URL = folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try remove(from: folder)
        try FileManager.default.createSymbolicLink(at: entry(in: folder), withDestinationURL: app)
    }

    static func remove(from folder: URL = folder) throws {
        let entry = entry(in: folder)
        // A dangling link fails fileExists, so ask for its attributes instead.
        guard (try? FileManager.default.attributesOfItem(atPath: entry.path)) != nil else { return }
        try FileManager.default.removeItem(at: entry)
    }

    /// After the app moves, the menu item points at nothing: point it at this copy. A working item is
    /// left alone, and so is a copy run from a disk image or a translocated (quarantined) location.
    static func repair(app: URL? = app, in folder: URL = folder) {
        guard let app, !app.path.contains("/AppTranslocation/"), !app.path.hasPrefix("/Volumes/"),
              let current = destination(in: folder), current.standardizedFileURL != app.standardizedFileURL,
              !FileManager.default.fileExists(atPath: current.path) else { return }
        try? install(app: app, in: folder)
    }
}
