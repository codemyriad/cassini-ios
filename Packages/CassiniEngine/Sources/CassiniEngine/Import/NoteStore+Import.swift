import Foundation
import CassiniNotebook

extension NoteStore {
    /// The note not in Recently Deleted whose imported source had these bytes.
    public func liveNote(withSourceSha256 sha256: String) -> Note? {
        all().first { $0.trashedAt == nil && $0.sourceSha256 == sha256 }
    }

    /// Saves `note` unless a live note has the same source bytes by now; that note's id then, and nothing is written.
    /// The check and the write are one step on the store, so two imports of one file at once add one note.
    public func insert(_ note: Note, unlessLiveSourceIs sha256: String) throws -> UUID? {
        if let existing = liveNote(withSourceSha256: sha256) { return existing.id }
        try save(note)
        return nil
    }
}
