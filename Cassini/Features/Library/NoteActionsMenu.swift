import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The long-press actions of a Library row: the iOS form of Android's Note actions sheet (features.md section 6). What
/// it offers comes from `LibraryScreenModel.menu(_:)` and each row goes to `perform(_:on:)`; the exports and Document
/// info belong to the Note screen, which opens and starts them.
struct NoteActionsMenu: View {
    let noteID: UUID
    @Environment(LibraryScreenModel.self) private var model

    @State private var exportOpen = false
    @State private var confirmedExport: ExportSheetState.Choice?

    var body: some View {
        Group {
            if let menu = model.menu(noteID) {
                Button(menu.isFavorite ? LibraryCopy.removeStar : LibraryCopy.star, systemImage: menu.isFavorite ? "star.slash" : "star") {
                    perform(.toggleStar)
                }
                Button(LibraryCopy.rename, systemImage: "pencil") { perform(.rename) }
                if !menu.recording {
                    transcribeItems(menu)
                    exportMenu(menu)
                    Button(LibraryCopy.documentInfo, systemImage: "info.circle") { perform(.documentInfo) }
                    Divider()
                    Button(TrashCopy.moveToTrash, systemImage: "trash", role: .destructive) { perform(.moveToTrash) }
                }
            }
        }
        .sheet(isPresented: $exportOpen, onDismiss: shareConfirmed) {
            if let note = model.note(noteID), let menu = model.menu(noteID) {
                ExportFormatSheet(note: note, jobPending: menu.transcribe == .stop || menu.transcribe == .removeFromQueue) {
                    confirmedExport = $0
                }
            }
        }
    }

    private func shareConfirmed() {
        guard let choice = confirmedExport else { return }
        confirmedExport = nil
        if let format = choice.transcriptFormat { perform(.export(format)) }
        else if choice == .originalAudio { perform(.shareAudio) }
        else { perform(.exportDocument) }
    }

    @ViewBuilder private func transcribeItems(_ menu: LibraryRowMenu) -> some View {
        switch menu.transcribe {
        case .transcribe:
            Button(LibraryCopy.transcribe, systemImage: TranscribeSymbol.name) { perform(.transcribe) }.disabled(menu.transcribeWaits)
        case .transcribeAgain(let version, let namesCarry):
            Button { perform(.transcribeAgain) } label: {
                Label(LibraryCopy.transcribeAgain, systemImage: "arrow.clockwise")
                Text(LibraryCopy.addsVersion(version) + (namesCarry ? " " + LibraryCopy.namesCarry : ""))
            }.disabled(menu.transcribeWaits)
        case .transcribeAgainUnavailable:
            Button {} label: {
                Label(LibraryCopy.transcribeAgain, systemImage: "arrow.clockwise")
                Text(LibraryCopy.noNewVersion)
            }.disabled(true)
        case .stop:
            Button(LibraryCopy.stop, systemImage: "stop.circle") { perform(.stop) }
        case .removeFromQueue:
            Button(LibraryCopy.removeFromQueue, systemImage: "minus.circle") { perform(.removeFromQueue) }
        case .resumeOrStartOver:
            Button(LibraryCopy.resume, systemImage: "play.circle") { perform(.resume) }
            Button(LibraryCopy.startOver, systemImage: "arrow.counterclockwise") { perform(.startOver) }
        }
    }

    /// D99 uses the same format selector as the meeting header.
    private func exportMenu(_ menu: LibraryRowMenu) -> some View {
        Button(LibraryCopy.export, systemImage: "square.and.arrow.up") { exportOpen = true }
            .disabled(menu.transcribeWaits)
    }

    private func perform(_ action: NoteAction) {
        Task { await model.perform(action, on: noteID) }
    }
}
