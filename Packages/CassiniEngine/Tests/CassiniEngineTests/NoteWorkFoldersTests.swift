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

    /// What `work/` holds that a person would lose with it: a checkpoint file, readable or not, or names that say
    /// more than a fresh run's.
    @Test func aCheckpointOrNamedSpeakersAreADraftAndAFreshRunsNamesAreNot() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = try NoteStore(root: root)
        let drafts = DraftNamesStore(notes: notes)
        let work = NoteWorkFolders(notes: notes, drafts: drafts)
        let bare = UUID(), fresh = UUID(), named = UUID(), merged = UUID(), saved = UUID(), damaged = UUID()
        for id in [bare, fresh, named, merged] { _ = try noteWithAudio(id) }
        drafts.mutate(fresh) { _ in DraftNames(generation: 4) }
        drafts.mutate(named) { $0.rename("speaker_0", "Ada") }
        try drafts.mutate(merged) { try $0.merge("speaker_1", into: "speaker_0") }
        try work.files.save(checkpoint(of: noteWithAudio(saved), doneMs: 30_000), for: saved)
        try work.files.save(checkpoint(of: noteWithAudio(damaged), doneMs: 30_000), for: damaged)
        try Data("{".utf8).write(to: work.files.directory(for: damaged).appendingPathComponent(CheckpointFiles.filename))

        #expect(FileManager.default.fileExists(atPath: work.files.directory(for: fresh).appendingPathComponent(DraftNamesStore.filename).path))
        #expect(await work.holdsDraft(bare) == false)
        #expect(await work.holdsDraft(fresh) == false)
        #expect(await work.holdsDraft(named))
        #expect(await work.holdsDraft(merged))
        #expect(await work.holdsDraft(saved))
        #expect(await work.holdsDraft(damaged))
        // Without the names store nothing says what a names file holds: it counts.
        #expect(await NoteWorkFolders(notes: notes).holdsDraft(fresh))
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
