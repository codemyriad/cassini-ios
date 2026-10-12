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
        playback.seek(1.75)
        playback.show(note, owner: owner)
        XCTAssertEqual(playback.state.position, 1.75, "the same file is not opened again")

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

    func testTheSameFileWrittenAgainIsOpenedAgainWherePlaybackWas() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedNote(in: test)
        let library = test.graph.library, playback = test.graph.playback, owner = PlaybackOwner()
        let shown = try XCTUnwrap(library.note(note.id))
        playback.show(shown, owner: owner)
        playback.seek(1.25)
        let url = try XCTUnwrap(library.audioURL(shown))
        try Data([1, 2, 3]).write(to: url)

        // The screen shows the note again with the same name and duration: the file's new size tells it apart.
        test.playback.loadError = CocoaError(.fileReadCorruptFile)
        playback.show(shown, owner: owner)
        XCTAssertTrue(playback.failed(note.id), "the rewritten file was opened again")
    }

    func testAPlayerRefusedWhileARecordingRunsOpensWhenTheRecordingLetsItGo() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedNote(in: test)
        let playback = test.graph.playback, owner = PlaybackOwner()
        let shown = try XCTUnwrap(test.graph.library.note(note.id))
        playback.setBlocked(true)
        XCTAssertNil(NotePlayer.key(for: shown, blocked: playback.isBlocked), "the screen asks for no player")
        playback.show(shown, owner: owner)
        XCTAssertFalse(playback.owns(note.id), "nothing opens while a recording runs")

        playback.setBlocked(false)
        let key = try XCTUnwrap(NotePlayer.key(for: shown, blocked: playback.isBlocked), "the key changes, so the screen shows it again")
        XCTAssertEqual(key.noteID, note.id)
        playback.show(shown, owner: owner)
        XCTAssertTrue(playback.owns(note.id))
    }

    func testAFailedPositionSaveShowsNoAlert() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedNote(in: test)
        let playback = test.graph.playback
        playback.show(try XCTUnwrap(test.graph.library.note(note.id)), owner: PlaybackOwner())
        // The note's directory cannot be written, so its writes fail.
        let directory = test.root.appendingPathComponent(note.id.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        playback.seek(1)
        playback.play()
        playback.pause()
        await playback.settle()
        await test.graph.library.settle()
        XCTAssertNil(test.graph.errors.current, "dropped, as on Android: the next save counts")

        // Another edit of the note in the same state does show the alert.
        await test.graph.library.commit(note.id) { $0.title = "Renamed" }
        XCTAssertNotNil(test.graph.errors.current)
    }

    /// A final save stores the Library preview at the position (`PreviewText` through the app's `NotePreview`).
    func testAFinalSaveThroughTheAppRefreshesTheLibraryPreview() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = Note(title: "Spoken", audioFilename: "audio.caf")
        note.duration = 2
        note.transcript = [TranscriptSegment(text: "First words.", start: 0, end: 1),
                           TranscriptSegment(text: "Later words.", start: 1, end: 2)]
        try NoteRepository(root: test.root).save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        await test.graph.start()
        let playback = test.graph.playback
        playback.show(try XCTUnwrap(test.graph.library.note(note.id)), owner: PlaybackOwner())
        playback.seek(1.5)
        playback.play()
        playback.pause()
        await playback.settle()
        await test.graph.library.settle()
        XCTAssertEqual(test.graph.library.note(note.id)?.previewText, "…words.", "from the word playing at 1.5 s")
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
