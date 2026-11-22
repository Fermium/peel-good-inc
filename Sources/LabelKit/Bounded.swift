import Dispatch
import Foundation

/// Blocking work (Vision, Spotlight, PDF parsing) with a time limit, run on Dispatch queues and never on the
/// Swift concurrency pool. That pool has one thread per core; a few calls that never return used to take all of
/// it, and every `await` in the app stopped with them (issue #6: Vision text recognition stuck on a batch of photos).
public enum Bounded {
    /// Runs `work` on `queue` and returns its result, or `fallback()` once `limit` seconds pass. Work that
    /// runs over keeps going on its queue; its result is dropped.
    public static func run<T: Sendable>(on queue: DispatchQueue, limit: TimeInterval,
                                        _ work: @escaping @Sendable () -> T,
                                        fallback: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            let once = Once(done)
            queue.async { once.resume(work()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) { once.resume(fallback()) }
        }
    }

    /// The same, for synchronous callers that aren't on the Swift concurrency pool (a Dispatch queue, the CLI).
    /// Returns nil once `limit` seconds pass.
    public static func wait<T: Sendable>(on queue: DispatchQueue, limit: TimeInterval, _ work: @escaping @Sendable () -> T) -> T? {
        let box = Box<T>()
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            box.value = work()
            finished.signal()
        }
        return finished.wait(timeout: .now() + limit) == .success ? box.value : nil
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        init(_ c: CheckedContinuation<T, Never>) { continuation = c }
        func resume(_ value: T) {
            let c = lock.withLock { () -> CheckedContinuation<T, Never>? in
                defer { continuation = nil }
                return continuation
            }
            c?.resume(returning: value)
        }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}

/// A framework call that has hung once may hang every time (Vision's detectors queue behind the stuck one), so a
/// `Lane` stops calling it while a call that ran over is still out, and starts again once that call returns.
/// At most one call per lane is left hanging.
public final class Lane: @unchecked Sendable {
    public let name: String
    public let limit: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var overdue = 0

    public init(_ name: String, limit: TimeInterval) {
        self.name = name
        self.limit = limit
        queue = DispatchQueue(label: "PeelGood.\(name)", qos: .userInitiated, attributes: .concurrent)
    }

    /// True while a call that ran over hasn't returned.
    public var isStuck: Bool { lock.withLock { overdue > 0 } }

    /// `work`'s result, or nil when it ran over `limit` or the lane is stuck. Blocks the caller, so call it from a
    /// Dispatch queue or a thread, never from async code.
    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T? {
        if isStuck { return nil }
        let state = Call()
        let result = Bounded.wait(on: queue, limit: limit) { [self] () -> T in
            let value = work()
            if state.finish() { lock.withLock { overdue -= 1 } }
            return value
        }
        if result == nil, state.giveUp() { lock.withLock { overdue += 1 } }
        return result
    }

    /// Whether the call finished or was given up on first.
    private final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false, abandoned = false
        /// True when the call had been given up on (so it was counted overdue).
        func finish() -> Bool { lock.withLock { finished = true; return abandoned } }
        /// True when the call hasn't finished yet (so count it overdue).
        func giveUp() -> Bool { lock.withLock { if finished { return false }; abandoned = true; return true } }
    }
}
