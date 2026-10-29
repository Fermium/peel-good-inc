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

/// The watched folders, as a compact row of chips above the rules.
struct WatchedFoldersRow: View {
    @ObservedObject var watcher = FolderWatcher.shared

    var body: some View {
        HStack(spacing: 6) {
            Text("Watch").foregroundStyle(.secondary)
            if watcher.folders.isEmpty {
                Text("No folders").foregroundStyle(.tertiary)
            }
            ForEach(watcher.folders, id: \.self) { folder in
                HStack(spacing: 4) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 14, height: 14)
                    Text(folder.lastPathComponent)
                    Button { watcher.folders.removeAll { $0 == folder } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop watching \(folder.lastPathComponent)")
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .help(folder.path)
            }
            Button { add() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Watch a folder")
            Spacer()
        }
        .font(.callout)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url, !watcher.folders.contains(url) else { return }
        watcher.folders.append(url)
    }
}
