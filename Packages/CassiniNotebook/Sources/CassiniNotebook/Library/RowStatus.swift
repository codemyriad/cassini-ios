import CassiniCore
import Foundation

/// What a note's audio file is, for its Library status: a capture still being written, plain audio, audio with a
/// transcript (a Cassini document on Android; a transcribed note or an imported document here), or a file that cannot
/// be played.
public enum AudioKind: Hashable, Sendable, CaseIterable {
    case liveCapture, plain, document, unplayable
}

/// What the Library status chip needs to know about one note (Android `NoteFacts`): `documentState` is nil unless
/// the audio is a document, `jobState` nil without a job, and whether the note is the capture being recorded now.
public struct RowFacts: Hashable, Sendable {
    public var audioKind: AudioKind
    public var documentState: DocumentState?
    public var jobState: JobState?
    public var isActiveCapture: Bool

    public init(audioKind: AudioKind, documentState: DocumentState? = nil, jobState: JobState? = nil,
                isActiveCapture: Bool = false) {
        self.audioKind = audioKind; self.documentState = documentState; self.jobState = jobState
        self.isActiveCapture = isActiveCapture
    }

    /// The facts of `note` with its job's state, while `activeNoteID` is being recorded. A note with a transcript is a
    /// readable document, unless it was imported from one Cassini could not read; one with neither is plain audio.
    public init(_ note: Note, jobState: JobState?, activeNoteID: UUID?) {
        let transcribed = !note.transcript.isEmpty || note.status == .ready
        let stored = note.document?.state
        let documentState: DocumentState? = transcribed && (stored == nil || stored == .plainAudio) ? .ok : stored
        let kind: AudioKind = switch note.audio {
        case .live: .liveCapture
        case .unplayable: .unplayable
        case .plain: documentState == nil ? .plain : .document
        }
        self.init(audioKind: kind, documentState: kind == .plain ? nil : documentState, jobState: jobState,
                  isActiveCapture: note.id == activeNoteID)
    }
}

/// The Library status chip (Android `NoteStatus`, features.md section 1). `of` applies the table rows in order; the
/// first match wins.
public enum RowStatus: Hashable, Sendable, CaseIterable {
    case recording, transcribing, queued, paused, failed, unplayable, unreadable, newerFormat, transcribed, audioOnly

    /// The text after the chip on the meta line.
    public enum Suffix: Hashable, Sendable { case none, resume, tryAgain, speakers, noSpeech }

    public static func of(_ facts: RowFacts) -> RowStatus {
        if facts.audioKind == .liveCapture && facts.isActiveCapture { return .recording }
        switch facts.jobState {
        case .running: return .transcribing
        case .queued: return .queued
        case .paused: return .paused
        case .failed: return .failed
        case .needsConsent, nil: break
        }
        if facts.audioKind == .unplayable { return .unplayable }
        switch facts.documentState {
        case .unreadable, .invalidMetadata: return .unreadable
        case .unknownFormat: return .newerFormat
        case .ok, .unverified, .staleAudio: return .transcribed
        case .plainAudio, nil: return .audioOnly
        }
    }

    /// "· Resume" when paused, "· Try again" when failed, and for a transcribed note "· No speech" without words or
    /// "· N speakers" with 1 or more.
    public static func suffix(_ status: RowStatus, speakerCount: Int, hasWords: Bool) -> Suffix {
        switch status {
        case .paused: .resume
        case .failed: .tryAgain
        case .transcribed: !hasWords ? .noSpeech : speakerCount >= 1 ? .speakers : .none
        default: .none
        }
    }
}
