import SwiftUI
import CassiniNotebook

/// A sheet over the Note screen. Kept with the scene as its `NoteOverlay`, so it opens again when the screen comes
/// back after Cassini was closed.
enum NoteSheet: Identifiable {
    case rename, speakers, versions, documentInfo
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

    init?(_ saved: SavedNoteOverlay, in note: Note) {
        switch saved.overlay {
        case .rename: self = .rename
        case .speakers: self = .speakers
        case .versions: self = .versions
        case .documentInfo: self = .documentInfo
        case .naming(let id): self = .naming(id, draft: saved.draft)
        case .editing(let id):
            guard let segment = note.transcript.first(where: { $0.id == id }) else { return nil }
            self = .editing(segment)
        }
    }

    var draft: String? { if case .naming(_, let draft) = self { draft } else { nil } }
}

extension View {
    /// Keeps the Note screen's open sheet, and the name typed into Name this speaker, with the scene, and opens the
    /// sheet again once the screen and its note are back after Cassini was closed (as Recently Deleted keeps its
    /// dialog). Off for UI tests, like the rest of the scene's state.
    func keepsNoteOverlay(note: Note?, readOnly: ReadOnlyReason?, sheet: Binding<NoteSheet?>,
                          draft: Binding<String?>) -> some View {
        modifier(NoteOverlayKeeper(note: note, readOnly: readOnly, sheet: sheet, draft: draft))
    }
}

private struct NoteOverlayKeeper: ViewModifier {
    let note: Note?
    let readOnly: ReadOnlyReason?
    @Binding var sheet: NoteSheet?
    @Binding var draft: String?
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
    }

    private func restore() {
        guard restoresSceneState, !restored, let note else { return }
        restored = true
        guard sheet == nil, let kept = SavedNoteOverlay(saved)?.restored(over: note, readOnly: readOnly) else { return }
        sheet = NoteSheet(kept, in: note)
    }

    private func keep() {
        guard restoresSceneState, restored, let note else { return }
        saved = sheet.flatMap { SavedNoteOverlay(noteID: note.id, overlay: $0.overlay, draft: draft).encoded }
    }
}
