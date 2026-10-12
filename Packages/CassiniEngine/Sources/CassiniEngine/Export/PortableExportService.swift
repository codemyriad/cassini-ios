import Foundation
import CassiniNotebook

/// Writes a note as a Cassini document: its audio as Ogg Opus with every transcript version made on this device added
/// as a variant, the note's own transcript last and default.
///
/// The audio is the imported Ogg Opus when the note has one (a verified document keeps its earlier variants), else the
/// playable file encoded to Opus. Intermediate files go in `<folder>/work/`, which is removed afterwards, so no title
/// can collide with them. The source is never changed.
public struct PortableExportService: Sendable {
    private let audio: any AudioProcessing

    public init(audio: any AudioProcessing) { self.audio = audio }

    /// The exported file, `<folder>/<filename>.opus`. Nothing it made stays in `folder` when it throws.
    public func export(_ note: Note, original: URL, playable: URL, into folder: URL, filename: String) async throws -> URL {
        let work = folder.appendingPathComponent("work", isDirectory: true)
        let output = folder.appendingPathComponent(filename).appendingPathExtension("opus")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            var opus = original
            if (try? ImportClassifier.sniff(fileAt: original)) != .oggOpus {
                opus = work.appendingPathComponent("encoded.opus")
                try await audio.encodeOpus(playable, to: opus)
            }
            for (index, version) in Self.localVersions(of: note).enumerated() {
                try Task.checkCancellation()
                var snapshot = note
                snapshot.transcript = version.segments
                snapshot.speakers = version.speakers
                let next = work.appendingPathComponent("version-\(index).opus")
                try await Self.seal(snapshot, opus, next)
                opus = next
            }
            try Task.checkCancellation()
            try await Self.seal(note, opus, output)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// The versions made on this device besides the current one, oldest first; imported variants are in the source.
    static func localVersions(of note: Note) -> [TranscriptVersion] {
        (note.versions ?? []).filter { $0.id != note.selectedVersionID && $0.portableID == nil && !$0.segments.isEmpty }
    }

    private static func seal(_ note: Note, _ opus: URL, _ target: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try PortableTranscript.export(note: note, opus: opus, destination: target)
        }.value
    }
}
