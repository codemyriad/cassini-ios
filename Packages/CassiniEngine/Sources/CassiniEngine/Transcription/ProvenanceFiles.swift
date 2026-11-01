import Foundation
import CassiniNotebook

/// Where the `ProvenanceRecord` of each on-device run of a note is kept for exports, so that a version keeps its own
/// run's record (and language, D53.2) after a later run.
public protocol ProvenanceStoring: Sendable {
    /// The note's run records, oldest first; empty when it has none or they cannot be read.
    func records(_ noteID: UUID) -> [ProvenanceRecord]
    /// Keeps `record` as the note's newest (`ProvenanceRecord.keeping`).
    func save(_ record: ProvenanceRecord, for noteID: UUID) throws
}

extension ProvenanceStoring {
    /// The note's latest run record; nil when it has none.
    public func load(_ noteID: UUID) -> ProvenanceRecord? { records(noteID).last }

    /// The newest run record that made `transcript`'s words; nil when no run of the note made them.
    public func record(of transcript: [TranscriptSegment], in noteID: UUID) -> ProvenanceRecord? {
        ProvenanceRecord.newest(describing: transcript, in: records(noteID))
    }

    /// What an export writes as `provenance.speechToText` for `note`: nil unless its transcript is a run's.
    public func provenance(for note: Note) -> TranscriptProvenance? {
        record(of: note.transcript, in: note.id)?.provenance(for: note.transcript)
    }
}

/// `<note folder>/provenance.json`, beside the note so that it goes with it: a JSON array of the run records, oldest
/// first.
public struct ProvenanceFiles: ProvenanceStoring {
    public static let filename = "provenance.json"

    private let noteDirectory: @Sendable (UUID) -> URL

    public init(noteDirectory: @escaping @Sendable (UUID) -> URL) { self.noteDirectory = noteDirectory }

    public init(notes: NoteStore) { self.init(noteDirectory: { notes.directory(for: $0) }) }

    public func url(for noteID: UUID) -> URL { noteDirectory(noteID).appendingPathComponent(Self.filename) }

    public func records(_ noteID: UUID) -> [ProvenanceRecord] {
        guard let data = try? Data(contentsOf: url(for: noteID)) else { return [] }
        return (try? JSONDecoder().decode([ProvenanceRecord].self, from: data)) ?? []
    }

    public func save(_ record: ProvenanceRecord, for noteID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFile.write(encoder.encode(ProvenanceRecord.keeping(record, in: records(noteID))), to: url(for: noteID))
    }
}
