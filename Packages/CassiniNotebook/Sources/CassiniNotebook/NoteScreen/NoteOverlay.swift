import Foundation

/// A sheet over the Note screen. Small and `Codable`, so the screen keeps the open one with the scene and it comes
/// back after Cassini was closed (Android keeps its sheets with `rememberSaveable`); the name being typed into Name
/// this speaker is kept beside it.
public enum NoteOverlay: Codable, Hashable, Sendable {
    case rename
    case speakers
    case versions
    case documentInfo
    case naming(speakerID: String)
    case editing(segmentID: UUID)

    /// Whether the sheet changes the transcript, so it opens only while the transcript can be changed.
    var changesTranscript: Bool {
        switch self {
        case .rename, .documentInfo: false
        case .speakers, .versions, .naming, .editing: true
        }
    }

    /// The sheet to show again over `note`: none when what it was about is gone (the speaker, the passage, every
    /// version), or when it would change a transcript that is read-only now (`readOnly`).
    public func restorable(over note: Note, readOnly: ReadOnlyReason?) -> NoteOverlay? {
        if changesTranscript, readOnly != nil { return nil }
        switch self {
        case .rename, .documentInfo: return self
        case .speakers: return note.speakers?.isEmpty == false ? self : nil
        case .versions: return note.versions?.isEmpty == false ? self : nil
        case .naming(let speakerID): return note.speaker(speakerID) != nil ? self : nil
        case .editing(let segmentID): return note.transcript.contains { $0.id == segmentID } ? self : nil
        }
    }
}

/// The open sheet of a note's screen as the scene keeps it, with the name typed so far into Name this speaker.
public struct SavedNoteOverlay: Codable, Hashable, Sendable {
    public var noteID: UUID
    public var overlay: NoteOverlay
    public var draft: String?

    public init(noteID: UUID, overlay: NoteOverlay, draft: String? = nil) {
        self.noteID = noteID; self.overlay = overlay; self.draft = draft
    }

    public var encoded: Data? { try? JSONEncoder().encode(self) }

    public init?(_ data: Data?) {
        guard let data, let saved = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = saved
    }

    /// The saved sheet for `note`'s screen, when it is that note's and can open again (`NoteOverlay.restorable`); a
    /// draft is kept only for Name this speaker.
    public func restored(over note: Note, readOnly: ReadOnlyReason?) -> SavedNoteOverlay? {
        guard noteID == note.id, let overlay = overlay.restorable(over: note, readOnly: readOnly) else { return nil }
        guard case .naming = overlay else { return SavedNoteOverlay(noteID: noteID, overlay: overlay) }
        return SavedNoteOverlay(noteID: noteID, overlay: overlay, draft: draft)
    }
}
