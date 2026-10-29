import Foundation
import Synchronization

/// Native work cannot always stop mid-call (Android's `NativeBudget`). Whoever loads native models (Parakeet, the
/// speech detector, Sortformer, CAM++) holds this budget until they are released again, so a cancelled job's models
/// leave memory before the next job loads its own. One holder at a time, served in the order they asked.
///
/// A job holds it for its decode, during which Parakeet and the streaming diarizer are loaded together as on Android
/// (the voiceprint model loads only after the decode, under a hold of its own), and for a whole-file speaker analysis.
/// While another holds it the job shows "Finishing the previous note…" (`JobEvent.waitingForPrevious`). Waiting can be
/// cancelled: the waiter then stops with `CancellationError` and takes nothing.
public final class NativeBudget: Sendable {
    /// The process's budget.
    public static let shared = NativeBudget()

    private struct State {
        var held = false
        var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Whether someone holds the budget now.
    public var isHeld: Bool { state.withLock { $0.held } }

    /// Runs `body` while holding the budget; the budget is given back however `body` ends.
    public func withBudget<Value>(_ body: () async throws -> Value) async throws -> Value {
        try await acquire()
        defer { release() }
        return try await body()
    }

    /// Takes the budget once it is free, after everyone who asked before. A cancelled task stops waiting with
    /// `CancellationError`; one that is cancelled already does not take a free budget. Pair with `release`.
    public func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Start { case taken, waiting, cancelled }
                let start = state.withLock { state -> Start in
                    if !state.held {
                        state.held = true
                        return .taken
                    }
                    // A cancel that came before the wait was set up finds no waiter to end.
                    if Task.isCancelled { return .cancelled }
                    state.waiters.append((id, continuation))
                    return .waiting
                }
                switch start {
                case .taken: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .waiting: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Gives the budget back: to the first waiter, or free.
    public func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard !state.waiters.isEmpty else {
                state.held = false
                return nil
            }
            return state.waiters.removeFirst().continuation
        }
        next?.resume()
    }
}
