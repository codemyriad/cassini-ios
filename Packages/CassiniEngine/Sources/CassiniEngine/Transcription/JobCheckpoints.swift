import Foundation
import CassiniNotebook

/// What a note's `work/` directory holds for its job.
public enum CheckpointStatus: Hashable, Sendable {
    /// No saved progress.
    case missing
    /// Progress saved up to `doneMs` of `totalMs`, with `words` words so far.
    case saved(doneMs: Int64, totalMs: Int64, words: Int)
    /// Saved progress that no longer matches the audio or the model: it cannot be resumed.
    case mismatch
}

/// The saved progress of jobs, in each note's `work/` directory. The transcription job writes it; the queue reads its
/// numbers, discards it for Start over and deletes it when no job owns it.
public protocol JobCheckpoints: Sendable {
    func status(of noteID: UUID) async -> CheckpointStatus
    /// Deletes the note's `work/` directory and everything in it.
    func discard(_ noteID: UUID) async throws
    /// Notes that have a `work/` directory.
    func notesWithWork() async -> Set<UUID>
    /// The speech language the note's saved progress began in (`CheckpointState.appleLanguage`); nil without saved
    /// progress or for a recognizer that is given none.
    func language(of noteID: UUID) async -> String?
    func recognizer(of noteID: UUID) async -> String?
}

extension JobCheckpoints {
    public func language(of noteID: UUID) async -> String? { nil }
    public func recognizer(of noteID: UUID) async -> String? { nil }
}

extension Job {
    /// The job with the numbers of `checkpoint`: its done and total audio and its words, or none without one.
    public func withNumbers(of checkpoint: CheckpointStatus) -> Job {
        var job = self
        if case .saved(let doneMs, let totalMs, let words) = checkpoint {
            job.doneMs = doneMs; job.totalMs = totalMs; job.words = words
        } else {
            job.doneMs = 0; job.words = 0
        }
        return job
    }
}
