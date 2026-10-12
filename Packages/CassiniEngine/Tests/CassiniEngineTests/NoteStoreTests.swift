import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@Suite struct NoteStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    private func store() throws -> (NoteStore, CountingNotePersistence) {
        let persistence = try CountingNotePersistence(root: root)
        return (NoteStore(persistence: persistence), persistence)
    }

    @Test func anUnchangedMutateWritesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, persistence) = try store()
        let note = Note(title: "Kept")
        try await store.save(note)
        #expect(persistence.saveCount == 1)
        let same = try await store.mutate(note.id) { $0.title = "Kept" }
        #expect(same == note)
        #expect(persistence.saveCount == 1)
        try await store.mutate(note.id) { $0.title = "Renamed" }
        #expect(persistence.saveCount == 2)
        #expect(await store.note(note.id)?.title == "Renamed")
    }

    @Test func aMissingNoteIsNotMutated() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, persistence) = try store()
        #expect(try await store.mutate(UUID()) { $0.title = "x" } == nil)
        #expect(persistence.saveCount == 0)
    }

    @Test func mutateAllWritesOnlyTheNotesItChanged() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, persistence) = try store()
        var starred = Note(title: "Starred"); starred.isFavorite = true
        try await store.save(starred)
        try await store.save(Note(title: "Plain"))
        let changed = try await store.mutateAll { $0.isFavorite = false }
        #expect(changed.map(\.title) == ["Starred"])
        #expect(persistence.saveCount == 3)
    }

    @Test func aFailedWriteKeepsTheNoteInMemoryAsItWas() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, persistence) = try store()
        let note = Note(title: "Before")
        try await store.save(note)
        persistence.failSaves(true)
        await #expect(throws: CocoaError.self) { try await store.mutate(note.id) { $0.title = "After" } }
        #expect(await store.note(note.id)?.title == "Before")
    }

    @Test func writesAreReadBackAfterARestart() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = try store()
        let older = Note(title: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = Note(title: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
        try await store.save(older); try await store.save(newer)
        let reopened = try NoteStore(root: root)
        let report = try await reopened.load()
        #expect(report.notes.map(\.title) == ["Newer", "Older"])
        #expect(await reopened.all().map(\.id) == [newer.id, older.id])
    }

    @Test func changesArriveInWriteOrderAndDeleteRemovesTheDirectory() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = try store()
        let changes = await store.changes()
        let note = Note(title: "One")
        try await store.save(note)
        try await store.mutate(note.id) { $0.title = "Two" }
        try await store.delete(note.id)
        var received: [NoteChange] = []
        for await change in changes {
            received.append(change)
            if received.count == 3 { break }
        }
        var renamed = note; renamed.title = "Two"
        #expect(received == [.saved(note), .saved(renamed), .deleted(note.id)])
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: note.id).path))
    }

    @Test func aSchemaOneNoteIsWrittenBackAsSchemaTwo() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = #"{"schemaVersion":1,"id":"\#(id.uuidString)","title":"Legacy","createdAt":0,"audioFilename":"audio.m4a","status":"ready","language":"it_IT","failureMessage":"Transcription was interrupted. Tap Transcribe to start again."}"#
        try Data(legacy.utf8).write(to: folder.appendingPathComponent("note.json"))
        let store = try NoteStore(root: root)
        try await store.load()
        try await store.mutate(id) { $0.isFavorite = true }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("note.json"))) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == 2)
        #expect(object?["language"] as? String == "it-IT")
        #expect(object?["failure"] as? String == "INTERRUPTED")
        #expect(object?["failureMessage"] == nil)
    }

    @Test func anEditOfTheStoredNoteWritesItsResultAsMade() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, persistence) = try store()
        let note = Note(title: "First")
        try await store.save(note)
        let edit = NoteEdit(note) { $0.title = "Second" }
        #expect(try await store.apply(edit) == edit.after)
        #expect(persistence.saveCount == 2)
        #expect(try await store.apply(NoteEdit(edit.after) { $0.title = "Second" }) == edit.after)
        #expect(persistence.saveCount == 2, "an edit that changes nothing writes nothing")
    }

    @Test func anEditKeepsWhatAnotherWriterSavedAfterItWasMade() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = try store()
        var note = Note(title: "Recording")
        note.duration = 5
        try await store.save(note)
        let bookmark = UUID()
        let starred = NoteEdit(note) { $0.isFavorite = true }
        let marked = NoteEdit(starred.after) { $0.addBookmark(at: 2, id: bookmark) }
        try await store.mutate(note.id) { $0.transcript = [TranscriptSegment(text: "Hello", start: 0, end: 1)] }

        try await store.applyAll([starred, marked])

        let stored = try #require(await store.note(note.id))
        #expect(stored.isFavorite)
        #expect(stored.bookmarks.map(\.id) == [bookmark])
        #expect(stored.transcript.map(\.text) == ["Hello"])
    }

    @Test func anEditOfANoteDeletedSinceWritesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, persistence) = try store()
        let note = Note(title: "Gone")
        try await store.save(note)
        try await store.delete(note.id)
        #expect(try await store.apply(NoteEdit(note) { $0.title = "Back" }) == nil)
        #expect(try await store.applyAll([NoteEdit(note) { $0.title = "Back" }]) == [])
        #expect(persistence.saveCount == 1)
    }
}
