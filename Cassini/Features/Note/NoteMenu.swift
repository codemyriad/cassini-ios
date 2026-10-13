import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The "…" menu of a note (Android's Note actions sheet as a system menu): star, speakers, versions, rename, document
/// info, the exports, the transcription row for the note's job, and Move to Recently Deleted.
struct NoteMenu: View {
    let note: Note
    let transcribeRow: TranscribeRow?
    /// A Cassini document is being prepared.
    let exportingDocument: Bool
    let perform: (NoteMenuAction) -> Void
    @Environment(RecordingStore.self) private var recording

    var body: some View {
        let finishing = recording.finishingNoteID == note.id
        Menu {
            Button(note.isFavorite ? NoteCopy.removeStar : NoteCopy.star, systemImage: note.isFavorite ? "star.slash" : "star") {
                perform(.toggleStar)
            }
            if note.hasDocument {
                Button(NoteCopy.speakers, systemImage: "person.2") { perform(.speakers) }
                if (note.versions ?? []).count > 0 {
                    Button(NoteCopy.versions, systemImage: "clock.arrow.circlepath") { perform(.versions) }
                }
            }
            Button(NoteCopy.rename, systemImage: "pencil") { perform(.rename) }
            if note.hasDocument { Button(NoteCopy.documentInfo, systemImage: "info.circle") { perform(.documentInfo) } }
            Divider()
            let unavailable = ExportCopy.reason(TranscriptExports.availability(of: note))
            Menu {
                // A disabled submenu still opens on iOS, so its rows are disabled as well.
                ForEach(TranscriptFormat.allCases) { format in
                    Button(ExportCopy.title(format)) { perform(.exportTranscript(format)) }.disabled(unavailable != nil)
                }
            } label: {
                Text(NoteCopy.exportTranscript)
                if let unavailable { Text(unavailable) }
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(unavailable != nil)
            Button(exportingDocument ? NoteCopy.preparingDocument : NoteCopy.exportDocument, systemImage: "doc.badge.arrow.up") {
                perform(.exportDocument)
            }
            .disabled(exportingDocument || note.transcript.isEmpty || transcribeRow == .stop || finishing)
            Button(NoteCopy.shareAudio, systemImage: "waveform") { perform(.shareAudio) }.disabled(finishing)
            if let transcribeRow {
                Divider()
                transcription(transcribeRow, disabled: finishing)
            }
            if !note.isRecording {
                Divider()
                Button(TrashCopy.moveToTrash, systemImage: "trash", role: .destructive) { perform(.moveToTrash) }
            }
        } label: {
            Image(systemName: "ellipsis").frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
        }
        .accessibilityLabel(NoteCopy.moreActions)
        .accessibilityIdentifier("noteActions")
    }

    @ViewBuilder private func transcription(_ row: TranscribeRow, disabled: Bool) -> some View {
        switch row {
        case .transcribe:
            Button(NoteCopy.transcribe, systemImage: "text.badge.waveform") { perform(.transcribe) }.disabled(disabled)
        case .transcribeAgain:
            Button(NoteCopy.transcribeAgain, systemImage: "arrow.clockwise") { perform(.transcribeAgain) }.disabled(disabled)
        case .transcribeAgainUnavailable:
            Button {} label: {
                Text(NoteCopy.transcribeAgain)
                Text(NoteCopy.noNewVersion)
                Image(systemName: "arrow.clockwise")
            }
            .disabled(true)
        case .stop:
            Button(NoteCopy.stopKeepProgress, systemImage: "stop.circle") { perform(.stop) }
        case .removeFromQueue:
            Button(NoteCopy.removeFromQueue, systemImage: "minus.circle") { perform(.removeFromQueue) }
        case .resumeOrStartOver:
            Button(NoteCopy.resume, systemImage: "play.circle") { perform(.resume) }
            Button(NoteCopy.startOver, systemImage: "arrow.counterclockwise") { perform(.startOver) }
        }
    }
}
