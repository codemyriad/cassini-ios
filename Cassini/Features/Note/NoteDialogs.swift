import SwiftUI
import CassiniEngine
import CassiniNotebook

extension View {
    /// The Note screen's sheets (`NoteScreenModel.sheet`) and its question (`NoteScreenState.dialog`).
    func noteSheetsAndDialogs(model: NoteScreenModel) -> some View {
        modifier(NoteSheetsAndDialogs(model: model))
    }
}

private struct NoteSheetsAndDialogs: ViewModifier {
    let model: NoteScreenModel

    private var noteID: UUID { model.noteID }

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(item: $model.sheet, content: sheet)
            .alert(title, isPresented: shown, presenting: model.screen.dialog, actions: actions, message: message)
    }

    @ViewBuilder private func sheet(_ sheet: NoteSheet) -> some View {
        switch sheet {
        case .rename(let draft): RenameNoteDialog(noteID: noteID, draft: draft) { model.sheetDraft = $0 }
        case .speakers: SpeakersView(model: model)
        case .versions: TranscriptVersionsView(model: model)
        case .documentInfo: DocumentInfoSheet(noteID: noteID)
        case .naming(let speakerID, let draft):
            NameSpeakerSheet(model: model.naming(speakerID), draft: draft) { model.sheetDraft = $0 }
        case .editing(let segment): SegmentEditor(model: model, segment: segment)
        }
    }

    private var shown: Binding<Bool> {
        Binding(get: { model.screen.dialog != nil }, set: { if !$0 { model.screen.dismissDialog() } })
    }

    private var title: String {
        switch model.screen.dialog {
        case .readOnly(let reason)?: NoteCopy.readOnly(reason)
        case .startOver?: NoteCopy.startOverTitle
        case .transcribeFresh?: NoteCopy.freshTitle
        case nil: ""
        }
    }

    @ViewBuilder private func actions(_ dialog: NoteDialog) -> some View {
        switch dialog {
        case .readOnly: Button(NoteCopy.close, role: .cancel) { model.screen.dismissDialog() }
        case .startOver:
            Button(NoteCopy.startOver, role: .destructive) { model.confirmDialog() }
            Button(NoteCopy.cancel, role: .cancel) { model.screen.dismissDialog() }
        case .transcribeFresh:
            Button(NoteCopy.transcribeAgain) { model.confirmDialog() }
            Button(NoteCopy.cancel, role: .cancel) { model.screen.dismissDialog() }
        }
    }

    @ViewBuilder private func message(_ dialog: NoteDialog) -> some View {
        switch dialog {
        case .readOnly: EmptyView()
        case .startOver: Text(NoteCopy.startOverBody)
        case .transcribeFresh: Text(NoteCopy.freshBody)
        }
    }
}
