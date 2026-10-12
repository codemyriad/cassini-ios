import XCTest
import CassiniNotebook
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

/// The Library's note mirror over a store whose writes can be made to fail.
@MainActor final class LibraryStoreTests: XCTestCase {
    private var root: URL!
    private var persistence: CountingNotePersistence!
    private var library: LibraryStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        persistence = try CountingNotePersistence(root: root)
        library = LibraryStore(noteStore: NoteStore(persistence: persistence), errors: ErrorPresenter())
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
        let deadline = ContinuousClock.now + .seconds(5)
        while library.note(id)?.playbackPosition != 5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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
}
