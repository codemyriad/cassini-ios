import Foundation
import Testing
@testable import CassiniNotebook

/// A note deleted for good leaves nothing a later launch could read or rebuild into a note again.
struct NoteDeletionTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteDeletion-\(UUID().uuidString)")

    @Test func deleteRemovesTheWholeDirectory() throws {
        let repository = try NoteRepository(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = Note(title: "Gone")
        try repository.save(note)
        try Data([1, 2, 3]).write(to: repository.audioURL(for: note))

        try repository.delete(note.id)

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(try repository.load().notes.isEmpty)
    }

    // ports: PurgeOrderTest#aRebuildAfterTheFileDeleteDoesNotBringTheNoteBack
    @Test func aDeleteCutShortIsNeitherReadNorKeptByTheNextLoad() throws {
        let repository = try NoteRepository(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = Note(title: "Kept")
        try repository.save(kept)
        // What a delete that Cassini closed in the middle of leaves: the renamed directory, its metadata already gone.
        let leftover = root.appendingPathComponent(UUID().uuidString + ".purging", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: leftover.appendingPathComponent("audio.m4a"))
        let unrelated = root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let report = try repository.load()

        #expect(report.notes.map(\.id) == [kept.id])
        #expect(report.unreadable.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path), "only interrupted deletes are removed")
    }
}
