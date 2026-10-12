import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Recovery at launch (RecoveryRepositoryTest adapted to CAF, CatalogueRebuildTest for bare audio directories).
@Suite struct CaptureRecoveryTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let clock = FakeClock(now: Date(timeIntervalSince1970: 1_791_452_460))
    let audio = FakeAudioProcessing(summary: AudioSummary(duration: 42, waveform: [0.3]), opensAnyFile: true)
    let repairer = FakeCaptureRepairer()

    var recovery: CaptureRecovery {
        CaptureRecovery(audio: audio, repairer: repairer, clock: clock, recoveredTitle: { _ in "Recovered recording 8 Oct" })
    }

    /// A live note whose capture holds `bytes` (no file when nil).
    func liveNote(_ store: NoteStore, title: String = "Registrazione", createdAt: Date = Date(timeIntervalSince1970: 1_000),
                  bytes: Data? = Data(repeating: 1, count: 64)) async throws -> Note {
        var note = Note(title: title, createdAt: createdAt, audioFilename: "capture.caf")
        note.status = .recording; note.audio = .live
        try await store.save(note)
        if let bytes { try bytes.write(to: store.audioURL(for: note)) }
        return note
    }

    func file(_ store: NoteStore, _ id: UUID, _ name: String) -> URL { store.directory(for: id).appendingPathComponent(name) }

    // ports: RecoveryRepositoryTest#aTruncatedOpusCaptureIsRepairedToPlainWithASaneDuration
    @Test func aLiveCaptureIsRepairedToPlainWithItsDuration() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)
        let note = try await liveNote(store)
        let recovered = await recovery.recover(in: store, activeNoteID: nil)
        #expect(recovered == [RecoveredRecording(noteID: note.id, recoveredAt: clock.now, duration: 42)])
        #expect(repairer.urls == [store.audioURL(for: note)])
        let saved = try #require(await store.note(note.id))
        #expect(saved.audio == .plain)
        #expect(saved.status == .audioOnly)
        #expect(saved.duration == 42)
        #expect(saved.waveform == [0.3])
    }

    // ports: RecoveryRepositoryTest#theActiveCaptureIsLeftAlone
    @Test func theActiveCaptureIsLeftAlone() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)
        let note = try await liveNote(store)
        #expect(await recovery.recover(in: store, activeNoteID: note.id).isEmpty)
        #expect(await store.note(note.id) == note)
        #expect(repairer.urls.isEmpty)
    }

    // ports: RecoveryRepositoryTest#aCaptureWithoutAudioIsUnplayable
    @Test func aCaptureWithoutAudioIsUnplayableAndKept() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)
        let missing = try await liveNote(store, bytes: nil)
        audio.set(summary: nil)
        let garbage = try await liveNote(store, createdAt: Date(timeIntervalSince1970: 2_000))
        #expect(await recovery.recover(in: store, activeNoteID: nil).map(\.noteID) == [missing.id, garbage.id], "oldest first")
        for id in [missing.id, garbage.id] {
            let saved = try #require(await store.note(id))
            #expect(saved.audio == .unplayable(.interrupted))
            #expect(saved.failure == .audio)
        }
        #expect(FileManager.default.fileExists(atPath: file(store, garbage.id, "capture.caf").path), "audio is never deleted")
    }

    // ports: RecoveryRepositoryTest#aFinishedCaptureWithoutADurationIsRepairedButNotReported
    @Test func aFinishedCaptureWithoutADurationIsRepairedButNotReported() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)
        let note = try await liveNote(store)
        try await store.mutate(note.id) { $0.audio = .plain; $0.status = .audioOnly; $0.duration = 0 }
        #expect(await recovery.recover(in: store, activeNoteID: nil).isEmpty)
        #expect(await store.note(note.id)?.duration == 42)
    }

    // ports: RecoveryRepositoryTest#recoveryRunsOnce
    @Test func recoveryRunsOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)
        let note = try await liveNote(store)
        #expect(await recovery.recover(in: store, activeNoteID: nil).count == 1)
        let after = await store.note(note.id)
        #expect(await recovery.recover(in: store, activeNoteID: nil).isEmpty)
        #expect(await store.note(note.id) == after)
        #expect(repairer.urls.count == 1)
    }

    @Test func theLeftoversOfAnUnfinishedFinishAreDeleted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)
        // Compression stopped halfway: the half-written M4A goes, the capture stays.
        var halfway = Note(title: "Halfway", audioFilename: "capture.caf"); halfway.duration = 3
        try await store.save(halfway)
        try Data([1]).write(to: file(store, halfway.id, "capture.caf"))
        try Data([2]).write(to: file(store, halfway.id, "audio.m4a"))
        // Compression finished but the capture was not removed yet.
        var compressed = Note(title: "Compressed", audioFilename: "audio.m4a"); compressed.duration = 3
        try await store.save(compressed)
        try Data([1]).write(to: file(store, compressed.id, "capture.caf"))
        try Data([2]).write(to: file(store, compressed.id, "audio.m4a"))
        // An import keeps its original next to its M4A.
        var imported = Note(title: "Imported", audioFilename: "audio.m4a"); imported.originalAudioFilename = "capture.caf"
        imported.duration = 3
        try await store.save(imported)
        try Data([1]).write(to: file(store, imported.id, "capture.caf"))
        try Data([2]).write(to: file(store, imported.id, "audio.m4a"))

        await recovery.recover(in: store, activeNoteID: nil)
        let exists = { (id: UUID, name: String) in FileManager.default.fileExists(atPath: file(store, id, name).path) }
        #expect(exists(halfway.id, "capture.caf") && !exists(halfway.id, "audio.m4a"))
        #expect(!exists(compressed.id, "capture.caf") && exists(compressed.id, "audio.m4a"))
        #expect(exists(imported.id, "capture.caf") && exists(imported.id, "audio.m4a"))
    }

    @Test func theActiveRecordingKeepsItsFiles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)
        let note = try await liveNote(store)
        try Data([2]).write(to: file(store, note.id, "audio.m4a"))
        await recovery.recover(in: store, activeNoteID: note.id)
        #expect(FileManager.default.fileExists(atPath: file(store, note.id, "audio.m4a").path))
    }

    // ports: CatalogueRebuildTest#rebuildRecreatesRowsJobsAndLinks (a bare audio directory)
    @Test func aDirectoryWithAudioAndNoNoteIsRebuilt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let id = UUID()
        let folder = repository.directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("capture.caf"))
        try Data([2]).write(to: folder.appendingPathComponent("audio.m4a"))

        let rebuilt = await recovery.rebuild(in: repository)
        #expect(rebuilt.map(\.noteID) == [id])
        #expect(rebuilt.first?.duration == 42, "reported with what it holds")
        let note = try #require(try repository.load().notes.first)
        #expect(note.id == id)
        #expect(note.title == "Recovered recording 8 Oct")
        #expect(note.origin == .recovered)
        #expect(note.audioFilename == "capture.caf", "the capture is the recording's own audio")
        #expect(note.audio == .plain)
        #expect(note.duration == 42)
    }

    // ports: CatalogueRebuildTest#aCorruptDatabaseIsSetAsideAndRebuilt
    @Test func aDamagedNoteIsSetAsideAndRebuilt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let id = UUID()
        let folder = repository.directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"id\": tru".utf8).write(to: folder.appendingPathComponent("note.json"))
        try Data([2]).write(to: folder.appendingPathComponent("audio.m4a"))
        audio.set(summary: nil)

        #expect(await recovery.rebuild(in: repository).map(\.noteID) == [id])
        let note = try #require(try repository.load().notes.first)
        #expect(note.audioFilename == "audio.m4a")
        #expect(note.audio == .unplayable(.interrupted))
        let setAside = folder.appendingPathComponent("note.json.corrupt-1791452460000")
        #expect(try Data(contentsOf: setAside) == Data("{\"id\": tru".utf8))
    }

    // ports: CatalogueRebuildTest#rebuildSkipsDirectoriesWithoutAudioAndSyncsVoiceLinks, rebuildIsIdempotent
    @Test func readableNewerOrSilentDirectoriesAreLeftAlone() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let kept = Note(title: "Kept", audioFilename: "audio.m4a")
        try repository.save(kept)
        try Data([2]).write(to: repository.audioURL(for: kept))
        // A note from a newer Cassini is not damaged.
        let newer = UUID()
        try FileManager.default.createDirectory(at: repository.directory(for: newer), withIntermediateDirectories: true)
        let future = Data("{\"schemaVersion\": 3, \"id\": \"\(newer.uuidString)\"}".utf8)
        try future.write(to: repository.directory(for: newer).appendingPathComponent("note.json"))
        try Data([2]).write(to: repository.directory(for: newer).appendingPathComponent("audio.m4a"))
        // No audio: nothing to rebuild from.
        let silent = UUID()
        try FileManager.default.createDirectory(at: repository.directory(for: silent), withIntermediateDirectories: true)
        try Data("text".utf8).write(to: repository.directory(for: silent).appendingPathComponent("notes.txt"))

        #expect(await recovery.rebuild(in: repository).isEmpty)
        #expect(try Data(contentsOf: repository.directory(for: newer).appendingPathComponent("note.json")) == future)
        #expect(try repository.load().notes.map(\.id) == [kept.id])
        #expect(await recovery.rebuild(in: repository).isEmpty)
    }
}

/// The note rows of a recording (NoteRepositoryTest).
@Suite struct RecordingNotesTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    // ports: NoteRepositoryTest#aRecordingStartsLiveAndEndsPlain
    @Test func aRecordingStartsLiveAndEndsPlain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)
        var note = Note(title: "Registrazione 9 ott", createdAt: Date(timeIntervalSince1970: 42), audioFilename: "capture.caf")
        note.audio = .live
        try await store.create(note)
        #expect(FileManager.default.fileExists(atPath: store.directory(for: note.id).path))
        #expect(store.captureURL(for: note) == store.directory(for: note.id).appendingPathComponent("capture.caf"))
        let reloaded = try NoteStore(root: root)
        let row = try #require(try await reloaded.load().notes.first)
        #expect(row.audio == .live)
        #expect(row.origin == .recorded)
        #expect(row.createdAt == Date(timeIntervalSince1970: 42))

        let finished = try await store.update(note.id) { $0.audio = .plain; $0.duration = 61 }
        #expect(finished?.audio == .plain)
        #expect(finished?.duration == 61)
    }

    // ports: NoteRepositoryTest#aRecordingThatCouldNotStartIsDiscarded
    @Test func aRecordingThatCouldNotStartIsDiscarded() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)
        var note = Note(title: "Nota", audioFilename: "capture.caf"); note.audio = .live
        try await store.create(note)
        try Data([1, 2, 3]).write(to: store.audioURL(for: note))
        try await store.discard(note.id)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: note.id).path))
        #expect(await store.note(note.id) == nil)
    }
}
