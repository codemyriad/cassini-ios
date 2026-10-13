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

    /// Rename keeps the title being typed, as Android's RenameDialog keeps it (`rememberSaveable`).
    @Test func renameKeepsTheTypedTitle() {
        let note = Note(title: "Standup")
        let rename = SavedLibraryDialog(.rename(note.id), draft: "Standup, revised")
        #expect(SavedLibraryDialog(rename.encoded) == rename)
        #expect(rename.restored(over: [note])?.draft == "Standup, revised")
        #expect(SavedLibraryDialog(.startOver(note.id), draft: "stray").draft == nil)
        #expect(SavedLibraryDialog(.rename(note.id), draft: "x").restored(over: []) == nil)
        #expect(SavedLibraryDialog(Data("garbage".utf8)) == nil)
    }
}
