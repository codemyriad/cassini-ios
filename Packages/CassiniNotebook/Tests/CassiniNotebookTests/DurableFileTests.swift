import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct DurableFileTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    private func contents(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func writeReplacesTheFileAndLeavesNoTemporaryFile() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note.json")
        try DurableFile.write(Data("first".utf8), to: url)
        try DurableFile.write(Data("second, longer".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("second, longer".utf8))
        #expect(try contents(root) == ["note.json"])
    }

    @Test func aStaleTemporaryFileIsOverwritten() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("jobs.json")
        try Data("a torn write from a crash, much longer than the new one".utf8)
            .write(to: root.appendingPathComponent("jobs.json.tmp"))
        try DurableFile.write(Data("{}".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("{}".utf8))
        #expect(try contents(root) == ["jobs.json"])
    }

    @Test func aFailedWriteKeepsThePreviousFile() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("voices.json")
        try DurableFile.write(Data("kept".utf8), to: url)
        // A directory where the temporary file goes makes the write fail before the rename.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("voices.json.tmp"), withIntermediateDirectories: false)
        #expect(throws: CocoaError.self) { try DurableFile.write(Data("lost".utf8), to: url) }
        #expect(try Data(contentsOf: url) == Data("kept".utf8))
    }

    @Test func aMissingDirectoryThrows() {
        #expect(throws: CocoaError.self) {
            try DurableFile.write(Data("x".utf8), to: root.appendingPathComponent("missing/note.json"))
        }
    }

    @Test func theRepositoriesWriteThroughIt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = try NoteRepository(root: root)
        let note = Note(title: "Durable")
        try notes.save(note)
        try notes.save(note)
        #expect(try contents(notes.directory(for: note.id)) == [NoteRepository.metadataFilename])
        let jobs = JobRepository(root: root)
        try jobs.save([])
        #expect(try jobs.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: jobs.url.path + DurableFile.temporarySuffix))
    }
}
