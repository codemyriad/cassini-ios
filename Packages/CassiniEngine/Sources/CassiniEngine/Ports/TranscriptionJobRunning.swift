import Foundation
import CassiniNotebook

public enum JobEvent: Hashable, Sendable {
    case phase(ProcessingPhase)
    case progress(doneMs: Int64, totalMs: Int64?)
    case words(Int)
    /// Words so far; those from `tentativeFromMs` on may still change.
    case draft(words: [TimedWord], tentativeFromMs: Int64)
}

public enum JobOutcome: Hashable, Sendable {
    /// The transcript is saved in the note.
    case done
    /// The checkpoint is saved when there was progress to save.
    case paused(PauseReason)
    case failed(JobFailure)
}

/// One run of one job, from the audio to the saved transcript.
public protocol TranscriptionJobRunning: Sendable {
    func run(_ job: Job, events: @escaping @Sendable (JobEvent) -> Void) async -> JobOutcome
}
