import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The long-press actions of a Library row: the iOS form of Android's Note actions sheet (features.md section 6). What
/// it offers comes from `LibraryScreenModel.menu(_:)`. The Library hosts the export selector;
/// confirmed exports and Document info open the Note screen, which runs the action.
struct NoteActionsMenu: View {
    let noteID: UUID
    @Environment(LibraryScreenModel.self) private var model

    let openExport: () -> Void

    var body: some View {
        Group {
            if let menu = model.menu(noteID) {
                Button(menu.isFavorite ? LibraryCopy.removeStar : LibraryCopy.star, systemImage: menu.isFavorite ? "star.slash" : "star") {
                    perform(.toggleStar)
                }
                Button(LibraryCopy.rename, systemImage: "pencil") { perform(.rename) }
                if !menu.recording {
                    Button(Wave6Copy.meetingSetDateTime, systemImage: "calendar") { perform(.setDateTime) }
                    transcribeItems(menu)
                    exportMenu(menu)
                    Button(LibraryCopy.documentInfo, systemImage: "info.circle") { perform(.documentInfo) }
                    Divider()
                    Button(TrashCopy.moveToTrash, systemImage: "trash", role: .destructive) { perform(.moveToTrash) }
                }
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

    /// D99 uses the same format selector as the meeting header.
    private func exportMenu(_ menu: LibraryRowMenu) -> some View {
        Button(LibraryCopy.export, systemImage: "square.and.arrow.up") { openExport() }
            .accessibilityIdentifier("exportOpen")
            .disabled(menu.transcribeWaits)
    }

    private func perform(_ action: NoteAction) {
        Task { await model.perform(action, on: noteID) }
    }
}
