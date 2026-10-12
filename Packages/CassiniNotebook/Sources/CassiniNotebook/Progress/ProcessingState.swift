import Foundation

/// The step a running job is in.
public enum ProcessingPhase: Hashable, Sendable {
    case starting
    /// A model download; the fraction is nil while its size is unknown.
    case downloading(Double?)
    case transcribing
    case preparingSpeakers(Double?)
    case identifyingSpeakers
    case matching
    case saving
    case stopping
}

public struct RunningJob: Hashable, Sendable {
    public var noteID: UUID
    public var title: String
    public var phase: ProcessingPhase
    /// Overall progress, nil while unknown.
    public var fraction: Double?
    public init(noteID: UUID, title: String, phase: ProcessingPhase = .starting, fraction: Double? = nil) {
        self.noteID = noteID; self.title = title; self.phase = phase; self.fraction = fraction
    }
}

/// What the transcription queue is doing, as the screens see it.
public struct ProcessingState: Hashable, Sendable {
    public var running: RunningJob?
    /// Waiting notes in the order they will run.
    public var queue: [UUID]
    public var hold: QueueHold?
    /// The job of each note that has one.
    public var jobs: [UUID: Job]

    public init(running: RunningJob? = nil, queue: [UUID] = [], hold: QueueHold? = nil, jobs: [UUID: Job] = [:]) {
        self.running = running; self.queue = queue; self.hold = hold; self.jobs = jobs
    }

    public func isQueued(_ id: UUID) -> Bool { queue.contains(id) }
    public func isRunning(_ id: UUID) -> Bool { running?.noteID == id }
    /// Jobs that run before this note's, counting the running one.
    public func ahead(of id: UUID) -> Int? {
        queue.firstIndex(of: id).map { $0 + (running == nil ? 0 : 1) }
    }
}
