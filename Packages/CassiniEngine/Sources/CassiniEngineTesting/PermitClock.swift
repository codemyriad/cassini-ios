#if DEBUG
import Foundation
import Synchronization
import CassiniEngine

/// A fake pacing clock. Each permit releases one sleep and advances virtual time by that sleep's
/// duration. Unused permits wait for future sleeps, so a UI command can request exactly K results.
public final class PermitClock: AppClock {
    private struct Sleep {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var now: Date
        var permits = 0
        var sleeps: [Sleep] = []
    }
    private final class Cancellation: Sendable { let value = Mutex(false) }
    private let state: Mutex<State>
    private let onWaiting: @Sendable () -> Void

    public init(now: Date, onWaiting: @escaping @Sendable () -> Void = {}) {
        state = Mutex(State(now: now))
        self.onWaiting = onWaiting
    }

    public var now: Date { state.withLock { $0.now } }

    public func sleep(for duration: Duration) async throws {
        let id = UUID(), cancelled = Cancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result = state.withLock { s -> Int in
                    if cancelled.value.withLock({ $0 }) { return -1 }
                    if s.permits > 0 {
                        s.permits -= 1
                        s.now += Self.seconds(duration)
                        return 1
                    }
                    s.sleeps.append(Sleep(id: id, duration: duration, continuation: continuation))
                    return 0
                }
                switch result {
                case -1: continuation.resume(throwing: CancellationError())
                case 1: continuation.resume()
                default: onWaiting()
                }
            }
        } onCancel: {
            cancelled.value.withLock { $0 = true }
            let continuation = self.state.withLock { s -> CheckedContinuation<Void, Error>? in
                guard let index = s.sleeps.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleeps.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }

    public func grant(_ count: Int) {
        precondition(count >= 0)
        let released = state.withLock { s -> [Sleep] in
            s.permits += count
            let count = min(s.permits, s.sleeps.count)
            let released = Array(s.sleeps.prefix(count))
            s.sleeps.removeFirst(count)
            s.permits -= count
            for sleep in released { s.now += Self.seconds(sleep.duration) }
            return released
        }
        for sleep in released { sleep.continuation.resume() }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
#endif
