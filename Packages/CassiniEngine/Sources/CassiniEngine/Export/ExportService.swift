import Foundation
import CassiniNotebook

/// Why a transcript export was not made.
public enum ExportError: Error, Equatable, Sendable {
    /// There is no such note, or no such transcript version.
    case noNote
    /// The note's transcript cannot be exported now (`TranscriptExports.availability`).
    case notAvailable(TranscriptExportAvailability)
    /// The file could not be written.
    case cannotSave
}

/// Makes the files a note is shared as, each in its own folder under `folder` (`tmp/Exports/<uuid>/`), and removes
/// them again: when the share sheet closes (`discard`), else at the next launch (`sweep`).
///
/// Transcripts are written from the stored note, so callers settle their pending edits first.
public struct ExportService: Sendable {
    /// Where exports wait for the share sheet.
    public let folder: URL
    private let notes: NoteStore

    public init(notes: NoteStore, folder: URL) { self.notes = notes; self.folder = folder }

    /// The note's transcript in `format`, at `<folder>/<uuid>/<ExportNames.file(title)>`. `version` picks a transcript
    /// version; nil, or the selected version, exports the transcript the note shows.
    public func exportTranscript(_ id: UUID, format: TranscriptFormat, version versionID: UUID? = nil,
                                 texts: ExportTexts) async throws(ExportError) -> URL {
        guard let note = await notes.note(id) else { throw .noNote }
        let availability = TranscriptExports.availability(of: note)
        guard availability == .available else { throw .notAvailable(availability) }
        var version: TranscriptVersion?
        if let versionID, versionID != note.selectedVersionID {
            guard let match = note.versions?.first(where: { $0.id == versionID }) else { throw .noNote }
            version = match
        }
        let data: Data
        do { data = try TranscriptExports.data(note, format: format, version: version, texts: texts) } catch { throw .cannotSave }
        return try write(data, named: ExportNames.file(note.title, ext: format.fileExtension))
    }

    /// A new empty folder for one export.
    public func newFolder() throws(ExportError) -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch { throw .cannotSave }
        return url
    }

    /// Removes the folder of the export at `url`, then the exports folder once no other export is waiting in it.
    /// Anything outside the exports folder, such as a note's own audio, is left alone.
    public func discard(_ url: URL) {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.deletingLastPathComponent().path == folder.standardizedFileURL.path else { return }
        let files = FileManager.default
        try? files.removeItem(at: parent)
        if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? files.removeItem(at: folder) }
    }

    /// The launch sweep over the notes' directories and the exports folder (`Sweep`). The directories of every note,
    /// readable or not, are kept.
    @discardableResult
    public func sweep(now: Date) async -> Sweep.Report {
        let loaded = await notes.all().map(\.id)
        let unreadable = await notes.loadReport.unreadable.compactMap { UUID(uuidString: $0.lastPathComponent) }
        let sweep = Sweep(notes: notes.root, exports: folder)
        return sweep.run(known: Set(loaded + unreadable), now: now)
    }

    private func write(_ data: Data, named name: String) throws(ExportError) -> URL {
        let target = try newFolder()
        let url = target.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            discard(url)
            throw .cannotSave
        }
        return url
    }
}
