import Foundation

/// The stage the transcription pipeline is in. `words` and `speakers` are one step on the progress card.
public enum TranscriptionStage: String, CaseIterable, Hashable, Sendable {
    case reading, preparing, words, speakers, matching, saving
}

/// One word of a running job's draft: the raw speaker id (no merges) and times on the recording clock.
/// The same fields as CassiniCore's `Word`, which is not `Sendable`.
public struct DraftWord: Hashable, Sendable {
    public var speaker: String
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    public var lowConfidenceSpeaker: Bool?
    public init(speaker: String, startMs: Int64, endMs: Int64, text: String, lowConfidenceSpeaker: Bool? = nil) {
        self.speaker = speaker; self.startMs = startMs; self.endMs = endMs; self.text = text
        self.lowConfidenceSpeaker = lowConfidenceSpeaker
    }
}

/// One part of a model install. While `verifying`, the counts are the share of files already checked; otherwise the
/// bytes downloaded.
public struct DownloadProgress: Hashable, Sendable {
    public var part: ModelPart
    public var doneBytes: Int64
    public var totalBytes: Int64
    public var verifying: Bool
    public init(part: ModelPart, doneBytes: Int64, totalBytes: Int64, verifying: Bool) {
        self.part = part; self.doneBytes = doneBytes; self.totalBytes = totalBytes; self.verifying = verifying
    }

    /// Whole percent of `totalBytes`, 0 to 100.
    public var percent: Int {
        totalBytes <= 0 ? 0 : Int(min(max(doneBytes, 0), totalBytes) * 100 / totalBytes)
    }
}

/// A required model that a job could not install. The job's stored failure is `JobFailure.download(error)`;
/// `requiredFreeBytes` is what the space check asked for ("Free about N MB").
public struct DownloadFailure: Hashable, Sendable {
    public var error: DownloadError
    public var part: ModelPart
    public var requiredFreeBytes: Int64
    public init(error: DownloadError, part: ModelPart, requiredFreeBytes: Int64 = 0) {
        self.error = error; self.part = part; self.requiredFreeBytes = requiredFreeBytes
    }
}

/// The checkpoint a resumed run starts from: done and total audio, its draft words and its elapsed time.
public struct RestoredCheckpoint: Hashable, Sendable {
    public var doneMs: Int64
    public var totalMs: Int64
    public var words: [DraftWord]
    public var elapsedMs: Int64
    public init(doneMs: Int64, totalMs: Int64, words: [DraftWord], elapsedMs: Int64) {
        self.doneMs = doneMs; self.totalMs = totalMs; self.words = words; self.elapsedMs = elapsedMs
    }
}

/// What a run knows when inference begins.
public struct JobStart: Hashable, Sendable {
    /// 0 when unknown.
    public var totalMs: Int64
    /// Set when the run resumes from a checkpoint.
    public var restored: RestoredCheckpoint?
    /// A diarizer is installed and has not failed.
    public var speakers: Bool
    /// The voiceprint model is installed.
    public var prints: Bool
    /// The memory check flagged the device.
    public var lowMemory: Bool
    /// The Matching step can still run in this run; `JobEvent.namingClosed` gives the final answer.
    public var matching: Bool

    public init(totalMs: Int64, restored: RestoredCheckpoint? = nil, speakers: Bool, prints: Bool,
                lowMemory: Bool = false, matching: Bool? = nil) {
        self.totalMs = totalMs; self.restored = restored; self.speakers = speakers; self.prints = prints
        self.lowMemory = lowMemory; self.matching = matching ?? (prints && speakers)
    }
}

/// How one run of a job ended.
public enum JobOutcome: Hashable, Sendable {
    /// The transcript is saved in the note.
    case done
    /// The transcript is complete and sealed, but putting it in the note failed; the coordinator finishes that as
    /// reconcile does and never shows the note as failed.
    case adoptPending
    /// The checkpoint is saved when there was progress to save.
    case paused(PauseReason)
    case failed(JobFailure)
    /// A required model could not be installed; stored as `JobFailure.download(failure.error)`.
    case downloadFailed(DownloadFailure)
    /// No consent to download the `missingBytes` the job needs; nothing was downloaded.
    case needsConsent(missingBytes: Int64)
    /// Stopped for Start over or Recently Deleted; the coordinator discards the job's work.
    case cancelled
}

/// What a running job reports, in the order it happens. Times are on the recording clock.
public enum JobEvent: Hashable, Sendable {
    /// A cancelled job still holds the speech engine ("Finishing the previous note…").
    case waitingForPrevious
    /// Models are being installed; nil until the first byte or check is reported.
    case downloading(DownloadProgress?)
    /// Inference begins.
    case started(JobStart)
    /// The pipeline entered `stage` for the window `startMs..<endMs` (0..<0 when it has none).
    case stageChanged(TranscriptionStage, startMs: Int64 = 0, endMs: Int64 = 0)
    /// The decoder has read `readMs` of the audio; `totalMs` once the file tells it.
    case reading(readMs: Int64, totalMs: Int64?)
    /// A window was decoded: `doneMs` of `totalMs`, and every draft word so far.
    case windowDone(doneMs: Int64, totalMs: Int64, words: [DraftWord])
    /// Words from `tentativeFromMs` on may still change.
    case draft(words: [DraftWord], tentativeFromMs: Int64)
    /// A checkpoint covering `doneMs` was saved.
    case checkpointed(doneMs: Int64)
    /// Speakers could not be told apart: every word is one voice from now on.
    case speakersUnavailable
    /// Naming closed; `matching` tells whether the Matching step runs next.
    case namingClosed(matching: Bool)
    /// A stop was asked and the job is winding down.
    case stopping
    case ended(JobOutcome)
}
