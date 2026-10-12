import SwiftUI
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
    @Environment(TrashStore.self) private var trash
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
            Menu("Export transcript", systemImage: "square.and.arrow.up") {
                ForEach(TranscriptFormat.allCases) { format in Button(format.title) { export(format) } }
            }.disabled(note.transcript.isEmpty)
            Button(exportingDocument ? "Preparing Cassini document…" : "Export Cassini document", systemImage: "doc.badge.arrow.up") { exportDocument() }
                .disabled(exportingDocument || note.transcript.isEmpty || note.status == .transcribing || finishing)
            Button("Share original audio", systemImage: "waveform") {
                if let url = library.originalAudioURL(note) { shareItem = ShareItem(url: url) }
            }.disabled(finishing)
            Button("Transcribe again", systemImage: "arrow.clockwise", action: requestTranscription)
                .disabled(note.status == .transcribing || note.status == .queued || finishing || !note.audio.isPlayable)
            Divider()
            Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) {
                Task { await trash.moveToTrash(note.id) }
            }
        } label: { Image(systemName: "ellipsis").frame(minWidth: 32, minHeight: 32) }.accessibilityLabel("Recording actions")
    }

    private func export(_ format: TranscriptFormat) {
        do { shareItem = ShareItem(url: try exports.exportTranscript(note, format: format)) }
        catch { errors.present(error.localizedDescription) }
    }

    private func exportDocument() {
        exportingDocument = true
        Task {
            do { shareItem = ShareItem(url: try await exports.exportPortable(note.id)) }
            catch { errors.present(error.localizedDescription) }
            exportingDocument = false
        }
    }
}
