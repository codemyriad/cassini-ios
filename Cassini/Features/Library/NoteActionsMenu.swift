import SwiftUI
import CassiniEngine
import CassiniNotebook

/// A confirmation or form the Library opens over itself.
enum LibraryDialog: Identifiable, Hashable {
    case rename(UUID)
    case startOver(UUID)
    /// Transcribe again on a document whose versions cannot be kept.
    case transcribeFresh(UUID)

    var id: Self { self }
}

/// The long-press actions of a Library row: the iOS form of Android's Note actions sheet (features.md section 6). The
/// exports and Document info belong to the Note screen, which opens and starts them.
struct NoteActionsMenu: View {
    let note: Note
    let voiceModelReady: Bool
    @Binding var dialog: LibraryDialog?
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryScreenModel.self) private var model
    @Environment(ProcessingStore.self) private var processing
    @Environment(RecordingStore.self) private var recording
    @Environment(TrashService.self) private var trash
    @Environment(Router.self) private var router

    var body: some View {
        let recordingNow = note.isRecording && recording.state.noteID == note.id
        Button(note.isFavorite ? LibraryCopy.removeStar : LibraryCopy.star, systemImage: note.isFavorite ? "star.slash" : "star") {
            library.update(note.id) { $0.isFavorite.toggle() }
        }
        Button(LibraryCopy.rename, systemImage: "pencil") { dialog = .rename(note.id) }
        if !recordingNow {
            transcribeItems
            exportMenu
            Button(LibraryCopy.documentInfo, systemImage: "info.circle") {
                router.show(.note(note.id, start: .documentInfo))
            }
            Divider()
            Button(TrashCopy.moveToTrash, systemImage: "trash", role: .destructive) { Task { await trash.requestTrash(note.id) } }
        }
    }

    @ViewBuilder private var transcribeItems: some View {
        let job = processing.state.jobs[note.id]
        let finishing = recording.finishingNoteID == note.id
        switch LibraryMapping.transcribeAction(note, job: job, voiceModelReady: voiceModelReady) {
        case .transcribe:
            Button(LibraryCopy.transcribe, systemImage: "text.badge.plus") { transcribe(.transcribe) }.disabled(finishing)
        case .transcribeAgain(let version, let namesCarry):
            Button { transcribeAgain() } label: {
                Label(LibraryCopy.transcribeAgain, systemImage: "arrow.clockwise")
                Text(LibraryCopy.addsVersion(version) + (namesCarry ? " " + LibraryCopy.namesCarry : ""))
            }.disabled(finishing)
        case .transcribeAgainUnavailable:
            Button {} label: {
                Label(LibraryCopy.transcribeAgain, systemImage: "arrow.clockwise")
                Text(LibraryCopy.noNewVersion)
            }.disabled(true)
        case .stop:
            Button(LibraryCopy.stop, systemImage: "stop.circle") { processing.stop(note.id) }
        case .removeFromQueue:
            Button(LibraryCopy.removeFromQueue, systemImage: "minus.circle") { processing.dequeue(note.id) }
        case .resumeOrStartOver:
            Button(LibraryCopy.resume, systemImage: "play.circle") { transcribe(job?.kind ?? .transcribe) }
            Button(LibraryCopy.startOver, systemImage: "arrow.counterclockwise") { dialog = .startOver(note.id) }
        }
    }

    private var exportMenu: some View {
        let unavailable = ExportCopy.reason(TranscriptExports.availability(of: note))
        return Menu {
            ForEach(TranscriptFormat.allCases) { format in
                Button(ExportCopy.title(format)) { router.show(.note(note.id, start: .export(format))) }
            }
        } label: {
            Label(LibraryCopy.export, systemImage: "square.and.arrow.up")
            if let unavailable { Text(unavailable) }
        }
        .disabled(unavailable != nil)
    }

    private func transcribe(_ kind: JobKind) {
        Task { await model.transcribe(note.id, kind: kind) }
    }

    private func transcribeAgain() {
        if LibraryMapping.needsFreshConfirmation(note) { dialog = .transcribeFresh(note.id) } else { transcribe(.transcribeAgain) }
    }
}
