import AppKit
import UniformTypeIdentifiers

/// Turns whatever arrives (drops, the clipboard, Services, item providers) into files on disk.
/// Real files are used in place; promised files (screenshot thumbnails, browsers, Mail) are
/// received into a temporary folder; raw PDF or image data is written to a temporary file.
enum Intake {
    static let fileTypes: [UTType] = [.pdf, .svg, .image]

    /// A format the app reads from raw data: the clipboard, uploads without a usable name, MCP's content_base64.
    struct Format: Sendable {
        var type: UTType
        /// Extension for the file it's saved as.
        var ext: String
        /// Recognises the data from its first bytes.
        var matches: @Sendable (Data) -> Bool
        var mimeType: String { type.preferredMIMEType ?? "application/octet-stream" }
    }

    /// The one list of data formats, in the order the clipboard is read. `dataTypes`, `APIRoutes.uploadName` and
    /// `MCPTools.sniff` all read it.
    static let formats: [Format] = [
        Format(type: .pdf, ext: "pdf") { starts($0, "%PDF") },
        Format(type: .png, ext: "png") { starts($0, [0x89, 0x50, 0x4E, 0x47]) },
        Format(type: .jpeg, ext: "jpg") { starts($0, [0xFF, 0xD8, 0xFF]) },
        Format(type: .svg, ext: "svg") { String(decoding: $0.prefix(256), as: UTF8.self).contains("<svg") },
        Format(type: .tiff, ext: "tiff") { starts($0, [0x49, 0x49, 0x2A, 0x00]) || starts($0, [0x4D, 0x4D, 0x00, 0x2A]) },
        Format(type: .gif, ext: "gif") { starts($0, "GIF8") },
        Format(type: .heic, ext: "heic") { data in
            let head = [UInt8](data.prefix(12))
            guard head.count == 12, String(decoding: head[4..<8], as: UTF8.self) == "ftyp" else { return false }
            return ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(String(decoding: head[8..<12], as: UTF8.self))
        },
    ]

    /// The format of some data, from its first bytes.
    static func format(of data: Data) -> Format? { formats.first { $0.matches(data) } }

    /// The format for a content type such as "image/png; charset=binary".
    static func format(mimeType: String?) -> Format? {
        guard let mime = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
              let type = UTType(mimeType: mime) else { return nil }
        return formats.first { type.conforms(to: $0.type) }
    }

    private static func starts(_ data: Data, _ bytes: [UInt8]) -> Bool { data.prefix(bytes.count).elementsEqual(bytes) }
    private static func starts(_ data: Data, _ text: String) -> Bool { starts(data, Array(text.utf8)) }

    static let dataTypes: [(NSPasteboard.PasteboardType, String)] = formats.map { (NSPasteboard.PasteboardType($0.type.identifier), $0.ext) }

    static var pasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + dataTypes.map(\.0) + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return fileTypes.contains { type.conforms(to: $0) }
    }

    /// Whether the pasteboard holds something printable, without reading file contents.
    static func canRead(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.contains(where: isSupported)
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            return promises.contains { $0.fileTypes.contains { t in UTType(t).map { u in fileTypes.contains { u.conforms(to: $0) } } ?? false } }
        }
        return dataTypes.contains { pb.availableType(from: [$0.0]) != nil }
    }

    /// Reads everything synchronously first (drag pasteboards don't outlive the drop),
    /// then waits for any promised files.
    @MainActor
    static func files(from pb: NSPasteboard, name: String) async -> [URL] {
        Log.info(.intake, "\(name): pasteboard types \(pb.types?.map(\.rawValue).joined(separator: ", ") ?? "none")")
        let allURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let urls = allURLs.filter(isSupported)
        if !allURLs.isEmpty {
            Log.info(.intake, "files: \(allURLs.map(\.lastPathComponent).joined(separator: ", ")) (\(urls.count) printable)")
        }
        if !urls.isEmpty { return urls }

        let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        if !promises.isEmpty {
            Log.info(.intake, "receiving \(promises.count) promised file(s): \(promises.flatMap(\.fileTypes).joined(separator: ", "))")
            let folder = scratchFolder()
            var received: [URL] = []
            for promise in promises {
                received += await withCheckedContinuation { (done: CheckedContinuation<[URL], Never>) in
                    var files: [URL] = []
                    var remaining = max(1, promise.fileNames.count)
                    promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                        if let error { Log.error(.intake, "promised file failed: \(error.localizedDescription)") } else {
                            Log.info(.intake, "received \(url.lastPathComponent)")
                            files.append(url)
                        }
                        remaining -= 1
                        if remaining == 0 { done.resume(returning: files) }
                    }
                }
            }
            return received.filter(isSupported)
        }

        for (type, ext) in dataTypes {
            guard let data = pb.data(forType: type) else { continue }
            let url = scratchFolder().appendingPathComponent("\(name).\(ext)")
            do {
                try data.write(to: url)
                Log.info(.intake, "wrote \(data.count) bytes of \(type.rawValue) to \(url.lastPathComponent)")
                return [url]
            } catch {
                Log.error(.intake, "can't write \(url.path): \(error.localizedDescription)")
            }
        }
        Log.warning(.intake, "\(name): nothing printable found")
        return []
    }

    /// Item providers from SwiftUI drops: file URLs, or file representations of PDFs and images.
    static func files(from providers: [NSItemProvider]) async -> [URL] {
        Log.info(.intake, "item providers: \(providers.map { $0.registeredTypeIdentifiers.joined(separator: "/") }.joined(separator: ", "))")
        var result: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await withCheckedContinuation({ (done: CheckedContinuation<URL?, Never>) in
                   _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                       done.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                   }
               }), isSupported(url) {
                result.append(url)
                continue
            }
            guard let type = provider.registeredTypeIdentifiers.compactMap(UTType.init)
                .first(where: { t in fileTypes.contains { t.conforms(to: $0) } }) else { continue }
            let copy: URL? = await withCheckedContinuation { done in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    // The provided file is deleted when this returns; keep a copy.
                    guard let url else { return done.resume(returning: nil) }
                    let dest = scratchFolder().appendingPathComponent(url.lastPathComponent)
                    done.resume(returning: (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil)
                }
            }
            if let copy { result.append(copy) }
        }
        return result
    }

    static func scratchFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Peel Good Intake/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
