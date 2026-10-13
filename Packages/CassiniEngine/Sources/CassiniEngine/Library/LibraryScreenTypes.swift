import Foundation
import CassiniNotebook

/// A confirmation or form the Library opens over itself (Android `LibraryDialog`). `Codable`, so the Library keeps the
/// open one with the scene and it comes back after Cassini was closed.
public enum LibraryDialog: Identifiable, Hashable, Codable, Sendable {
    case rename(UUID)
    /// "Start over?": the saved progress goes.
    case startOver(UUID)
    /// Transcribe again on a document whose versions cannot be kept.
    case transcribeFresh(UUID)

    public var id: Self { self }

    public var noteID: UUID {
        switch self {
        case .rename(let id), .startOver(let id), .transcribeFresh(let id): id
        }
    }

    /// The dialog to open again after Cassini was closed: none once its note is gone or in Recently Deleted.
    public func restorable(over notes: [Note]) -> LibraryDialog? {
        notes.contains { $0.id == noteID && $0.trashedAt == nil } ? self : nil
    }
}

/// The Library's open dialog as the scene keeps it, with the title typed so far into Rename.
public struct SavedLibraryDialog: Codable, Hashable, Sendable {
    public var dialog: LibraryDialog
    public var draft: String?

    public init(_ dialog: LibraryDialog, draft: String? = nil) {
        self.dialog = dialog
        if case .rename = dialog { self.draft = draft }
    }

    public var encoded: Data? { try? JSONEncoder().encode(self) }

    public init?(_ data: Data?) {
        guard let data, let saved = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = saved
    }

    /// What opens again over `notes` (`LibraryDialog.restorable`), with its draft; nil once its note is gone, and
    /// the screen then drops what it kept.
    public func restored(over notes: [Note]) -> SavedLibraryDialog? {
        dialog.restorable(over: notes).map { SavedLibraryDialog($0, draft: draft) }
    }
}

/// A row of a note's actions menu (Android `NoteAction`, features.md section 6).
public enum NoteAction: Hashable, Sendable {
    case toggleStar
    case rename
    case transcribe
    case transcribeAgain
    /// Stop and keep progress.
    case stop
    case removeFromQueue
    case resume
    case startOver
    case export(TranscriptFormat)
    /// Export Cassini document and Share original audio (Android's Save a copy rows).
    case exportDocument
    case shareAudio
    case documentInfo
    case moveToTrash
}

/// What a note's actions menu offers (Android `NoteActionsUi`).
public struct LibraryRowMenu: Hashable, Sendable {
    public var isFavorite: Bool
    /// The note is being recorded: only Star and Rename.
    public var recording: Bool
    /// The transcribe row for the note's job.
    public var transcribe: TranscribeAction
    /// The recording's audio is still being written: Transcribe and Transcribe again wait for it.
    public var transcribeWaits: Bool
    /// The transcript exports; the audio can be shared whatever this says.
    public var export: TranscriptExportAvailability
    /// A Cassini document can be made: the note has a transcript and no job runs for it, as on the Note screen.
    public var exportsDocument: Bool

    public init(isFavorite: Bool, recording: Bool, transcribe: TranscribeAction, transcribeWaits: Bool,
                export: TranscriptExportAvailability, exportsDocument: Bool) {
        self.isFavorite = isFavorite; self.recording = recording; self.transcribe = transcribe
        self.transcribeWaits = transcribeWaits; self.export = export; self.exportsDocument = exportsDocument
    }
}

/// Where the Library sends the user.
public enum LibraryEffect: Hashable, Sendable {
    case openNote(Route)
    /// The Recording screen: it starts a recording, or returns to the one in progress.
    case openRecording
    case openSettings
    case openModelDownload(noteID: UUID?)
    /// A Transcribe the queue refused; the app says why.
    case refused(EnqueueRefusal)
}

/// What the Library shows: the day sections, or while searching the flat results, and what it says instead of rows.
public struct LibraryContent: Hashable, Sendable {
    /// The notes have not been read yet: nothing below the search, so the empty state never flashes.
    public var loading: Bool
    public var sections: [DaySection]
    /// The flat results while a query is open; nil when not searching.
    public var results: [LibraryRow]?
    public var emptyState: LibraryEmptyState?
    /// What only the Library knows, for its banners (`Notices.library`).
    public var facts: LibraryFacts

    public init(loading: Bool = false, sections: [DaySection] = [], results: [LibraryRow]? = nil,
                emptyState: LibraryEmptyState? = nil, facts: LibraryFacts = LibraryFacts()) {
        self.loading = loading; self.sections = sections; self.results = results; self.emptyState = emptyState
        self.facts = facts
    }
}
