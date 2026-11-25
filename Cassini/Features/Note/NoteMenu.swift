import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The "…" menu of a note (Android's Note actions sheet as a system menu): star, speakers, versions, rename, document
/// info, the exports, the transcription row for the note's job, and Move to Recently Deleted.
struct NoteMenu: View {
    let note: Note
    let transcribeRow: TranscribeRow?
    /// The Library's form of the row, for Transcribe again's caption.
    var transcribeAction: TranscribeAction?
    /// A Cassini document is being prepared.
    let exportingDocument: Bool
    @Binding var exportOpen: Bool
    /// Remains true through the sheet dismissal animation, until sharing starts in onDismiss.
    @Binding var exportPresented: Bool
    let perform: (NoteMenuAction) -> Void
    @Environment(RecordingStore.self) private var recording
    @Environment(ProcessingStore.self) private var processing
    private var speechUnavailable: Bool { processing.models.speechUnavailability == .model }

    @State private var confirmedExport: ExportSheetState.Choice?

    var body: some View {
        let finishing = recording.finishingNoteID == note.id
        Menu {
            Button(note.isFavorite ? NoteCopy.removeStar : NoteCopy.star, systemImage: note.isFavorite ? "star.slash" : "star") {
                perform(.toggleStar)
            }
            if note.hasDocument || note.speakers?.isEmpty == false {
                Button(NoteCopy.speakers, systemImage: "person.2") { perform(.speakers) }
                    .accessibilityIdentifier("speakersButton")
            }
            if note.hasDocument {
                if (note.versions ?? []).count > 0 {
                    Button(NoteCopy.versions, systemImage: "clock.arrow.circlepath") { perform(.versions) }
                }
            }
            Button(NoteCopy.rename, systemImage: "pencil") { perform(.rename) }
            if note.hasDocument { Button(NoteCopy.documentInfo, systemImage: "info.circle") { perform(.documentInfo) } }
            Divider()
            Button(LibraryCopy.export, systemImage: "square.and.arrow.up") {
                exportPresented = true
                exportOpen = true
            }
                .accessibilityIdentifier("exportOpen")
                .disabled(exportingDocument || finishing || note.isRecording)
            if let transcribeRow {
                Divider()
                transcription(transcribeRow, disabled: finishing)
            }
            if !note.isRecording {
                Divider()
                Button(TrashCopy.moveToTrash, systemImage: "trash", role: .destructive) { perform(.moveToTrash) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Color.ink)
        }
        .sheet(isPresented: $exportOpen, onDismiss: shareConfirmed) {
            ExportFormatSheet(note: note, jobPending: transcribeRow == .stop || transcribeRow == .removeFromQueue) {
                confirmedExport = $0
            }
        }
        .accessibilityLabel(NoteCopy.shareAndMore)
        .accessibilityIdentifier("noteActions")
    }

    private func shareConfirmed() {
        defer { exportPresented = false }
        guard let choice = confirmedExport else { return }
        confirmedExport = nil
        if let format = choice.transcriptFormat { perform(.exportTranscript(format)) }
        else if choice == .originalAudio { perform(.shareAudio) }
        else { perform(.exportDocument) }
    }

    @ViewBuilder private func transcription(_ row: TranscribeRow, disabled: Bool) -> some View {
        switch row {
        case .transcribe:
            Button { perform(.transcribe) } label: {
                Text(NoteCopy.transcribe)
                if speechUnavailable { Text(NoteCopy.speechUnavailable) }
                Image(systemName: TranscribeSymbol.name)
            }
            .disabled(disabled || speechUnavailable)
            .accessibilityLabel(Text(verbatim: [NoteCopy.transcribe, speechUnavailable ? NoteCopy.speechUnavailable : nil].compactMap { $0 }.joined(separator: ". ")))
        case .transcribeAgain:
            Button { perform(.transcribeAgain) } label: {
                Text(NoteCopy.transcribeAgain)
                if speechUnavailable { Text(NoteCopy.speechUnavailable) }
                else if let againCaption { Text(againCaption) }
                Image(systemName: "arrow.clockwise")
            }
            .disabled(disabled || speechUnavailable)
            .accessibilityIdentifier("transcribeAgain")
            .accessibilityLabel(Text(verbatim: [NoteCopy.transcribeAgain, speechUnavailable ? NoteCopy.speechUnavailable : againCaption].compactMap { $0 }.joined(separator: ". ")))
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

    private var againCaption: String? {
        guard case .transcribeAgain(let version, let namesCarry)? = transcribeAction else { return nil }
        return LibraryCopy.addsVersion(version) + (namesCarry ? " " + LibraryCopy.namesCarry : "")
    }
}

/// The symbol of Transcribe in the note's menu and the Library's. The note's menu named "text.badge.waveform", which is
/// no SF Symbol on any iOS, so its row had no icon; `TranscribeSymbolTests` checks this one exists on the running OS.
enum TranscribeSymbol {
    static let name = "text.badge.plus"
}
