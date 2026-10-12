import Foundation
import Synchronization
import CassiniNotebook

/// Why the coordinator wants a running job to stop.
public enum StopRequest: Hashable, Sendable {
    /// Keep the work: save a checkpoint and end as `JobOutcome.paused(reason)`.
    case pause(PauseReason)
    /// Drop the work (Start over, Recently Deleted): end as `JobOutcome.cancelled`.
    case cancel
}

/// Set by the coordinator, read by the job at its checkpoints. A cancel replaces a pause; a pause never replaces a
/// cancel.
public final class StopSignal: Sendable {
    private let state = Mutex<StopRequest?>(nil)

    public init() {}

    public var request: StopRequest? { state.withLock { $0 } }

    public func stop(_ request: StopRequest) {
        state.withLock { current in
            if current != .cancel { current = request }
        }
    }
}

/// One run of one job, from the audio to the saved transcript. `events` is called in order from any thread; the
/// coordinator forwards them to a single consumer so they are applied in that order.
public protocol TranscriptionJobRunning: Sendable {
    func run(_ job: Job, stop: StopSignal, events: @escaping @Sendable (JobEvent) -> Void) async -> JobOutcome
}
