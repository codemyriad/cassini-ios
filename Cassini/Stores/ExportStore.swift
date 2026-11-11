import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// Files made from a note for the share sheet, each in its own folder under `tmp/Exports/`, removed when the sheet
/// closes or at the next launch. Exports wait for the launch work, whose sweep clears `tmp/Exports`.
@MainActor @Observable final class ExportStore {
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let service: ExportService?
    @ObservationIgnored private let portable: PortableExportService?
    @ObservationIgnored private let texts: ExportTexts
    @ObservationIgnored private var discardTask: Task<Void, Never>?
    @ObservationIgnored private let ready: @MainActor () async -> Void
    @ObservationIgnored private let audioReady: @MainActor () async -> Void

    /// `texts` are the localized lines of every export (`ExportCopy.texts`); the sealed document labels passages without
    /// a speaker with `texts.unassignedLabel`, as the transcript exports do. `ready` returns once the launch work has
    /// run, so the launch sweep never removes an export being shared. `audioReady` waits for pending recording
    /// finalization before a bulk member resolves its current source path.
    init(library: LibraryStore, audio: any AudioProcessing, folder: URL, texts: ExportTexts,
         audioReady: @escaping @MainActor () async -> Void = {}, ready: @escaping @MainActor () async -> Void) {
        self.library = library
        self.ready = ready
        self.audioReady = audioReady
        self.texts = texts
        service = library.noteStore.map { ExportService(notes: $0, folder: folder) }
        portable = library.noteStore.map {
            PortableExportService(audio: audio, provenance: ProvenanceFiles(notes: $0), unassignedLabel: texts.unassignedLabel)
        }
    }

    /// The note's transcript in `format`, once the edits on screen are stored.
    func exportTranscript(_ id: UUID, format: TranscriptFormat) async throws(ExportError) -> URL {
        guard let service else { throw .cannotSave }
        await ready()
        await library.settle()
        return try await service.exportTranscript(id, format: format, texts: texts)
    }

    /// A copy of the note's original audio named after its title, for "Share original audio".
    func copyAudio(_ id: UUID) async throws(ExportError) -> URL {
        guard let service else { throw .cannotSave }
        await ready()
        return try await service.copyAudio(id)
    }

    /// A Cassini document of the note's audio with every local transcript version added to it.
    func exportPortable(_ id: UUID) async throws -> URL {
        await ready()
        await library.commit(id) { $0.saveCurrentVersion(.editedTranscript) }
        guard let service, let portable, let note = library.note(id), let original = library.originalAudioURL(note),
              let audio = library.audioURL(note) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let folder = try service.newFolder()
        do {
            return try await portable.export(note, original: original, playable: audio, into: folder,
                                             filename: ExportNames.stem(note.title))
        } catch {
            await service.discardFolder(folder).value
            throw error
        }
    }

    /// Removes an export once the share sheet is done with it.
    func discard(_ url: URL) {
        guard let service else { return }
        let previous = discardTask
        let current = service.discard(url)
        discardTask = Task { await previous?.value; await current.value }
    }
    /// Event fence for callers that need all share-sheet/cancel cleanup to have finished.
    func waitForDiscards() async { await discardTask?.value }

    /// The share sheet's item for the export at `url`, removed once the sheet is dismissed.
    func shareItem(_ url: URL) -> ShareItem { ShareItem(url: url) { [weak self] in self?.discard(url) } }

    /// The launch sweep: exports left from the last run and stale temporary files in the notes' directories.
    func sweep(now: Date) async { await service?.sweep(now: now) }

    /// D96: the complete selection. Audio-only notes keep their original container unchanged.
    func exportArchive(_ ids: [UUID], progress: @escaping @Sendable (TransferProgress) async -> Void) async throws -> URL {
        await ready()
        await library.settle()
        guard let service, let portable else { throw ExportError.cannotSave }
        let notes = ids.compactMap { library.note($0) }.filter(ArchiveSelection.isExportable)
        guard notes.count == ids.count else { throw ExportError.noNote }
        let batch = BulkExportService(folder: service.folder) { [library, portable, audioReady] selected, folder in
            await audioReady()
            try Task.checkCancellation()
            let (note, original, audio) = try await MainActor.run {
                guard let note = library.note(selected.id), ArchiveSelection.isExportable(note),
                      let original = library.originalAudioURL(note), let audio = library.audioURL(note) else {
                    throw ExportError.noNote
                }
                return (note, original, audio)
            }
            return try await portable.archiveSnapshot(note, original: original, playable: audio, into: folder)
        }
        return try await batch.export(notes, progress: progress)
    }
}
