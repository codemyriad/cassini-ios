import SwiftUI
import CassiniNotebook

/// A sheet over the Note screen. Kept with the scene as its `NoteOverlay`, so it opens again when the screen comes
/// back after Cassini was closed.
enum NoteSheet: Identifiable {
    /// Rename, starting from `draft` when one was being typed before Cassini was closed.
    case rename(draft: String?)
    case speakers, versions, documentInfo
    /// Name this speaker, starting from `draft` when one was being typed before Cassini was closed.
    case naming(String, draft: String?)
    /// Edit passage, of the passage as it was when the editor opened.
    case editing(TranscriptSegment)

    var id: String {
        switch self {
        case .rename: "rename"
        case .speakers: "speakers"
        case .versions: "versions"
        case .documentInfo: "documentInfo"
        case .naming(let id, _): "naming-\(id)"
        case .editing(let segment): "editing-\(segment.id)"
        }
    }

    var overlay: NoteOverlay {
        switch self {
        case .rename: .rename
        case .speakers: .speakers
        case .versions: .versions
        case .documentInfo: .documentInfo
        case .naming(let id, _): .naming(speakerID: id)
        case .editing(let segment): .editing(segmentID: segment.id)
        }
    }

    init?(_ overlay: NoteOverlay, draft: String?, in note: Note) {
        switch overlay {
        case .rename: self = .rename(draft: draft)
        case .speakers: self = .speakers
        case .versions: self = .versions
        case .documentInfo: self = .documentInfo
        case .naming(let id): self = .naming(id, draft: draft)
        case .editing(let id):
            guard let segment = note.transcript.first(where: { $0.id == id }) else { return nil }
            self = .editing(segment)
        }
    }

    var draft: String? {
        switch self {
        case .naming(_, let draft), .rename(let draft): draft
        case .speakers, .versions, .documentInfo, .editing: nil
        }
    }
}

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
