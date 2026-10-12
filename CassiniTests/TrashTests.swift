import XCTest
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

/// Recently Deleted over the real library, queue and saved voices.
@MainActor final class TrashTests: XCTestCase {
    /// A note in Recently Deleted since 31 days before the test clock's now, with a few bytes of audio.
    private func expiredNote(in test: TestGraph) throws -> Note {
        var note = Note(title: "Old draft", createdAt: test.clock.now.addingTimeInterval(-40 * 86_400), audioFilename: "audio.m4a")
        note.trashedAt = test.clock.now.addingTimeInterval(-31 * 86_400)
        let repository = try NoteRepository(root: test.root)
        try repository.save(note)
        try Data([1, 2, 3]).write(to: repository.audioURL(for: note))
        return note
    }

    func testUnreadableSavedVoicesDeleteNothingAndRaiseNoAlert() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try expiredNote(in: test)
        let voices = test.root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: voices.appendingPathComponent("voices.json"))
        let graph = test.graph

        let report = await graph.start()
        _ = try? await graph.trash.purgeExpired() // Cassini comes back to the screen.
        _ = try? await graph.trash.purgeExpired() // Recently Deleted opens.

        XCTAssertNotNil(report.failed[.purge])
        XCTAssertNotNil(graph.library.note(note.id), "nothing is deleted while the voices cannot be read")
        XCTAssertTrue(FileManager.default.fileExists(atPath: test.root.appendingPathComponent(note.id.uuidString).path))
        XCTAssertTrue(graph.trash.voicesUnavailable)
        XCTAssertNil(graph.errors.current, "no alert, however often the purge runs")
        XCTAssertEqual(graph.notices.notices.count, 1, "the one notice of the unreadable voices")
        var facts = NoticeFacts()
        graph.trash.contribute(to: &facts)
        XCTAssertTrue(facts.voicesUnavailable)
    }

    func testTheLaunchPurgesExpiredNotesAndLeavesNoFolder() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try expiredNote(in: test)
        let graph = test.graph

        let report = await graph.start()

        XCTAssertNil(report.failed[.purge])
        XCTAssertNil(graph.library.note(note.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: test.root.path).filter { $0.hasPrefix(note.id.uuidString) }, [])
        XCTAssertEqual(graph.settings.trashLastPurgeAt, test.clock.now)
    }

    func testMovingANoteOffersUndoOnceAndUndoRestoresIt() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = Note(title: "Call with supplier")
        try NoteRepository(root: test.root).save(note)
        let graph = test.graph
        await graph.start()
        graph.router.show(.note(note.id))

        let moved = await graph.trash.requestTrash(note.id)

        XCTAssertTrue(moved)
        XCTAssertEqual(graph.router.path, [], "the move lands on the Library")
        graph.trash.undo.showPending(duration: TrashPolicy.undoDuration(voiceOverRunning: false))
        XCTAssertEqual(graph.trash.undo.snackbar?.note, TrashedNote(noteID: note.id, title: "Call with supplier"))
        graph.trash.undo.showPending(duration: .seconds(10))
        XCTAssertEqual(graph.trash.undo.snackbar?.id, 1, "shown once")
        graph.trash.undo.undo()
        XCTAssertNil(graph.library.note(note.id)?.trashedAt)
        await graph.library.settle()
        XCTAssertNil(try NoteRepository(root: test.root).load().notes.first?.trashedAt, "the restore is written")
    }
}
