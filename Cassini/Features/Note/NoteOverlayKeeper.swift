import SwiftUI
import CassiniNotebook

extension View {
    /// Keeps the Note screen's open sheet, the text typed into Name this speaker or Rename, and the open question
    /// with the scene, and opens them again once the screen and its note are back after Cassini was closed (as the
    /// Library keeps its dialog). Off for UI tests, like the rest of the scene's state.
    func keepsNoteOverlay(noteID: UUID, note: Note?, readOnly: ReadOnlyReason?, sheet: Binding<NoteSheet?>,
                          draft: Binding<String?>, dialog: Binding<NoteDialog?>) -> some View {
        modifier(NoteOverlayKeeper(noteID: noteID, note: note, readOnly: readOnly, sheet: sheet, draft: draft,
                                   dialog: dialog))
    }
}

private struct NoteOverlayKeeper: ViewModifier {
    let noteID: UUID
    let note: Note?
    let readOnly: ReadOnlyReason?
    @Binding var sheet: NoteSheet?
    @Binding var draft: String?
    @Binding var dialog: NoteDialog?
    @Environment(\.restoresSceneState) private var restoresSceneState
    @SceneStorage("note.overlay") private var saved: Data?
    @State private var restored = false

    func body(content: Content) -> some View {
        content
            .onAppear(perform: restore)
            // After a launch the screen can come back before its note is read.
            .onChange(of: note == nil) { _, _ in restore() }
            .onChange(of: sheet?.id) { _, _ in
                draft = sheet?.draft
                keep()
            }
            .onChange(of: draft) { _, _ in keep() }
            .onChange(of: dialog) { _, _ in keep() }
            // A screen that leaves (its note gone) takes what it kept along.
            .onDisappear { if restoresSceneState, SavedNoteOverlay(saved)?.noteID == noteID { saved = nil } }
    }

    /// Opens what the scene kept, once, on the first appearance with the note. What cannot open now is dropped, so
    /// it does not open by itself on a later visit (`SavedNoteOverlay.restored`).
    private func restore() {
        guard restoresSceneState, !restored, let note else { return }
        restored = true
        let kept = SavedNoteOverlay(saved)?.restored(over: note, readOnly: readOnly)
        if sheet == nil, let overlay = kept?.overlay {
            draft = kept?.draft
            sheet = NoteSheet(overlay, draft: kept?.draft, in: note)
        }
        if dialog == nil, let question = kept?.dialog { dialog = question }
        keep()
    }

    private func keep() {
        guard restoresSceneState, restored, let note else { return }
        saved = SavedNoteOverlay.keeping(noteID: note.id, overlay: sheet?.overlay, draft: draft, dialog: dialog)
    }
}
