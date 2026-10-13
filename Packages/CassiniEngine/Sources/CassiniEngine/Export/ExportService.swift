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

    /// "Share original audio": the note's original audio byte for byte, at `<folder>/<uuid>/<ExportNames.file(title)>`
    /// with the original's extension, as Android's Save a copy names it. The note's own file is never shared in place.
    public func copyAudio(_ id: UUID) async throws(ExportError) -> URL {
        guard let note = await notes.note(id) else { throw .noNote }
        let source = notes.originalAudioURL(for: note)
        guard FileManager.default.fileExists(atPath: source.path) else { throw .noNote }
        let ext = source.pathExtension
        let name = ext.isEmpty ? ExportNames.stem(note.title) : ExportNames.file(note.title, ext: ext)
        let target = try newFolder()
        let url = target.appendingPathComponent(name)
        do {
            // A clone on APFS: no second copy of a long recording's bytes.
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            discardFolder(target)
            throw .cannotSave
        }
        return url
    }

    /// A new empty folder for one export.
    public func newFolder() throws(ExportError) -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch { throw .cannotSave }
        return url
    }

    /// Removes the export at `url` with its folder. Anything outside the exports folder, such as a note's own
    /// audio, is left alone. Discarding an export twice does nothing.
    public func discard(_ url: URL) { discardFolder(url.deletingLastPathComponent()) }

    /// Removes one export's folder (from `newFolder`), then the exports folder once no other export is waiting in it.
    public func discardFolder(_ exportFolder: URL) {
        let exportFolder = exportFolder.standardizedFileURL
        guard exportFolder.deletingLastPathComponent().path == folder.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: exportFolder)
        // rmdir removes only an empty folder, in one step: an export made meanwhile keeps the folder it is in.
        _ = rmdir(folder.path)
    }

    /// The launch sweep over the notes' directories and the exports folder (`Sweep`), with the notes that were
    /// loaded as the known ones. A directory whose `note.json` could not be read still holds that file, so the sweep
    /// keeps it; one that holds nothing but stale temporary files is removed.
    @discardableResult
    public func sweep(now: Date) async -> Sweep.Report {
        let loaded = await notes.all().map(\.id)
        return Sweep(notes: notes.root, exports: folder).run(known: Set(loaded), now: now)
    }

    private func write(_ data: Data, named name: String) throws(ExportError) -> URL {
        let target = try newFolder()
        let url = target.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            discardFolder(target)
            throw .cannotSave
        }
        return url
    }
}
