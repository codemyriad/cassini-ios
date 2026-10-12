import Foundation
import CassiniNotebook

/// Where a Transcribe, Resume or Start over came from; it decides which queue hold it clears.
public enum StartOrigin: Hashable, Sendable {
    /// A visible screen: clears the user hold, and the system hold on a Resume.
    case screen
    /// A notification action: clears the user hold.
    case notification
    /// The app itself (the enqueue after a recording or an import): clears nothing.
    case automatic
}

/// Why a note cannot be put in the queue.
public enum EnqueueRefusal: Hashable, Sendable {
    case noNote
    /// The note is in Recently Deleted.
    case trashed
    /// The note is still being recorded or saved.
    case recording
    /// The note's document has a format version this build cannot read.
    case unknownFormat
    /// iOS cannot decode the note's audio, so there is nothing to transcribe.
    case unplayable
}

/// The result of a Transcribe, Transcribe again, Resume or Try again.
public enum TranscribeOutcome: Hashable, Sendable {
    /// The note is queued; `changed` is false when it was queued or running already.
    case queued(changed: Bool)
    /// There is no consent to download the speech model: the job waits as "Ready to transcribe" and nothing touched
    /// the network.
    case needsConsent
    case refused(EnqueueRefusal)
}

/// The result of "Remove from queue".
public enum DequeueOutcome: Hashable, Sendable {
    /// The job is gone: the note is "Audio only" again.
    case removed
    /// The note has saved progress: its job is paused by the user and keeps it.
    case paused
    /// The note has no queued job (it may have started meanwhile).
    case notQueued
}

/// The rules of putting a note in the queue that need only the note and its job.
public enum EnqueueRules {
    /// Why `note` cannot be queued, or nil when it can.
    public static func refusal(for note: Note?) -> EnqueueRefusal? {
        guard let note else { return .noNote }
        if note.trashedAt != nil { return .trashed }
        if note.audio == .live { return .recording }
        if note.document?.state == .unknownFormat { return .unknownFormat }
        if case .unplayable = note.audio { return .unplayable }
        return nil
    }

    /// Whether a request from `origin` clears `hold`. A user hold yields to anything the user asks for; a system
    /// hold only to a Resume from a visible screen, so iOS is not asked again for time it just took back.
    public static func clears(_ hold: QueueHold?, origin: StartOrigin, resume: Bool) -> Bool {
        switch hold {
        case .user: origin != .automatic
        case .system: origin == .screen && resume
        case nil: false
        }
    }

    /// The language a job of `kind` is queued with: the chosen speech language for the transcribe kinds; nil (the
    /// job keeps the one it has) for speakers only, which never change the language of the words.
    public static func language(for kind: JobKind, speechLanguage: String) -> String? {
        kind == .speakersOnly ? nil : speechLanguage
    }
}

extension Job {
    /// The job at the back of the queue with `seq`: queued, the failure and pause reason cleared and no automatic
    /// attempts, but the numbers of its saved progress kept, so a Resume starts from them.
    public func requeued(seq: Int, kind: JobKind, language: String?, now: Date) -> Job {
        var job = self
        job.seq = seq
        job.kind = kind
        job.state = .queued
        job.pauseReason = nil
        job.failure = nil
        job.attempts = 0
        if let language { job.language = language }
        job.updatedAt = now
        return job
    }
}

extension NoteStatus {
    /// The coarse status written into `note.json` for older readers, for a note whose job is `job` (nil when it has
    /// none).
    public static func mirroring(_ job: Job?, hasTranscript: Bool) -> NoteStatus {
        switch job?.state {
        case .queued: .queued
        case .running: .transcribing
        case .failed: .failed
        case .paused, .needsConsent, nil: hasTranscript ? .ready : .audioOnly
        }
    }
}
