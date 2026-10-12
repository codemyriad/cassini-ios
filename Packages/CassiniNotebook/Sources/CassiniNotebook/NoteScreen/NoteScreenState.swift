import Foundation

/// A question the Note screen asks before it acts, or a change it refuses.
public enum NoteDialog: Hashable, Sendable {
    /// A rename, merge, version change or passage edit that `ReadOnlyReason` does not allow now.
    case readOnly(ReadOnlyReason)
    /// "Start over? The draft so far is discarded. Your recording is kept."
    case startOver
    /// "Transcribe again? Earlier versions can't be kept because the audio changed." (a document that is not ok).
    case transcribeFresh
}

/// What the screen asks the app to do after an event.
public enum NoteEffect: Hashable, Sendable {
    /// Seek to the time and play; following resumes.
    case seekAndPlay(TimeInterval)
    /// Open Name a speaker.
    case nameSpeaker(String)
    case openVersions
    /// Open the passage editor.
    case editPassage(UUID)
    case transcribe(JobKind)
    case startOver
    /// "Play anyway": the document is acknowledged and the player plays.
    case acknowledgeTrustAndPlay
    /// The held queue's Continue.
    case continueQueue
    /// A dismissed final failure removes its job, so the transcript shows again.
    case clearFailed
}

/// The Note screen's own state and its event rules (the parts of Android's `NoteViewModel` that do not need the
/// stores): search, auto-follow, the trust chip, dismissed banners, the open dialog, and the read-only gate. Each
/// event returns what the app should do, if anything.
public struct NoteScreenState: Hashable, Sendable {
    public var search: InNoteSearch?
    public var follow = PlaybackFollow()
    public var trustToggled = false
    public var dismissed: Set<String> = []
    public var dialog: NoteDialog?

    /// A screen opened from the Library with `query` starts with the search open and prefilled.
    public init(query: String? = nil) {
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search = InNoteSearch(query: query) }
    }

    /// The screen leaves when its note is gone or in Recently Deleted.
    public static func isGone(_ note: Note?) -> Bool { note?.trashedAt != nil || note == nil }

    // MARK: Changes the read-only gate covers

    /// A speaker header or the suggestion card's name: Name a speaker, unless the transcript is read-only.
    public mutating func speakerTapped(_ speakerID: String, readOnly: ReadOnlyReason?) -> NoteEffect? {
        gated(readOnly, .nameSpeaker(speakerID))
    }

    /// The version chip or Transcript versions.
    public mutating func versionsTapped(readOnly: ReadOnlyReason?) -> NoteEffect? { gated(readOnly, .openVersions) }

    /// Edit passage.
    public mutating func editPassage(_ segmentID: UUID, readOnly: ReadOnlyReason?) -> NoteEffect? {
        gated(readOnly, .editPassage(segmentID))
    }

    private mutating func gated(_ readOnly: ReadOnlyReason?, _ effect: NoteEffect) -> NoteEffect? {
        if let readOnly {
            dialog = .readOnly(readOnly)
            return nil
        }
        return effect
    }

    // MARK: Playback

    /// A word tap seeks to the word and plays, and following resumes.
    public mutating func wordTapped(_ word: WordRef, in transcript: NoteTranscript) -> NoteEffect? {
        guard let start = transcript.wordStart(word) else { return nil }
        follow.resume()
        return .seekAndPlay(start)
    }

    /// "Play from start of turn".
    public mutating func playTurn(_ turnID: String, in transcript: NoteTranscript) -> NoteEffect? {
        guard let start = transcript.turnStart(turnID) else { return nil }
        follow.resume()
        return .seekAndPlay(start)
    }

    // MARK: Banners

    /// The trust chip shows or hides the trust banner.
    public mutating func toggleTrust() { trustToggled.toggle() }

    public mutating func bannerAction(_ action: NoteBanner.Action, note: Note, job: Job?) -> NoteEffect? {
        switch action {
        case .resume, .tryAgain: return .transcribe(job?.kind ?? .transcribe)
        case .startOver:
            dialog = .startOver
            return nil
        case .transcribe: return .transcribe(.transcribe)
        case .transcribeAgain: return transcribeAgain(note)
        case .playAnyway: return .acknowledgeTrustAndPlay
        case .continueQueue: return .continueQueue
        }
    }

    /// Transcribe again: refused for a document that cannot take a new version, and asked first for one that becomes a
    /// fresh document.
    public mutating func transcribeAgain(_ note: Note) -> NoteEffect? {
        if TranscribeAgainRule.refused(note) { return nil }
        if TranscribeAgainRule.needsFreshConfirmation(note) {
            dialog = .transcribeFresh
            return nil
        }
        return .transcribe(.transcribeAgain)
    }

    /// Hides `banner`; a dismissed final failure removes its job instead, so the transcript shows again.
    public mutating func dismiss(_ banner: NoteBanner, note: Note, job: Job?) -> NoteEffect? {
        if banner.kind == .failed, let job, NoteBanners.finalFailure(job, refused: TranscribeAgainRule.refused(note)) {
            return .clearFailed
        }
        dismissed.insert(banner.id)
        return nil
    }

    // MARK: Dialogs

    /// The dialog's confirming button.
    public mutating func confirmDialog() -> NoteEffect? {
        defer { dialog = nil }
        switch dialog {
        case .startOver?: return .startOver
        case .transcribeFresh?: return .transcribe(.transcribeAgain)
        case .readOnly?, nil: return nil
        }
    }

    public mutating func dismissDialog() { dialog = nil }

    // MARK: Search

    public mutating func openSearch() { if search == nil { search = InNoteSearch() } }
    public mutating func closeSearch() { search = nil }
}
