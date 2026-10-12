#if DEBUG
import Foundation
import Synchronization
import CassiniEngine
import CassiniNotebook

/// A job runner whose runs the test ends. Each `run` is a `FakeJobRun` in `runs`, in the order the coordinator started
/// them. A run pauses at once when it is asked to stop, unless its `pauseOnStop` is off; a cancel always ends it.
public final class FakeJobRunner: TranscriptionJobRunning {
    private let started = Mutex<[FakeJobRun]>([])

    public init() {}

    public var runs: [FakeJobRun] { started.withLock { $0 } }

    public func run(_ job: Job, stop: StopSignal, events: @escaping @Sendable (JobEvent) -> Void) async -> JobOutcome {
        let run = FakeJobRun(job: job, stop: stop, events: events)
        started.withLock { $0.append(run) }
        let outcome = await run.outcome()
        events(.ended(outcome))
        run.markEnded()
        return outcome
    }

    /// The run with `index`, once the coordinator has started it.
    public func run(_ index: Int, timeout: Duration = .seconds(10)) async throws -> FakeJobRun {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let run = runs.dropFirst(index).first { return run }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FakeTimeout()
    }
}

public struct FakeTimeout: Error {
    public init() {}
}

/// One run of `FakeJobRunner`.
public final class FakeJobRun: Sendable {
    private struct State {
        var outcome: JobOutcome?
        var pauseOnStop = true
        var ended = false
    }

    public let job: Job
    public let stop: StopSignal
    private let events: @Sendable (JobEvent) -> Void
    private let state = Mutex(State())

    init(job: Job, stop: StopSignal, events: @escaping @Sendable (JobEvent) -> Void) {
        self.job = job; self.stop = stop; self.events = events
    }

    public var noteID: UUID { job.noteID }
    public var stopRequest: StopRequest? { stop.request }
    public var hasEnded: Bool { state.withLock { $0.ended } }

    /// Whether a stop ends the run at once; off, the run goes on until `finish`, as a job between checkpoints does.
    public var pauseOnStop: Bool {
        get { state.withLock { $0.pauseOnStop } }
        set { state.withLock { $0.pauseOnStop = newValue } }
    }

    public func finish(_ outcome: JobOutcome) { state.withLock { if $0.outcome == nil { $0.outcome = outcome } } }

    /// Sends `event` to the coordinator.
    public func send(_ event: JobEvent) { events(event) }

    fileprivate func markEnded() { state.withLock { $0.ended = true } }

    fileprivate func outcome() async -> JobOutcome {
        while true {
            let (outcome, pauses) = state.withLock { ($0.outcome, $0.pauseOnStop) }
            if let outcome { return outcome }
            switch stop.request {
            case .cancel: return .cancelled
            case .pause(let reason) where pauses: return .paused(reason)
            case .pause, nil: break
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
#endif
