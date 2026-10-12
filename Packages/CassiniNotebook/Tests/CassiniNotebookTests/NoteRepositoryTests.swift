import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct NoteRepositoryTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    /// Writes `fields` as the note.json of a new folder and returns the folder.
    private func write(_ json: String, id: UUID = UUID()) throws -> URL {
        let folder = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("note.json"))
        return folder
    }

    private func note(id: UUID, extra: String = "", schema: Int = 2, duration: Double = 1, audio: String = "audio.m4a") -> String {
        #"{"schemaVersion":\#(schema),"id":"\#(id)","title":"T","createdAt":0,"audioFilename":"\#(audio)","duration":\#(duration),"audio":{"plain":{}},"origin":"recorded"\#(extra)}"#
    }

    @Test func unreadableNotesAreCountedAndKeptOnDisk() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let good = UUID()
        _ = try write(note(id: good), id: good)
        let rejected = try [
            write(note(id: UUID(), schema: 3)),                                   // a newer schema
            write(note(id: UUID())),                                              // an id that is not its folder
            { let id = UUID(); return try write(note(id: id, duration: -1), id: id) }(),
            { let id = UUID(); return try write(note(id: id, extra: #","originalAudioFilename":"../x.opus""#), id: id) }(),
            { let id = UUID(); return try write(note(id: id, audio: "note.json"), id: id) }(),
            write("not json"),
        ]
        let report = try repository.load()
        #expect(report.notes.map(\.id) == [good])
        #expect(report.unreadableCount == rejected.count)
        for folder in rejected {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("note.json").path))
        }
    }

    @Test func filenamesFollowTheAllowlist() {
        for name in ["audio.m4a", "capture.caf", "playback.caf", "a", "A-1_b.opus", String(repeating: "a", count: 64)] {
            #expect(NoteRepository.isAllowedFilename(name), "\(name)")
        }
        for name in ["", ".", "..", ".hidden", "note.json", "a/b", "../a", "a b", "è.m4a", "-a", String(repeating: "a", count: 65)] {
            #expect(!NoteRepository.isAllowedFilename(name), "\(name)")
        }
    }

    @Test func anInvalidNoteIsNotSaved() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        #expect(throws: RepositoryError.self) { try repository.save(Note(title: "Unsafe", audioFilename: "note.json")) }
        var original = Note(title: "Unsafe")
        original.originalAudioFilename = "."
        #expect(throws: RepositoryError.self) { try repository.save(original) }
    }
}
