import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The "…" menu of a note.
struct NoteMenu: View {
    let note: Note
    @Binding var renaming: Bool
    @Binding var showingSpeakers: Bool
    @Binding var showingVersions: Bool
    @Binding var shareItem: ShareItem?
    let requestTranscription: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(TrashService.self) private var trash
    @Environment(ExportStore.self) private var exports
    @Environment(RecordingStore.self) private var recording
    @Environment(ErrorPresenter.self) private var errors
    @State private var exportingDocument = false

    var body: some View {
        let finishing = recording.finishingNoteID == note.id
        Menu {
            Button(note.isFavorite ? "Remove star" : "Star recording", systemImage: note.isFavorite ? "star.slash" : "star") {
                library.update(note.id) { $0.isFavorite.toggle() }
            }
            Button("Speakers", systemImage: "person.2") { showingSpeakers = true }
            Button("Transcript versions", systemImage: "clock.arrow.circlepath") { showingVersions = true }
            Button("Rename", systemImage: "pencil") { renaming = true }
            let unavailable = ExportCopy.reason(TranscriptExports.availability(of: note))
            Menu {
                ForEach(TranscriptFormat.allCases) { format in Button(ExportCopy.title(format)) { export(format) } }
            } label: {
                Text("Export transcript")
                if let unavailable { Text(unavailable) }
                Image(systemName: "square.and.arrow.up")
            }.disabled(unavailable != nil)
            Button(exportingDocument ? "Preparing Cassini document…" : "Export Cassini document", systemImage: "doc.badge.arrow.up") { exportDocument() }
                .disabled(exportingDocument || note.transcript.isEmpty || note.status == .transcribing || finishing)
            Button("Share original audio", systemImage: "waveform") {
                if let url = library.originalAudioURL(note) { shareItem = ShareItem(url: url) }
            }.disabled(finishing)
            Button("Transcribe again", systemImage: "arrow.clockwise", action: requestTranscription)
                .disabled(note.status == .transcribing || note.status == .queued || finishing || !note.audio.isPlayable)
            Divider()
            Button(TrashCopy.moveToTrash, systemImage: "trash", role: .destructive) {
                Task { await trash.requestTrash(note.id) }
            }
        } label: { Image(systemName: "ellipsis").frame(minWidth: 32, minHeight: 32) }.accessibilityLabel("Recording actions")
    }

    private func export(_ format: TranscriptFormat) {
        Task {
            do throws(ExportError) { share(try await exports.exportTranscript(note.id, format: format)) }
            catch { errors.present(ExportCopy.message(error)) }
        }
    }

    /// Offers an export, removing it once the share sheet is gone.
    private func share(_ url: URL) { shareItem = exports.shareItem(url) }

    private func exportDocument() {
        exportingDocument = true
        Task {
            do { share(try await exports.exportPortable(note.id)) }
            catch { errors.present(error.localizedDescription) }
            exportingDocument = false
        }
    }
}
