import Foundation
import CassiniCore
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
        let filename: String
        do {
            if format == .markdown {
                guard let options = texts.markdown else { throw ExportError.cannotSave }
                let original = notes.originalAudioURL(for: note), selected = version
                // Metadata only: do not scan/hash a multi-hour audio file or render it on the UI actor.
                data = try await Task.detached(priority: .userInitiated) {
                    var personal: [MarkdownNote] = []
                    if note.document != nil {
                        let source = CassiniDocument.readChecked(original, verify: false)
                        guard let manifest = source.manifest else { throw ExportError.cannotSave }
                        personal = MarkdownExport.notes(in: manifest)
                    }
                    return try TranscriptExports.data(note, format: format, version: selected, texts: texts, markdownNotes: personal)
                }.value
                filename = MarkdownExport.filename(note.title, untitled: options.untitled)
            } else {
                data = try TranscriptExports.data(note, format: format, version: version, texts: texts)
                filename = ExportNames.file(note.title, ext: format.fileExtension)
            }
        } catch { throw .cannotSave }
        return try await write(data, named: filename)
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
            await discardFolder(target).value
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
    @discardableResult public func discard(_ url: URL) -> Task<Void, Never> { discardFolder(url.deletingLastPathComponent()) }

    /// Removes one export's folder (from `newFolder`), then the exports folder once no other export is waiting in it.
    @discardableResult public func discardFolder(_ exportFolder: URL) -> Task<Void, Never> {
        let root = folder.standardizedFileURL
        let target = exportFolder.standardizedFileURL
        return Task(priority: .utility) {
            guard target.deletingLastPathComponent().path == root.path else { return }
            try? await CancellableFileWork.run(priority: .utility) {
                try? FileManager.default.removeItem(at: target)
                // Atomic: a newly created sibling keeps its parent.
                _ = rmdir(root.path)
            }
        }
    }

    /// The launch sweep over the notes' directories and the exports folder (`Sweep`), with the notes that were
    /// loaded as the known ones. A directory whose `note.json` could not be read still holds that file, so the sweep
    /// keeps it; one that holds nothing but stale temporary files is removed.
    @discardableResult
    public func sweep(now: Date) async -> Sweep.Report {
        let loaded = await notes.all().map(\.id)
        return Sweep(notes: notes.root, exports: folder).run(known: Set(loaded), now: now)
    }

    private func write(_ data: Data, named name: String) async throws(ExportError) -> URL {
        let target = try newFolder()
        let url = target.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            await discardFolder(target).value
            throw .cannotSave
        }
        return url
    }
}
