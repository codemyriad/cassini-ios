import XCTest
import CassiniNotebook
import CassiniEngine
import CassiniEngineTesting

/// The Library's note mirror over a store whose writes can be made to fail: edits replayed over what other writers
/// save, and changes shown while their write failed (`showUnsaved`) carried by the next write.
@MainActor final class LibraryStoreTests: XCTestCase {
    private var root: URL!
    private var persistence: CountingNotePersistence!
    private var library: LibraryStore!
    private var failures: [any Error] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        persistence = try CountingNotePersistence(root: root)
        library = LibraryStore(noteStore: NoteStore(persistence: persistence)) { [unowned self] in failures.append($0) }
        await library.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A finished recording whose seal could not be written, as `RecordingController` leaves it.
    private func recordingWithAFailedSeal() async throws -> UUID {
        var note = Note(title: "Voice note", audioFilename: "capture.caf")
        note.status = .recording; note.audio = .live
        try await library.insert(note)
        let seal: @Sendable (inout Note) -> Void = { $0.title = "Standup"; $0.duration = 12; $0.audio = .plain; $0.status = .audioOnly }
        persistence.failSaves(true)
        let sealed = await library.commit(note.id, seal)
        XCTAssertNil(sealed)
        library.showUnsaved(note.id, seal)
        persistence.failSaves(false)
        XCTAssertEqual(library.note(note.id)?.isRecording, false, "shown plain at once")
        return note.id
    }

    private func stored(_ id: UUID) throws -> Note? {
        try NoteRepository(root: root).load().notes.first { $0.id == id }
    }

    func testAnUnsavedSealSurvivesALaterWriteAndIsWrittenWithIt() async throws {
        let id = try await recordingWithAFailedSeal()
        XCTAssertEqual(try stored(id)?.audio, .live)

        library.update(id) { $0.playbackPosition = 3 } // The first play and pause.
        await library.settle()
        let shown = try XCTUnwrap(library.note(id))
        XCTAssertFalse(shown.isRecording)
        XCTAssertEqual(shown.title, "Standup")
        XCTAssertEqual(shown.playbackPosition, 3)
        let onDisk = try XCTUnwrap(try stored(id))
        XCTAssertEqual(onDisk.audio, .plain, "the later write carried the seal")
        XCTAssertEqual(onDisk.status, .audioOnly)
        XCTAssertEqual(onDisk.duration, 12)
        XCTAssertEqual(onDisk.playbackPosition, 3)
    }

    func testAnUnsavedSealStaysOnScreenWhileLaterWritesFail() async throws {
        let id = try await recordingWithAFailedSeal()
        persistence.failSaves(true)
        library.update(id) { $0.isFavorite = true }
        await library.settle()
        XCTAssertEqual(library.note(id)?.isRecording, false, "a failed write puts back the stored note, seal on top")
        persistence.failSaves(false)

        library.update(id) { $0.isFavorite = true }
        await library.settle()
        XCTAssertEqual(try stored(id)?.audio, .plain)
        XCTAssertEqual(try stored(id)?.isFavorite, true)
    }

    func testAnUnsavedSealStaysOverWhatAnotherWriterSaves() async throws {
        let id = try await recordingWithAFailedSeal()
        let store = try XCTUnwrap(library.noteStore)
        try await store.mutate(id) { $0.playbackPosition = 5 }
        try await waitForObserved("the library's saved playback position") { self.library.note(id)?.playbackPosition == 5 }
        XCTAssertEqual(library.note(id)?.playbackPosition, 5)
        XCTAssertEqual(library.note(id)?.isRecording, false)
    }

    func testARenameAfterAFailedSealShowsAndKeepsTheNewTitle() async throws {
        let id = try await recordingWithAFailedSeal()
        library.update(id) { $0.title = "Retro" } // RenameNoteSheet.
        XCTAssertEqual(library.note(id)?.title, "Retro", "the rename shows over the seal at once")
        await library.settle()
        XCTAssertEqual(library.note(id)?.title, "Retro")
        let onDisk = try XCTUnwrap(try stored(id))
        XCTAssertEqual(onDisk.title, "Retro")
        XCTAssertEqual(onDisk.audio, .plain, "the rename carried the seal beneath it")
    }

    func testARenameWhileTheSealIsWrittenIsNotUndoneByTheNextWrite() async throws {
        let id = try await recordingWithAFailedSeal()
        library.update(id) { $0.title = "Retro" }
        library.update(id) { $0.isFavorite = true }
        library.update(id) { $0.playbackPosition = 4 }
        await library.settle()
        let onDisk = try XCTUnwrap(try stored(id))
        XCTAssertEqual(onDisk.title, "Retro", "later writes do not replay the seal over the rename")
        XCTAssertEqual(onDisk.isFavorite, true)
        XCTAssertEqual(onDisk.playbackPosition, 4)
        XCTAssertEqual(onDisk.audio, .plain)
        XCTAssertEqual(library.note(id)?.title, "Retro")
    }

    func testARenameWhoseWriteFailsLetsTheNextWriteCarryTheSeal() async throws {
        let id = try await recordingWithAFailedSeal()
        persistence.failSaves(true)
        library.update(id) { $0.title = "Retro" }
        await library.settle()
        XCTAssertEqual(library.note(id)?.title, "Standup", "the failed rename is put back, the seal still shown")
        persistence.failSaves(false)
        library.update(id) { $0.isFavorite = true }
        await library.settle()
        let onDisk = try XCTUnwrap(try stored(id))
        XCTAssertEqual(onDisk.title, "Standup")
        XCTAssertEqual(onDisk.audio, .plain)
        XCTAssertEqual(onDisk.isFavorite, true)
    }

    func testATranscriptionQueuedAfterAFailedSealShowsItsStatus() async throws {
        let id = try await recordingWithAFailedSeal()
        persistence.failSaves(true) // The disk is still full.
        // As the queue writes a job's status.
        library.update(id) { $0.status = .queued; $0.failure = nil }
        XCTAssertEqual(library.note(id)?.status, .queued)
        library.update(id) { $0.status = .transcribing }
        XCTAssertEqual(library.note(id)?.status, .transcribing)
        XCTAssertEqual(library.note(id)?.isRecording, false)
        await library.settle()
        persistence.failSaves(false)
        library.update(id) { $0.status = .transcribing }
        XCTAssertEqual(library.note(id)?.status, .transcribing)
        await library.settle()
        XCTAssertEqual(library.note(id)?.status, .transcribing)
        XCTAssertEqual(try stored(id)?.status, .transcribing)
        XCTAssertEqual(try stored(id)?.audio, .plain)
    }

    /// An edit is replayed over the stored note when it is written, so a field another writer saved meanwhile stays.
    func testAnEditKeepsWhatAnotherWriterSavedMeanwhile() async throws {
        let note = Note(title: "Standup")
        try await library.insert(note)
        let store = try XCTUnwrap(library.noteStore)
        try await store.mutate(note.id) { $0.playbackPosition = 7 }
        library.update(note.id) { $0.title = "Retro" }
        await library.settle()
        let onDisk = try XCTUnwrap(try stored(note.id))
        XCTAssertEqual(onDisk.title, "Retro")
        XCTAssertEqual(onDisk.playbackPosition, 7, "the other writer's change is kept")
        XCTAssertEqual(library.note(note.id)?.playbackPosition, 7)
        XCTAssertTrue(failures.isEmpty)
    }

    /// A failed write puts the note back as stored and reports the failure; a commit says it failed.
    func testAFailedWriteIsPutBackAndReported() async throws {
        let note = Note(title: "Standup")
        try await library.insert(note)
        persistence.failSaves(true)
        library.update(note.id) { $0.title = "Retro" }
        XCTAssertEqual(library.note(note.id)?.title, "Retro", "shown at once")
        await library.settle()
        XCTAssertEqual(library.note(note.id)?.title, "Standup")
        XCTAssertEqual(failures.count, 1)
        let committed = await library.commit(note.id, reportsFailure: false) { $0.playbackPosition = 2 }
        XCTAssertNil(committed)
        XCTAssertEqual(failures.count, 1, "a commit that does not report stays quiet")
        persistence.failSaves(false)
    }
}
