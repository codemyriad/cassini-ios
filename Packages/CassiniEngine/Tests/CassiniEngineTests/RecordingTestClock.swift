import Foundation
import Synchronization
import CassiniEngine

/// Recording's test scheduler: sleeps register deadlines, and the harness advances to the next
/// deadline while waiting for an actual controller event, or moves exact virtual ticks for ordering checks.
/// No policy tick uses elapsed host time.
final class RecordingTestClock: AppClock {
    private struct Sleep {
        var id: UUID
        var deadline: Duration
        var duration: Duration
        var continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var origin: Date
        var elapsed: Duration = .zero
        var cancelled: Set<UUID> = []
        var closed = false
        var sleeps: [Sleep] = []
    }
    private final class Cancellation: Sendable { let value = Mutex(false) }
    private let state: Mutex<State>

    init(now: Date) { state = Mutex(State(origin: now)) }
    var now: Date { state.withLock { $0.origin.addingTimeInterval(Self.seconds($0.elapsed)) } }
    var pendingSleeps: Int { state.withLock { $0.sleeps.count } }

    func pendingSleepIDs(for duration: Duration) -> Set<UUID> {
        state.withLock { Set($0.sleeps.filter { $0.duration == duration }.map(\.id)) }
    }
    var cancelledSleepIDs: Set<UUID> { state.withLock { $0.cancelled } }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID(), cancelled = Cancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let rejected = state.withLock { s -> Bool in
                    guard !s.closed, !cancelled.value.withLock({ $0 }) else { return true }
                    s.sleeps.append(Sleep(id: id, deadline: s.elapsed + duration, duration: duration, continuation: continuation))
                    return false
                }
                if rejected { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            cancelled.value.withLock { $0 = true }
            let continuation = self.state.withLock { s -> CheckedContinuation<Void, Error>? in
                guard let index = s.sleeps.firstIndex(where: { $0.id == id }) else { return nil }
                s.cancelled.insert(id)
                return s.sleeps.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }

    func advanceToNextSleep() {
        let ready = state.withLock { s -> [Sleep] in
            guard let next = s.sleeps.map(\.deadline).min() else { return [] }
            s.elapsed = max(s.elapsed, next)
            let ready = s.sleeps.filter { $0.deadline <= s.elapsed }
            s.sleeps.removeAll { $0.deadline <= s.elapsed }
            return ready
        }
        for sleep in ready { sleep.continuation.resume() }
    }

    /// Move by an explicit virtual interval rather than jumping to the next pending deadline.
    func advance(by duration: Duration) {
        precondition(duration >= .zero)
        let ready = state.withLock { s -> [Sleep] in
            s.elapsed += duration
            let ready = s.sleeps.filter { $0.deadline <= s.elapsed }
            s.sleeps.removeAll { $0.deadline <= s.elapsed }
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
