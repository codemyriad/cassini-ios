import Foundation

/// The transcription entry of the note's actions menu (Android `TranscribeRowUi`).
public enum TranscribeRow: Hashable, Sendable {
    /// A note without a transcript: "Transcribe".
    case transcribe
    /// A note with a transcript: "Transcribe again".
    case transcribeAgain
    /// A document that cannot take a new version here (unverified or newer format): "Transcribe again", disabled.
    case transcribeAgainUnavailable
    /// A running job: "Stop and keep progress".
    case stop
    /// A queued job: "Remove from queue".
    case removeFromQueue
    /// A stopped job: "Resume" and "Start over".
    case resumeOrStartOver

    /// The row of `note` with its `job`; nil while the note is recorded or its audio cannot be played, when there is
    /// nothing to transcribe.
    public static func of(_ note: Note, job: Job?) -> TranscribeRow? {
        switch job?.state {
        case .running?: return .stop
        case .queued?: return .removeFromQueue
        case .paused?: return .resumeOrStartOver
        case .failed?, .needsConsent?, nil: break
        }
        guard note.audio.isPlayable else { return nil }
        guard note.hasDocument else { return .transcribe }
        return note.refusesNewVersion ? .transcribeAgainUnavailable : .transcribeAgain
    }
}
