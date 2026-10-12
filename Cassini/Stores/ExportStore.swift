import Foundation
import Observation
import CassiniAudio
import CassiniNotebook

/// Files made from a note for the share sheet, each in its own temporary folder.
@MainActor @Observable final class ExportStore {
    @ObservationIgnored private let library: LibraryStore

    init(library: LibraryStore) { self.library = library }

    func exportTranscript(_ note: Note, format: TranscriptFormat) throws -> URL {
        let url = try Self.newFolder().appendingPathComponent(Self.filename(note.title, fallback: "Transcript")).appendingPathExtension(format.rawValue)
        try format.data(for: note).write(to: url, options: .atomic)
        return url
    }

    /// A Cassini document of the note's audio with every local transcript version appended to it.
    func exportPortable(_ id: UUID) async throws -> URL {
        await library.commit(id) { $0.saveCurrentVersion(name: "Edited transcript") }
        guard let note = library.note(id), let original = library.originalAudioURL(note), let audio = library.audioURL(note) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let folder = try Self.newFolder()
        let output = folder.appendingPathComponent(Self.filename(note.title, fallback: "Recording")).appendingPathExtension("opus")
        return try await Task.detached(priority: .userInitiated) {
            let encoded = folder.appendingPathComponent("encoded-audio.opus")
            var intermediates = [encoded]
            defer { for url in intermediates { try? FileManager.default.removeItem(at: url) } }
            do {
                var opus: URL
                if ["opus", "ogg"].contains(original.pathExtension.lowercased()) { opus = original }
                else { try OpusAudio.encode(audio, to: encoded); opus = encoded }
                for version in note.versions ?? [] where version.id != note.selectedVersionID && version.portableID == nil && !version.segments.isEmpty {
                    try Task.checkCancellation()
                    var snapshot = note; snapshot.transcript = version.segments; snapshot.speakers = version.speakers
                    let next = folder.appendingPathComponent("version-\(version.id).opus")
                    intermediates.append(next)
                    try PortableTranscript.export(note: snapshot, opus: opus, destination: next)
                    opus = next
                }
                try Task.checkCancellation()
                try PortableTranscript.export(note: note, opus: opus, destination: output)
                return output
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        }.value
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
