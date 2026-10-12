import SwiftUI
import CassiniEngine

extension View {
    /// "Stop transcription and move to Recently Deleted?" for a note whose transcription runs, from any screen.
    func trashStopConfirmation() -> some View { modifier(TrashStopConfirmation()) }
}

/// The confirmation is kept with the scene, so it comes back after Cassini was closed once its note is in the library
/// again.
private struct TrashStopConfirmation: ViewModifier {
    @Environment(TrashService.self) private var trash
    @Environment(LibraryStore.self) private var library
    @Environment(\.restoresSceneState) private var restoresSceneState
    @SceneStorage("trash.stopConfirmation") private var savedNoteID: String?
    /// The note whose confirmation was open when Cassini closed, until the library has loaded it.
    @State private var restoring: UUID?

    func body(content: Content) -> some View {
        content.alert(TrashCopy.stopAndTrash,
                      isPresented: Binding(get: { trash.stopConfirmation != nil }, set: { if !$0 { trash.cancelStop() } }),
                      presenting: trash.stopConfirmation) { note in
            Button(TrashCopy.cancel, role: .cancel) {}
            Button(TrashCopy.moveToTrash, role: .destructive) { Task { await trash.confirmStop(note) } }
        } message: { _ in
            Text(TrashCopy.keptFor30Days)
        }
        .onAppear { if restoresSceneState { restoring = savedNoteID.flatMap(UUID.init(uuidString:)) } }
        .onChange(of: restoring.flatMap(library.note) != nil, initial: true) { _, loaded in
            guard loaded, let id = restoring else { return }
            restoring = nil
            if !trash.askAgain(id) { savedNoteID = nil }
        }
        .onChange(of: trash.stopConfirmation) { _, note in
            if restoresSceneState { savedNoteID = note?.noteID.uuidString }
        }
    }
}
