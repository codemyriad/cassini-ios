import SwiftUI
import CassiniNotebook

/// The long-press actions of a Library row.
struct NoteActionsMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(TrashStore.self) private var trash
    let note: Note
    var body: some View {
        Button(note.isFavorite ? "Remove star" : "Star recording", systemImage: note.isFavorite ? "star.slash" : "star") {
            library.update(note.id) { $0.isFavorite.toggle() }
        }
        if !note.isRecording {
            Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) { Task { await trash.moveToTrash(note.id) } }
        }
    }
}
