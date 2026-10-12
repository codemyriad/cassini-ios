import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The long-press actions of a Library row.
struct NoteActionsMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(TrashService.self) private var trash
    let note: Note
    var body: some View {
        Button(note.isFavorite ? "Remove star" : "Star recording", systemImage: note.isFavorite ? "star.slash" : "star") {
            library.update(note.id) { $0.isFavorite.toggle() }
        }
        if !note.isRecording {
            Button(TrashCopy.moveToTrash, systemImage: "trash", role: .destructive) { Task { await trash.requestTrash(note.id) } }
        }
    }
}
