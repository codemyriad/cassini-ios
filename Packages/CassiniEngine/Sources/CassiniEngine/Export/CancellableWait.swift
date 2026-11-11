import Foundation
import Synchronization

/// Waits for independently owned work. Cancellation ends only the wait; the operation keeps running.
public enum CancellableWait {
    public static func run(_ operation: @escaping @Sendable () async -> Void) async throws {
        try Task.checkCancellation()
        let completion = Completion()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if completion.install(continuation) {
                    Task { await operation(); completion.finish() }
                } else {
                    continuation.resume(throwing: CancellationError())
                }
            }
            try Task.checkCancellation()
        } onCancel: { completion.cancel() }
    }

    private final class Completion: Sendable {
        private struct State {
            var cancelled = false
            var waiter: CheckedContinuation<Void, any Error>?
        }
        private let state = Mutex(State())
        func install(_ waiter: CheckedContinuation<Void, any Error>) -> Bool {
            state.withLock { state in
                guard !state.cancelled else { return false }
                state.waiter = waiter
                return true
            }
        }
        func finish() {
            let waiter = state.withLock { state in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
        func cancel() {
            let waiter = state.withLock { state in
                state.cancelled = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
