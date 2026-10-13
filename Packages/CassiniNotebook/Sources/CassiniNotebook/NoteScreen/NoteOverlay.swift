import Foundation

/// A sheet over the Note screen. Small and `Codable`, so the screen keeps the open one with the scene and it comes
/// back after Cassini was closed (Android keeps its sheets with `rememberSaveable`); the text typed into Name this
/// speaker or Rename is kept beside it.
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

/// What a note's screen keeps with the scene: the open sheet with the text typed so far into it (Name this speaker,
/// Rename), and the open question (Android `NoteViewModel.saveOverlays`).
public struct SavedNoteOverlay: Codable, Hashable, Sendable {
    public var noteID: UUID
    public var overlay: NoteOverlay?
    public var draft: String?
    public var dialog: NoteDialog?

    public init(noteID: UUID, overlay: NoteOverlay? = nil, draft: String? = nil, dialog: NoteDialog? = nil) {
        self.noteID = noteID; self.overlay = overlay; self.draft = draft; self.dialog = dialog
    }

    /// The screen's open sheet, its draft and its question as the scene keeps them; nil when neither is open.
    public static func keeping(noteID: UUID, overlay: NoteOverlay?, draft: String?, dialog: NoteDialog?) -> Data? {
        guard overlay != nil || dialog != nil else { return nil }
        return SavedNoteOverlay(noteID: noteID, overlay: overlay, draft: overlay?.keepsDraft == true ? draft : nil,
                                dialog: dialog).encoded
    }

    public var encoded: Data? { try? JSONEncoder().encode(self) }

    public init?(_ data: Data?) {
        guard let data, let saved = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = saved
    }

    /// What opens again over `note`'s screen: the sheet when it can (`NoteOverlay.restorable`), with its draft, and
    /// the question when it still applies (`NoteDialog.restorable`); nil when nothing does or it is another note's.
    ///
    /// The screen asks once, on its first appearance with its note, and keeps only what this returns: a sheet that
    /// cannot open now must not open by itself on a later visit to the note (as the Library drops its dialog).
    public func restored(over note: Note, readOnly: ReadOnlyReason?) -> SavedNoteOverlay? {
        guard noteID == note.id else { return nil }
        let overlay = overlay?.restorable(over: note, readOnly: readOnly)
        let dialog = dialog?.restorable(over: note, readOnly: readOnly)
        guard overlay != nil || dialog != nil else { return nil }
        return SavedNoteOverlay(noteID: noteID, overlay: overlay, draft: overlay?.keepsDraft == true ? draft : nil,
                                dialog: dialog)
    }
}

extension NoteOverlay {
    /// Name this speaker and Rename keep what was typed into them.
    var keepsDraft: Bool {
        switch self {
        case .naming, .rename: true
        case .speakers, .versions, .documentInfo, .editing: false
        }
    }
}

extension NoteDialog {
    /// The question to ask again over `note` after Cassini was closed: the read-only explanation while its reason
    /// holds, Transcribe again? while the document still makes a fresh one, and Start over? (whose note is still
    /// here, as in the Library).
    public func restorable(over note: Note, readOnly: ReadOnlyReason?) -> NoteDialog? {
        switch self {
        case .readOnly(let reason): reason == readOnly ? self : nil
        case .transcribeFresh:
            TranscribeAgainRule.needsFreshConfirmation(note) && !note.refusesNewVersion ? self : nil
        case .startOver: self
        }
    }
}
