import AppKit

/// A modal raised directly inside a Task holds the main queue until someone answers, and everything on
/// the main actor stops with it, remote printing included. From a run loop block, as after a click, it
/// doesn't. Use this for any alert a Task raises. It waits its turn behind a modal already open.
@MainActor
enum ModalAlert {
    static func run<T: Sendable>(_ modal: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { done in
            RunLoop.main.perform { MainActor.assumeIsolated { done.resume(returning: modal()) } }
        }
    }

    static func show(_ error: Error) async {
        _ = await run { NSAlert(error: error).runModal() }
    }
}
