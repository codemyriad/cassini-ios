import Foundation
import Testing
import CassiniNotebook
import CassiniEngine

/// The Library's open dialog comes back after Cassini was closed, unless its note has gone.
@Suite struct LibraryDialogTests {
    @Test func aDialogRoundTripsAndComesBackOverItsNote() throws {
        let note = Note(title: "Standup")
        for dialog in [LibraryDialog.rename(note.id), .startOver(note.id), .transcribeFresh(note.id)] {
            let saved = try JSONDecoder().decode(LibraryDialog.self, from: JSONEncoder().encode(dialog))
            #expect(saved == dialog)
            #expect(saved.noteID == note.id)
            #expect(saved.restorable(over: [note]) == dialog)
        }
    }

    @Test func aDialogWhoseNoteIsGoneOrTrashedDoesNotComeBack() {
        var trashed = Note(title: "Old"); trashed.trashedAt = Date()
        #expect(LibraryDialog.rename(trashed.id).restorable(over: [trashed]) == nil)
        #expect(LibraryDialog.rename(UUID()).restorable(over: [trashed]) == nil)
    }
}
