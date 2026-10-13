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
    @ObservationIgnored private let ready: @MainActor () async -> Void

    /// `ready` returns once the launch work has run, so the launch sweep never removes an export being shared.
    init(library: LibraryStore, audio: any AudioProcessing, folder: URL, locale: Locale, timeZone: TimeZone,
         ready: @escaping @MainActor () async -> Void) {
        self.library = library
        self.ready = ready
        service = library.noteStore.map { ExportService(notes: $0, folder: folder) }
        portable = library.noteStore.map { PortableExportService(audio: audio, provenance: ProvenanceFiles(notes: $0)) }
        texts = ExportCopy.texts(locale: locale, timeZone: timeZone)
    }

    /// The note's transcript in `format`, once the edits on screen are stored.
    func exportTranscript(_ id: UUID, format: TranscriptFormat) async throws(ExportError) -> URL {
        guard let service else { throw .cannotSave }
        await ready()
        await library.settle()
        return try await service.exportTranscript(id, format: format, texts: texts)
    }

    /// A Cassini document of the note's audio with every local transcript version added to it.
    func exportPortable(_ id: UUID) async throws -> URL {
        await ready()
        await library.commit(id) { $0.saveCurrentVersion(name: "Edited transcript") }
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

    /// Removes an export once the share sheet is done with it.
    func discard(_ url: URL) { service?.discard(url) }

    /// The share sheet's item for the export at `url`, removed once the sheet is dismissed.
    func shareItem(_ url: URL) -> ShareItem { ShareItem(url: url) { [weak self] in self?.discard(url) } }

    /// The launch sweep: exports left from the last run and stale temporary files in the notes' directories.
    func sweep(now: Date) async { await service?.sweep(now: now) }
}
