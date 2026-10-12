import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// Files made from a note for the share sheet, each in its own temporary folder.
@MainActor @Observable final class ExportStore {
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let portable: PortableExportService

    init(library: LibraryStore, portable: PortableExportService) { self.library = library; self.portable = portable }

    func exportTranscript(_ note: Note, format: TranscriptFormat) throws -> URL {
        let url = try Self.newFolder().appendingPathComponent(Self.filename(note.title, fallback: "Transcript")).appendingPathExtension(format.rawValue)
        try format.data(for: note).write(to: url, options: .atomic)
        return url
    }

    /// A Cassini document of the note's audio with every local transcript version added to it.
    func exportPortable(_ id: UUID) async throws -> URL {
        await library.commit(id) { $0.saveCurrentVersion(name: "Edited transcript") }
        guard let note = library.note(id), let original = library.originalAudioURL(note), let audio = library.audioURL(note) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let folder = try Self.newFolder()
        do {
            return try await portable.export(note, original: original, playable: audio, into: folder,
                                             filename: Self.filename(note.title, fallback: "Recording"))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func newFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func filename(_ title: String, fallback: String) -> String {
        let name = String(title.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : "-" }.prefix(80))
        return name.isEmpty ? fallback : name
    }
}
