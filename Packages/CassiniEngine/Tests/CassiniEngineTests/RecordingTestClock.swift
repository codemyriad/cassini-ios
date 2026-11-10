import Foundation
import Synchronization
import CassiniEngine

/// Recording's test scheduler: sleeps register deadlines, and the harness advances to the next
/// deadline only while waiting for an actual controller event. No policy tick uses elapsed host time.
final class RecordingTestClock: AppClock {
    private struct Sleep {
        var id: UUID
        var deadline: Date
        var continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var now: Date
        var closed = false
        var sleeps: [Sleep] = []
    }
    private final class Cancellation: Sendable { let value = Mutex(false) }
    private let state: Mutex<State>

    init(now: Date) { state = Mutex(State(now: now)) }
    var now: Date { state.withLock { $0.now } }

    func sleep(for duration: Duration) async throws {
        let id = UUID(), cancelled = Cancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let rejected = state.withLock { s -> Bool in
                    guard !s.closed, !cancelled.value.withLock({ $0 }) else { return true }
                    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                    s.sleeps.append(Sleep(id: id, deadline: s.now.addingTimeInterval(seconds), continuation: continuation))
                    return false
                }
                if rejected { continuation.resume(throwing: CancellationError()) }
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

    func advanceToNextSleep() {
        let ready = state.withLock { s -> [Sleep] in
            guard let next = s.sleeps.map(\.deadline).min() else { return [] }
            s.now = max(s.now, next)
            let ready = s.sleeps.filter { $0.deadline <= s.now }
            s.sleeps.removeAll { $0.deadline <= s.now }
            return ready
        }
        for sleep in ready { sleep.continuation.resume() }
    }

    func cancelAll() {
        let pending = state.withLock { s -> [Sleep] in
            s.closed = true
            let pending = s.sleeps
            s.sleeps = []
            return pending
        }
        for sleep in pending { sleep.continuation.resume(throwing: CancellationError()) }
    }
}
