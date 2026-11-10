import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The long-press actions of a Library row: the iOS form of Android's Note actions sheet (features.md section 6). What
/// it offers comes from `LibraryScreenModel.menu(_:)` and each row goes to `perform(_:on:)`; the exports and Document
/// info belong to the Note screen, which opens and starts them.
struct NoteActionsMenu: View {
    let noteID: UUID
    @Environment(LibraryScreenModel.self) private var model

    var body: some View {
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

    /// The transcript formats (disabled, with the reason, for a note without a transcript), the Cassini document and
    /// the original audio, which is always offered, as Android's Save a copy rows.
    private func exportMenu(_ menu: LibraryRowMenu) -> some View {
        let unavailable = ExportCopy.reason(menu.export)
        return Menu {
            Section {
                ForEach(TranscriptFormat.allCases) { format in
                    Button(ExportCopy.title(format)) { perform(.export(format)) }.disabled(unavailable != nil)
                }
            } header: {
                if let unavailable { Text(unavailable) }
            }
            Button(NoteCopy.exportDocument, systemImage: "doc.badge.arrow.up") { perform(.exportDocument) }
                .disabled(!menu.exportsDocument)
            Button(NoteCopy.shareAudio, systemImage: "waveform") { perform(.shareAudio) }.disabled(menu.transcribeWaits)
        } label: {
            Label(LibraryCopy.export, systemImage: "square.and.arrow.up")
        }
    }

    private func perform(_ action: NoteAction) {
        Task { await model.perform(action, on: noteID) }
    }
}
