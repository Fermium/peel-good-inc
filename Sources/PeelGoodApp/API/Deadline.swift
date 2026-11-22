import Foundation

/// Main-actor work with a time limit. The timer runs on the main queue, not on the Swift concurrency pool, so it
/// fires even when that pool is busy (issue #6). Work that runs over is cancelled and its result dropped.
@MainActor
enum Deadline {
    static func run<T: Sendable>(_ seconds: TimeInterval, orThrow timeout: @autoclosure () -> Error,
                                 _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let timeout = timeout()
        let box = Box<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
                box.continuation = done
                box.task = Task { @MainActor in
                    do { box.finish(.success(try await work())) } catch { box.finish(.failure(error)) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    MainActor.assumeIsolated {
                        box.task?.cancel()
                        box.finish(.failure(timeout))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in box.task?.cancel() }
        }
    }

    private final class Box<T: Sendable> {
        var continuation: CheckedContinuation<T, Error>?
        var task: Task<Void, Never>?
        func finish(_ result: Result<T, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
