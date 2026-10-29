import AppKit
import UniformTypeIdentifiers

/// Turns whatever arrives (drops, the clipboard, Services, item providers) into files on disk.
/// Real files are used in place; promised files (screenshot thumbnails, browsers, Mail) are
/// received into a temporary folder; raw PDF or image data is written to a temporary file.
enum Intake {
    static let fileTypes: [UTType] = [.pdf, .svg, .image]

    static let dataTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.pdf, "pdf"), (.png, "png"), (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
        (NSPasteboard.PasteboardType(UTType.svg.identifier), "svg"), (.tiff, "tiff"),
    ]

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
            .appendingPathComponent("Labelize Intake/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
