import Foundation
import CassiniCore

/// What a load found: the readable notes, newest first, and the note directories whose `note.json` could not be used.
/// Those stay on disk untouched.
public struct LoadReport: Sendable, Equatable {
    public var notes: [Note]
    public var unreadable: [URL]
    public init(notes: [Note] = [], unreadable: [URL] = []) { self.notes = notes; self.unreadable = unreadable }
    public var unreadableCount: Int { unreadable.count }
}

/// One durable metadata document per note, at `<root>/<id>/note.json`. A damaged document never hides other notes.
public struct NoteRepository: Sendable {
    public static let metadataFilename = "note.json"

    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func audioURL(for note: Note) -> URL { directory(for: note.id).appendingPathComponent(note.audioFilename) }
    public func originalAudioURL(for note: Note) -> URL {
        note.originalAudioFilename.map { directory(for: note.id).appendingPathComponent($0) } ?? audioURL(for: note)
    }

    public func save(_ note: Note) throws {
        guard Self.isValid(note) else { throw RepositoryError.invalidDocument }
        let folder = directory(for: note.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try DurableFile.write(encoder.encode(note), to: folder.appendingPathComponent(Self.metadataFilename))
    }

    /// Reads every note, after finishing the deletes Cassini closed in the middle of.
    public func load() throws -> LoadReport {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        removeInterruptedDeletes(in: folders)
        var report = LoadReport()
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            do {
                var note = try JSONDecoder().decode(Note.self, from: Data(contentsOf: folder.appendingPathComponent(Self.metadataFilename)))
                if note.origin == .importedDocument {
                    let source = originalAudioURL(for: note)
                    if FileManager.default.fileExists(atPath: source.path) {
                        note.meetingTime = MeetingTime.read(CassiniDocument.readChecked(source, verify: false))
                    }
                }
                guard note.id.uuidString == folder.lastPathComponent, Self.isValid(note) else { throw RepositoryError.invalidDocument }
                report.notes.append(note)
            } catch {
                report.unreadable.append(folder)
            }
        }
        report.notes.sort { $0.sortDate > $1.sortDate }
        report.unreadable.sort { $0.lastPathComponent < $1.lastPathComponent }
        return report
    }

    /// Deletes the note's directory. It is first renamed out of the notes (`<id>.purging`), in one atomic step, so a
    /// delete that Cassini closed in the middle of never leaves audio without its `note.json` for a launch to rebuild
    /// into a note again; the next `load` finishes it. A directory that is already gone counts as deleted, as on
    /// Android.
    public func delete(_ id: UUID) throws {
        let fileManager = FileManager.default
        let doomed = purgingDirectory(for: id)
        if fileManager.fileExists(atPath: doomed.path) { try fileManager.removeItem(at: doomed) }
        let directory = directory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.moveItem(at: directory, to: doomed)
        try? fileManager.removeItem(at: doomed) // Gone from the notes already; a leftover goes at the next load.
    }

    private static let purgingSuffix = ".purging"

    private func purgingDirectory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString + Self.purgingSuffix, isDirectory: true)
    }

    /// Finishes the deletes that Cassini closed in the middle of.
    private func removeInterruptedDeletes(in folders: [URL]) {
        for folder in folders where folder.lastPathComponent.hasSuffix(Self.purgingSuffix)
            && UUID(uuidString: String(folder.lastPathComponent.dropLast(Self.purgingSuffix.count))) != nil {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A file name a note may point at inside its own directory: no paths, no hidden files, never the metadata itself.
    public static func isAllowedFilename(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 64, name != metadataFilename else { return false }
        func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        return isASCIIAlphanumeric(first)
            && name.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    static func isValid(_ note: Note) -> Bool {
        isAllowedFilename(note.audioFilename)
            && (note.originalAudioFilename.map(isAllowedFilename) ?? true)
            && note.duration.isFinite && note.duration >= 0
    }
}

public enum RepositoryError: LocalizedError {
    case invalidDocument
    public var errorDescription: String? { "This recording’s metadata is not supported or is damaged. Its files have been preserved." }
}
