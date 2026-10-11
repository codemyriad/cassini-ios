import Foundation

/// One atomic metadata document per recording. A damaged document never hides other notes.
public struct NoteRepository: Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func audioURL(for note: Note) -> URL { directory(for: note.id).appendingPathComponent(note.audioFilename) }
    public func save(_ note: Note) throws {
        guard note.schemaVersion == 1, !note.audioFilename.contains("/"), !note.audioFilename.contains("..") else {
            throw RepositoryError.invalidDocument
        }
        let folder = directory(for: note.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(note).write(to: folder.appendingPathComponent("note.json"), options: .atomic)
    }
    public func load() throws -> (notes: [Note], unreadableCount: Int) {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var notes: [Note] = []; var unreadable = 0
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            do {
                let note = try JSONDecoder().decode(Note.self, from: Data(contentsOf: folder.appendingPathComponent("note.json")))
                guard note.schemaVersion == 1, note.id.uuidString == folder.lastPathComponent,
                      !note.audioFilename.contains("/"), !note.audioFilename.contains(".."),
                      note.duration.isFinite, note.duration >= 0 else { throw RepositoryError.invalidDocument }
                notes.append(note)
            } catch { unreadable += 1 }
        }
        return (notes.sorted { $0.createdAt > $1.createdAt }, unreadable)
    }
    public func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(for: id)) }
}

public enum RepositoryError: LocalizedError {
    case invalidDocument
    public var errorDescription: String? { "This recording’s metadata is not supported or is damaged. Its files have been preserved." }
}
