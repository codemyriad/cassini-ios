import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

@Suite struct CheckpointFilesTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let id = UUID()
    private let segmentID = UUID()

    private func state(_ doneMs: Int64) -> CheckpointState {
        CheckpointState(source: "audio.m4a", signature: "1:2", language: "en-US",
                        segments: [TranscriptSegment(id: segmentID, text: "Hello", start: 0, end: Double(doneMs) / 1000)],
                        doneMs: doneMs, totalMs: 90_000, elapsedMs: 10)
    }

    /// Files for notes under `root`; the note's own folder exists, as it does for a note in the library.
    private func files(availableBytes: @escaping @Sendable (URL) -> Int64 = CheckpointFiles.availableBytes) -> CheckpointFiles {
        let root = root
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
        return CheckpointFiles(noteDirectory: { root.appendingPathComponent($0.uuidString, isDirectory: true) },
                               availableBytes: availableBytes)
    }

    @Test func aFailedWriteOnAFullVolumeIsASpaceError() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the work folder goes makes every write fail.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(id.uuidString).appendingPathComponent(CheckpointFiles.directoryName))
        #expect(throws: CheckpointSpaceError.self) { try files(availableBytes: { _ in 1 << 20 }).save(state(30_000), for: id) }
        #expect {
            try files(availableBytes: { _ in 1 << 40 }).save(state(30_000), for: id)
        } throws: { !($0 is CheckpointSpaceError) }
        #expect(CheckpointFiles.availableBytes(root.appendingPathComponent("missing/deeper")) > 0)
    }

    @Test func aSavedCheckpointReadsBackAndKeepsThePreviousOneAsTheBackup() throws {
        let files = self.files()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try files.load(id) == nil)
        #expect(!files.exists(id))
        try files.save(state(30_000), for: id)
        try files.save(state(60_000), for: id)
        #expect(try files.load(id) == state(60_000))
        let folder = files.directory(for: id)
        #expect(folder.path.hasSuffix("\(id.uuidString)/work"))
        let backup = try CheckpointState.decode(Data(contentsOf: folder.appendingPathComponent(CheckpointFiles.backupFilename)))
        #expect(backup == state(30_000))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("checkpoint.json.tmp").path))
    }

    @Test func aDamagedCheckpointFallsBackToTheBackup() throws {
        let files = self.files()
        defer { try? FileManager.default.removeItem(at: root) }
        try files.save(state(30_000), for: id)
        try files.save(state(60_000), for: id)
        try Data("{\"version\":".utf8).write(to: files.directory(for: id).appendingPathComponent(CheckpointFiles.filename))
        #expect(try files.load(id) == state(30_000))
        // A crash between moving the checkpoint to the backup and renaming the new one leaves only the backup.
        try FileManager.default.removeItem(at: files.directory(for: id).appendingPathComponent(CheckpointFiles.filename))
        #expect(try files.load(id) == state(30_000))
        #expect(files.exists(id))
    }

    @Test func bothFilesDamagedIsAnError() throws {
        let files = self.files()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = files.directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent(CheckpointFiles.filename))
        #expect(throws: (any Error).self) { try files.load(id) }
    }

    @Test func discardRemovesTheWorkFolderOnly() throws {
        let files = self.files()
        defer { try? FileManager.default.removeItem(at: root) }
        try files.save(state(30_000), for: id)
        let note = root.appendingPathComponent(id.uuidString).appendingPathComponent("note.json")
        try Data("{}".utf8).write(to: note)
        try files.discard(id)
        try files.discard(id)
        #expect(!files.exists(id))
        #expect(FileManager.default.fileExists(atPath: note.path))
    }

    @Test func aSaveForANoteWhoseFolderIsGoneLeavesNothingBehind() throws {
        let files = self.files()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = UUID()
        #expect(throws: (any Error).self) { try files.save(state(30_000), for: other) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(other.uuidString).path))
    }
}
