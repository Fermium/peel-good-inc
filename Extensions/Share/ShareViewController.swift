// Share extension: "Peel Good Inc." in the Share menu of Finder, Preview, Safari and others.
// Copies the shared items into the extension's container, hands them to the app
// (which prints them on the default printer) and finishes immediately.
// Built with Sources/PeelGoodShared/AppIdentity.swift for the bundle ID (see scripts/make-app.sh).
import AppKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handOff() }
    }

    private func handOff() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var files: [URL] = []
        for provider in providers {
            if let url = await copy(provider) { files.append(url) }
        }
        if !files.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppIdentity.bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.open(files, withApplicationAt: app, configuration: config)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func copy(_ provider: NSItemProvider) async -> URL? {
        let wanted: [UTType] = [.pdf, .svg, .image]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let source: URL? = await withCheckedContinuation { done in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    done.resume(returning: (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                }
            }
            if let source {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let dest = folder.appendingPathComponent(source.lastPathComponent)
                if (try? FileManager.default.copyItem(at: source, to: dest)) != nil { return dest }
            }
        }
        guard let type = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            .first(where: { t in wanted.contains { t.conforms(to: $0) } }) else { return nil }
        return await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return done.resume(returning: nil) }
                let dest = folder.appendingPathComponent(url.lastPathComponent)
                done.resume(returning: (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil)
            }
        }
    }
}
