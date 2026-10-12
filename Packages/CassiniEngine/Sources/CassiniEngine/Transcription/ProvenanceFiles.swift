import Foundation
import CassiniNotebook

/// Where the latest on-device run's `ProvenanceRecord` is kept for exports.
public protocol ProvenanceStoring: Sendable {
    /// The note's record; nil when it has none or it cannot be read.
    func load(_ noteID: UUID) -> ProvenanceRecord?
    func save(_ record: ProvenanceRecord, for noteID: UUID) throws
}

extension ProvenanceStoring {
    /// What an export writes as `provenance.speechToText` for `note`: nil unless its transcript is the run's.
    public func provenance(for note: Note) -> TranscriptProvenance? {
        load(note.id)?.provenance(for: note.transcript)
    }
}

/// `<note folder>/provenance.json`, beside the note so that it goes with it.
public struct ProvenanceFiles: ProvenanceStoring {
    public static let filename = "provenance.json"

    private let noteDirectory: @Sendable (UUID) -> URL

    public init(noteDirectory: @escaping @Sendable (UUID) -> URL) { self.noteDirectory = noteDirectory }

    public init(notes: NoteStore) { self.init(noteDirectory: { notes.directory(for: $0) }) }

    public func url(for noteID: UUID) -> URL { noteDirectory(noteID).appendingPathComponent(Self.filename) }

    public func load(_ noteID: UUID) -> ProvenanceRecord? {
        guard let data = try? Data(contentsOf: url(for: noteID)) else { return nil }
        return try? JSONDecoder().decode(ProvenanceRecord.self, from: data)
    }

    public func save(_ record: ProvenanceRecord, for noteID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url(for: noteID), options: .atomic)
    }
}
