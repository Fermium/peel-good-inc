import AppKit
import CoreServices
import CryptoKit
import SwiftUI
import UserNotifications

/// Watches folders (not their subfolders) for new printable files and hands each one over once:
/// after it has finished downloading, and never the same contents twice.
@MainActor
final class FolderWatcher: ObservableObject {
    static let shared = FolderWatcher()

    @Published var folders: [URL] {
        didSet {
            UserDefaults.standard.set(folders.map(\.path), forKey: "watchedFolders")
            restart()
        }
    }

    var onFile: (URL) -> Void = { _ in }

    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private var seen: [String]
    private static let partial: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]

    private init() {
        folders = (UserDefaults.standard.stringArray(forKey: "watchedFolders") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        seen = UserDefaults.standard.stringArray(forKey: "watchedSeen") ?? []
    }

    func start() { restart() }

    private func restart() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
            MainActor.assumeIsolated { watcher.handle(list, flagList) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, folders.map(\.path) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        guard let stream else {
            Log.error(.files, "couldn't watch \(folders.map(\.path).joined(separator: ", "))")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        Log.info(.files, "watching \(folders.map(\.lastPathComponent).joined(separator: ", "))")
    }

    private func handle(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let watched = Set(folders.map { $0.standardizedFileURL.path })
        for (path, flag) in zip(paths, flags) {
            let isFile = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0
            let arrived = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
            let url = URL(fileURLWithPath: path)
            guard isFile, arrived, watched.contains(url.deletingLastPathComponent().standardizedFileURL.path),
                  !url.lastPathComponent.hasPrefix("."), !Self.partial.contains(url.pathExtension.lowercased()),
                  Intake.isSupported(url), FileManager.default.fileExists(atPath: path), !pending.contains(path) else { continue }
            pending.insert(path)
            Task { await settle(url) }
        }
    }

    /// Waits until the size stops changing, then hands the file over unless it's been seen.
    private func settle(_ url: URL) async {
        defer { pending.remove(url.path) }
        var last = -1
        for _ in 0..<90 {
            try? await Task.sleep(for: .milliseconds(700))
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            if size > 0 && size == last { break }
            last = size
        }
        guard let hash = await Task.detached(priority: .utility, operation: { Self.sha256(url) }).value else { return }
        guard !seen.contains(hash) else {
            Log.info(.files, "\(url.lastPathComponent) arrived again, already handled")
            return
        }
        seen.append(hash)
        if seen.count > 500 { seen.removeFirst(seen.count - 500) }
        UserDefaults.standard.set(seen, forKey: "watchedSeen")
        Log.info(.files, "new file in \(url.deletingLastPathComponent().lastPathComponent): \(url.lastPathComponent)")
        onFile(url)
    }
}

extension FolderWatcher {
    /// SHA-256 of a file, read in 1 MB chunks.
    nonisolated static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// "Label ready" notifications with Print and Preview buttons, for files that arrive on their own.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onAction: (URL, _ print: Bool) -> Void = { _, _ in }

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let print = UNNotificationAction(identifier: "print", title: "Print", options: [])
        let preview = UNNotificationAction(identifier: "preview", title: "Preview", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "label", actions: [print, preview], intentIdentifiers: [])])
    }

    func ask(_ url: URL, detail: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { Log.error(.files, "notifications: \(error.localizedDescription)") }
            guard granted else {
                Log.warning(.files, "notifications are off; open Peel Good Inc. to print \(url.lastPathComponent)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = url.lastPathComponent
            content.body = detail
            content.categoryIdentifier = "label"
            content.userInfo = ["path": url.path]
            center.add(UNNotificationRequest(identifier: url.path, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        let print = response.actionIdentifier == "print"
        await MainActor.run { onAction(URL(fileURLWithPath: path), print) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Rules > Watched Folders: the folders, + and −, and what new files do when no rule says otherwise.
struct WatchedFoldersSection: View {
    enum Folders {
        /// `FolderWatcher.shared`, saved and watched.
        case live
        /// A fixed list kept in memory (screenshots, previews).
        case preview([URL])
    }

    let folders: Folders
    let store: Store?
    @ObservedObject private var watcher = FolderWatcher.shared
    @State private var previewList: [URL] = []
    @State private var selection: URL?

    init(folders: Folders, store: Store?) {
        self.folders = folders
        self.store = store
    }

    private var list: [URL] {
        if case .live = folders { return watcher.folders }
        return previewList
    }

    private func set(_ urls: [URL]) {
        if case .live = folders { watcher.folders = urls } else { previewList = urls }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Watched Folders").font(.headline)
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(list, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 18, height: 18)
                            Text(folder.lastPathComponent)
                            Text((folder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .help(folder.path)
                        .tag(folder)
                    }
                    if list.isEmpty {
                        Text("No folders. Click + to watch one.")
                            .font(.callout).foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(height: 74)
                .onDeleteCommand(perform: removeSelected)
                Divider()
                HStack(spacing: 0) {
                    Button(action: add) { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("Watch a folder").accessibilityLabel("Add Folder")
                    Divider().frame(height: 16)
                    Button(action: removeSelected) { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil)
                        .help("Stop watching the selected folder").accessibilityLabel("Remove Folder")
                    Spacer()
                    if let store { NewFilesPicker(store: store) }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            Text("New files in these folders go through the rules. Ask sends a notification with Print and Preview.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if case .preview(let urls) = folders { previewList = urls } }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url, !list.contains(url) else { return }
        set(list + [url])
    }

    private func removeSelected() {
        guard let selection else { return }
        set(list.filter { $0 != selection })
        self.selection = nil
    }
}

/// "New files: Ask / Print / Show preview", the default for watched folders.
private struct NewFilesPicker: View {
    @ObservedObject var store: Store

    var body: some View {
        Picker("New files", selection: Binding(get: { store.newFilesAction }, set: { store.newFilesAction = $0 })) {
            Text(RuleAction.ask.title).tag(RuleAction.ask)
            Text(RuleAction.print.title).tag(RuleAction.print)
            Text(RuleAction.review.title).tag(RuleAction.review)
        }
        .fixedSize()
        .font(.callout)
    }
}
