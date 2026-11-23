import Foundation
import LabelKit
import os

/// Opening a file can wait on macOS. For Downloads, Desktop, Documents and removable volumes, `open()` doesn't
/// return until the user answers "Peel Good Inc. would like to access files in your Downloads folder". After an
/// update the old answer may no longer apply (an ad-hoc signature changes with every build), so the question comes
/// back, and if nobody is at the Mac it never returns (issue #10: the main thread sat in `open()` for a bot's
/// preview, and the HTTP API and MCP stopped answering).
///
/// So files the app is handed by path are opened here first: on a Dispatch queue, never the main thread or the
/// Swift concurrency pool, with a time limit. While an open in a folder is still out, later checks in that
/// folder answer `.waiting` straight away, so at most one thread per folder is left waiting.
enum FileAccess {
    enum Outcome: Equatable, Sendable {
        case readable
        /// `open()` failed with this errno (EPERM or EACCES when the user said no).
        case failed(Int32)
        /// macOS is still deciding, most likely waiting for the user to answer its prompt.
        case waiting
    }

    /// Seconds to wait for `open()`. Long enough to answer the prompt when someone is there.
    nonisolated(unsafe) static var limit: TimeInterval = 10
    static let queue = DispatchQueue(label: "PeelGood.file-access", qos: .userInitiated, attributes: .concurrent)
    /// Folders (or files) with an open that ran over, and how many are still out.
    private static let overdue = OSAllocatedUnfairLock(initialState: [String: Int]())

    /// Opens `url` for reading and closes it again. A folder is opened as a folder (listing it needs the same say-so).
    static func probe(_ url: URL, limit: TimeInterval = limit) async -> Outcome {
        let key = gate(for: url)
        if overdue.withLock({ ($0[key] ?? 0) > 0 }) { return .waiting }
        let call = Call()
        let path = url.path
        return await Bounded.run(on: queue, limit: limit) {
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            let outcome: Outcome = fd >= 0 ? .readable : .failed(errno)
            if fd >= 0 { close(fd) }
            if call.finish() { overdue.withLock { $0[key, default: 1] -= 1; if $0[key] == 0 { $0[key] = nil } } }
            return outcome
        } fallback: {
            if call.giveUp() { overdue.withLock { $0[key, default: 0] += 1 } }
            return .waiting
        }
    }

    /// Every file, as an API error for the first one that can't be read.
    static func check(_ urls: [URL], limit: TimeInterval = limit) async throws {
        for url in urls {
            let outcome = await probe(url, limit: limit)
            if let error = error(for: url, outcome) {
                Log.warning(.api, "\(url.lastPathComponent): \(error.message)")
                throw error
            }
        }
    }

    static func error(for url: URL, _ outcome: Outcome) -> APIError? {
        let folder = url.deletingLastPathComponent().lastPathComponent
        switch outcome {
        case .readable:
            return nil
        case .waiting:
            return APIError(status: 503, code: "file_access_waiting", message: "macOS hasn't let Peel Good Inc. read files in \u{201C}\(folder)\u{201D} yet. It may be asking on screen: click Allow, or turn on Peel Good Inc. in System Settings > Privacy & Security > Files and Folders. Then try again. Nothing printed.")
        case .failed(let code) where code == EPERM || code == EACCES:
            return APIError(status: 403, code: "file_access_denied", message: "Peel Good Inc. isn't allowed to read files in \u{201C}\(folder)\u{201D}. Turn it on in System Settings > Privacy & Security > Files and Folders, then try again.")
        case .failed(let code):
            return APIError.unprocessable("Couldn't open \(url.lastPathComponent): \(String(cString: strerror(code))).", code: "unreadable")
        }
    }

    /// Files share their folder's gate: macOS asks once per folder.
    private static func gate(for url: URL) -> String {
        let standard = url.standardizedFileURL
        let isFolder = (try? standard.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return (isFolder ? standard : standard.deletingLastPathComponent()).path
    }

    /// Whether the open finished or was given up on first.
    private final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false, abandoned = false
        /// True when the call had been given up on (so it was counted overdue).
        func finish() -> Bool { lock.withLock { finished = true; return abandoned } }
        /// True when the call hasn't finished yet (so count it overdue).
        func giveUp() -> Bool { lock.withLock { if finished { return false }; abandoned = true; return true } }
    }
}
