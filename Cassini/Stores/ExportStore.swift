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
    @ObservationIgnored private let bulk: BulkExportService?
    @ObservationIgnored private var zipTask: Task<Void, Never>?
    private(set) var zipProgress: BulkProgress?
    private(set) var zipExported = 0
    var zipShareItem: ShareItem?
    var zipFailure: String?
    @ObservationIgnored private let texts: ExportTexts
    @ObservationIgnored private let ready: @MainActor () async -> Void

    /// `texts` are the localized lines of every export (`ExportCopy.texts`); the sealed document labels passages without
    /// a speaker with `texts.unassignedLabel`, as the transcript exports do. `ready` returns once the launch work has
    /// run, so the launch sweep never removes an export being shared.
    init(library: LibraryStore, audio: any AudioProcessing, folder: URL, texts: ExportTexts,
         ready: @escaping @MainActor () async -> Void) {
        self.library = library
        self.ready = ready
        self.texts = texts
        service = library.noteStore.map { ExportService(notes: $0, folder: folder) }
        let portableService = library.noteStore.map {
            PortableExportService(audio: audio, provenance: ProvenanceFiles(notes: $0), unassignedLabel: texts.unassignedLabel)
        }
        portable = portableService
        bulk = library.noteStore.flatMap { notes in
            portableService.map { BulkExportService(notes: notes, portable: $0, folder: folder) }
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
            service.discardFolder(folder)
            throw error
        }
    }

    /// A single cancellable archive operation, shared through the existing sheet/cleanup path.
    func exportZIP(_ ids: [UUID]) {
        guard zipTask == nil, !ids.isEmpty else { return }
        zipProgress = BulkProgress(completed: 0, total: ids.count)
        zipExported = 0
        zipFailure = nil
        zipTask = Task {
            defer { zipTask = nil; zipProgress = nil }
            do {
                await ready()
                await library.settle()
                try Task.checkCancellation()
                guard let bulk else { throw ExportError.cannotSave }
                for id in ids {
                    try Task.checkCancellation()
                    if let note = library.note(id), !note.transcript.isEmpty {
                        guard await library.commit(id, { $0.saveCurrentVersion(.editedTranscript) }) != nil else {
                            throw ExportError.cannotSave
                        }
                    }
                }
                let url = try await bulk.export(ids) { [weak self] completed, total in
                    await self?.setZIPProgress(completed: completed, total: total)
                }
                if Task.isCancelled { discard(url); throw CancellationError() }
                zipExported = ids.count
                zipShareItem = shareItem(url)
            } catch is CancellationError {
                // The engine removes partial output; completed notes and their versions remain intact.
            } catch { zipFailure = ExportCopy.notSaved }
        }
    }

    private func setZIPProgress(completed: Int, total: Int) {
        zipProgress = BulkProgress(completed: completed, total: total)
    }

    func cancelZIP() { zipTask?.cancel() }
    func settleZIP() async { await zipTask?.value }

    /// Removes an export once the share sheet is done with it.
    func discard(_ url: URL) { service?.discard(url) }

    /// The share sheet's item for the export at `url`, removed once the sheet is dismissed.
    func shareItem(_ url: URL) -> ShareItem { ShareItem(url: url) { [weak self] in self?.discard(url) } }

    /// The launch sweep: exports left from the last run and stale temporary files in the notes' directories.
    func sweep(now: Date) async { await service?.sweep(now: now) }
}
