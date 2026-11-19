import Foundation
import Synchronization

/// Waits for an answer for a while.
public enum TimeLimit {
    /// `work`'s answer, or nil if it takes longer than `limit`. `work` is not stopped: a request cancelled
    /// half way reads as its address failing.
    public static func answer<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once(continuation)
            let timer = Task {
                try? await Task.sleep(for: limit)
                once.resume(nil)
            }
            Task {
                once.resume(await work())
                timer.cancel()
            }
        }
    }
}

/// Resumes a continuation the first time it is asked to, and ignores the rest.
private final class Once<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: T?) {
        continuation.withLock { continuation in
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
