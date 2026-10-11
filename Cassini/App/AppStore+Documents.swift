import Foundation
import CassiniNotebook
import CassiniAudio

extension AppStore {
    func originalAudioURL(_ note: Note) -> URL? {
        guard let repository else { return nil }
        return note.originalAudioFilename.map { repository.directory(for: note.id).appendingPathComponent($0) } ?? repository.audioURL(for: note)
    }
    func exportPortable(_ id: UUID) async throws -> URL {
        update(id) { $0.saveCurrentVersion(name: "Edited transcript") }
        guard let note = note(id), let original = originalAudioURL(note), let audio = audioURL(note) else { throw CocoaError(.fileReadNoSuchFile) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await Task.detached(priority: .userInitiated) {
            let filename = String(note.title.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : "-" }.prefix(80))
            let output = folder.appendingPathComponent(filename.isEmpty ? "Recording" : filename).appendingPathExtension("opus")
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
}
