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
    /// The stored queue was written by a newer Cassini, or could not be read or moved aside, so it takes no jobs in
    /// this run (see `JobStore.Failure`).
    case queueUnavailable
    /// The requested speech recognizer cannot run on this device or in this language.
    case speechUnavailable(JobFailure)
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

/// What a screen does once a Transcribe, Transcribe again, Resume, Try again, Start over or Identify speakers has
/// answered, the same for every screen that asks: without consent the model download screen opens over the note
/// (`ScreenStack.offerModelDownload`, or from the Library `show`), and a refusal says why.
public enum TranscribeFollowUp: Hashable, Sendable {
    case none
    case openModelDownload
    case refused(EnqueueRefusal)
}

extension TranscribeOutcome {
    public var followUp: TranscribeFollowUp {
        switch self {
        case .queued: .none
        case .needsConsent: .openModelDownload
        case .refused(let refusal): .refused(refusal)
        }
    }
}

/// What follows a saved recording or import while Transcribe automatically is on, as Android's `AfterFinish`.
public enum HandOff: Hashable, Sendable {
    /// The note is in the queue.
    case queued
    /// The models may not be downloaded yet and the person has not said no: the model download screen asks.
    case askConsent
    /// The note stays audio only: the person declined the download, or the note cannot be queued.
    case audioOnly
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

    /// Whether Cassini coming to the screen resumes what `hold` keeps, as a Resume from the screen would. Only the
    /// system hold, and only on a system without continued processing (iOS 18), where it means nothing but that the
    /// finite background time ran out: there it comes about 30 s after every exit during a transcription. On iOS 26 the
    /// system hold can also be the person's Stop in the system's progress, so it waits for Resume as before. A user hold
    /// never yields to this. Android has no such rule (its system hold is the rare `onTimeout`): a proposal, see
    /// docs/ios18.md.
    public static func resumesOnActivation(_ hold: QueueHold?, platform: PlatformFacts) -> Bool {
        hold == .system && !platform.continuedProcessing
    }

    /// The language a job of `kind` is queued with: the chosen speech language for the transcribe kinds; nil (the
    /// job keeps the one it has) for speakers only, which never change the language of the words.
    public static func language(for kind: JobKind, speechLanguage: String) -> String? {
        kind == .speakersOnly ? nil : speechLanguage
    }
}

extension ProcessingState {
    /// How many notes a hold keeps from starting, for "Transcription paused · N waiting" with Continue; nil when that
    /// notice does not show: nothing holds the queue, nothing waits, or a job still runs (it shows its own Stop).
    public var heldWaiting: Int? {
        guard hold != nil, running == nil, !queue.isEmpty else { return nil }
        return queue.count
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

/// When a failed run may be given to another recognizer instead of failing: its recognizer could not get the memory it
/// needs (`MEMORY`) or could not load its model (`MODEL`). Every other failure is about the recording, the language,
/// the download or the person's choice, and a second recognizer would meet it too or must not override it.
public enum RecognizerFallback {
    public static func applies(to failure: JobFailure) -> Bool {
        switch failure {
        case .memory, .model: true
        default: false
        }
    }
}
