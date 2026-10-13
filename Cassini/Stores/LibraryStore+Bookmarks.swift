import Foundation
import CassiniNotebook

/// Marked moments (an iOS extra): the screens ask for them by intent, and the note's rules make the change.
extension LibraryStore {
    /// Marks the moment at `time` of the note.
    func markMoment(_ noteID: UUID, at time: TimeInterval) {
        let bookmark = UUID()
        update(noteID) { $0.addBookmark(at: time, id: bookmark) }
    }

    func removeBookmark(_ bookmarkID: UUID, from noteID: UUID) {
        update(noteID) { $0.removeBookmark(bookmarkID) }
    }
}
