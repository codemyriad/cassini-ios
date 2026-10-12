import XCTest
import CassiniNotebook
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

/// The app's player over a real library: positions saved to the note, the reload when the audio changes, and the
/// failure state.
@MainActor final class PlaybackStoreTests: XCTestCase {
    func testAFinalSaveStoresThePositionAndTheLibraryPreview() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedNote(in: test)
        let playback = PlaybackStore(playback: test.playback, library: test.graph.library,
                                     preview: { note, position in "\(note.title) at \(Int(position))" })
        playback.show(try XCTUnwrap(test.graph.library.note(note.id)), owner: PlaybackOwner())
        playback.seek(1)
        playback.play()
        playback.pause()
        await playback.settle()
        await test.graph.library.settle()

        let stored = try XCTUnwrap(NoteRepository(root: test.root).load().notes.first { $0.id == note.id })
        XCTAssertEqual(stored.playbackPosition, 1)
        XCTAssertEqual(stored.previewText, "Plain at 1")
        XCTAssertEqual(test.graph.library.note(note.id)?.playbackPosition, 1, "the screens show it")
    }

    func testANoteOpensAtItsSavedPositionAndTheSameScreenKeepsThePlayer() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = try await seedNote(in: test)
        let saved = await test.graph.library.commit(note.id) { $0.playbackPosition = 1.5 }
        note = try XCTUnwrap(saved)
        let playback = test.graph.playback, owner = PlaybackOwner()
        playback.show(note, owner: owner)
        XCTAssertTrue(playback.owns(note.id))
        XCTAssertEqual(playback.state.position, 1.5)
        playback.show(note, owner: owner)
        XCTAssertEqual(test.playback.loads.count, 1, "the same file is not opened again")

        playback.leave(PlaybackOwner())
        XCTAssertTrue(playback.owns(note.id), "another screen's leave does nothing")
        playback.leave(owner)
        XCTAssertNil(playback.state.noteID)
    }

    func testTheCompressedCopyReplacingTheCaptureIsOpenedWherePlaybackWas() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedNote(in: test)
        let library = test.graph.library, playback = test.graph.playback, owner = PlaybackOwner()
        playback.show(try XCTUnwrap(library.note(note.id)), owner: owner)
        playback.seek(1.25)
        playback.play()

        let compressed = test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.m4a")
        try Data([1]).write(to: compressed)
        let moved = await library.commit(note.id) { $0.audioFilename = "audio.m4a" }
        playback.show(try XCTUnwrap(moved), owner: owner)

        XCTAssertEqual(test.playback.loadedURL, compressed)
        XCTAssertEqual(test.playback.position, 1.25)
        XCTAssertTrue(playback.state.isPlaying, "still playing")
    }

    func testAFileThatCannotBePlayedShowsAsFailedForItsNote() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedNote(in: test)
        test.playback.loadError = CocoaError(.fileReadCorruptFile)
        let playback = test.graph.playback
        playback.show(try XCTUnwrap(test.graph.library.note(note.id)), owner: PlaybackOwner())
        XCTAssertTrue(playback.failed(note.id))
        XCTAssertFalse(playback.owns(note.id))
        XCTAssertNil(test.graph.errors.current, "no global alert")
    }

    func testASpeakerSampleDoesNotMoveTheSavedPosition() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedNote(in: test)
        let playback = test.graph.playback
        playback.show(try XCTUnwrap(test.graph.library.note(note.id)), owner: PlaybackOwner())
        playback.seek(0.5)
        XCTAssertTrue(playback.playSample(note, from: 1, to: 1.8))
        XCTAssertNotNil(playback.state.sample)
        playback.stopSample()
        await playback.settle()
        await test.graph.library.settle()
        XCTAssertNil(playback.state.sample)
        XCTAssertFalse(playback.state.isPlaying)
        XCTAssertEqual(test.graph.library.note(note.id)?.playbackPosition, 0.5)
    }

    /// A two-second note with an audio file, then the launch that loads it.
    private func seedNote(in test: TestGraph) async throws -> Note {
        var note = Note(title: "Plain", audioFilename: "audio.caf")
        note.duration = 2
        try NoteRepository(root: test.root).save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        await test.graph.start()
        return note
    }
}
