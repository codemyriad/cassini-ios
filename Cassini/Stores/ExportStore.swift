import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// Files made from a note for the share sheet, each in its own folder under `tmp/Exports/`, removed when the sheet
/// closes or at the next launch.
@MainActor @Observable final class ExportStore {
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let service: ExportService?
    @ObservationIgnored private let portable: PortableExportService
    @ObservationIgnored private let texts: ExportTexts

    init(library: LibraryStore, portable: PortableExportService, folder: URL, locale: Locale, timeZone: TimeZone) {
        self.library = library
        self.portable = portable
        service = library.noteStore.map { ExportService(notes: $0, folder: folder) }
        texts = ExportCopy.texts(locale: locale, timeZone: timeZone)
    }

    /// The note's transcript in `format`, once the edits on screen are stored.
    func exportTranscript(_ id: UUID, format: TranscriptFormat) async throws(ExportError) -> URL {
        guard let service else { throw .cannotSave }
        await library.settle()
        return try await service.exportTranscript(id, format: format, texts: texts)
    }

    /// A Cassini document of the note's audio with every local transcript version added to it.
    func exportPortable(_ id: UUID) async throws -> URL {
        await library.commit(id) { $0.saveCurrentVersion(name: "Edited transcript") }
        guard let service, let note = library.note(id), let original = library.originalAudioURL(note),
              let audio = library.audioURL(note) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let folder = try service.newFolder()
        do {
            return try await portable.export(note, original: original, playable: audio, into: folder,
                                             filename: ExportNames.stem(note.title))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Removes an export once the share sheet is done with it.
    func discard(_ url: URL) { service?.discard(url) }

    /// The launch sweep: exports left from the last run and stale temporary files in the notes' directories.
    func sweep(now: Date) async { await service?.sweep(now: now) }
}
