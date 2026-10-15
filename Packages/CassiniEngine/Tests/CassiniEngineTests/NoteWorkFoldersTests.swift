import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

/// The queue reads the windowed job's checkpoints through `NoteWorkFolders`.
@Suite struct NoteWorkFoldersTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// A note folder with a two-byte `audio.m4a`; returns the audio's URL.
    private func noteWithAudio(_ id: UUID) throws -> URL {
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("audio.m4a")
        try Data([1, 2]).write(to: audio)
        return audio
    }

    private func checkpoint(of audio: URL, doneMs: Int64) -> CheckpointState {
        CheckpointState(source: audio.lastPathComponent, signature: CheckpointState.signature(of: audio), model: CheckpointState.appleModel(language: "en-US"),
                        segments: [TranscriptSegment(text: "Hello there", start: 0, end: 1,
                                                     words: [.init(text: "Hello", start: 0, end: 0.5),
                                                             .init(text: " there", start: 0.5, end: 1)])],
                        doneMs: doneMs, totalMs: 60_000, elapsedMs: 10)
    }

    @Test func aCheckpointGivesItsNumbersAndOneThatNoLongerFitsTheAudioIsAMismatch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = try NoteStore(root: root)
        let work = NoteWorkFolders(notes: notes)
        let saved = UUID(), changed = UUID(), damaged = UUID(), bare = UUID()
        for id in [saved, changed, damaged] {
            try work.files.save(checkpoint(of: noteWithAudio(id), doneMs: 30_000), for: id)
        }
        _ = try noteWithAudio(bare)
        // The audio was replaced after the checkpoint was written.
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(changed.uuidString).appendingPathComponent("audio.m4a"))
        try Data("{".utf8).write(to: work.files.directory(for: damaged).appendingPathComponent(CheckpointFiles.filename))

        #expect(await work.status(of: saved) == .saved(doneMs: 30_000, totalMs: 60_000, words: 2))
        #expect(await work.status(of: changed) == .mismatch)
        #expect(await work.status(of: damaged) == .mismatch)
        #expect(await work.status(of: bare) == .missing)
        #expect(await work.notesWithWork() == [saved, changed, damaged])

        try await work.discard(saved)
        #expect(await work.status(of: saved) == .missing)
        #expect(await work.notesWithWork() == [changed, damaged])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(saved.uuidString).appendingPathComponent("audio.m4a").path),
                "only the work goes")
    }
}
