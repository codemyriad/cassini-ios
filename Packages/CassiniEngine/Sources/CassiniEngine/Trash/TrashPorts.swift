import Foundation
import CassiniNotebook

/// The notes as Recently Deleted sees and changes them: in the app, the Library's main-actor mirror over `NoteStore`.
@MainActor public protocol TrashNotes: AnyObject {
    /// Every note, Recently Deleted included.
    var notes: [Note] { get }
    func note(_ id: UUID) -> Note?
    /// Changes the note at once and writes it in the background. False when there is no such note.
    @discardableResult func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) -> Bool
    /// Deletes the note's directory, then the note.
    func delete(_ id: UUID) async throws
}

/// What Recently Deleted asks of the transcription queue.
@MainActor public protocol TrashQueue: AnyObject {
    /// A job runs for the note now: moving it asks first.
    func isRunning(_ noteID: UUID) -> Bool
    /// Before a note moves: a running job stops and keeps its progress, a queued one leaves the queue. Once the job has
    /// ended, `move` writes the trash with what the note remembers for Restore; when it returns false the job is put
    /// back. Returns what `move` returned.
    func trash(_ noteID: UUID, then move: (TrashedJob?) -> Bool) async -> Bool
    /// After Restore and Undo: a job that was queued is queued again, at the back.
    func restore(_ noteID: UUID, trashedJob: TrashedJob?)
    /// The first step of a permanent delete: a running job stops and is awaited, then the job goes.
    func cancelAndRemove(_ noteID: UUID) async
}

/// The voiceprints each note gave to the saved voices.
@MainActor public protocol VoiceEvidence: AnyObject {
    /// False when the saved voices could not be read: a note's prints cannot be taken out of them, so no note may be
    /// deleted for good.
    var isReadable: Bool { get }
    /// Removes the note's voiceprints and its samples from every saved voice.
    func removeEvidence(noteID: UUID) async throws
}

/// What the screens do around a move: in the app, the recording, the player and the navigation.
@MainActor public protocol TrashHost: AnyObject {
    /// False while the note may not go to Recently Deleted (it is being recorded).
    func mayTrash(_ noteID: UUID) -> Bool
    /// Just before the note moves: its playback stops.
    func willTrash(_ noteID: UUID)
    /// Right after it moved: its screen closes wherever it is open.
    func didTrash(_ noteID: UUID)
    /// The expired notes were deleted at `date`.
    func didPurge(at date: Date)
}

public enum TrashError: Error, Equatable {
    /// The saved voices could not be read; nothing was deleted.
    case voicesUnavailable
}
