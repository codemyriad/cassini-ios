import Foundation
import Testing
@testable import CassiniNotebook

@Test func searchMatchesEveryTermAcrossTitleAndTranscript() {
    var note = Note(title: "Café planning")
    note.transcript = [.init(text: "Delivery on Thursday", start: 0, end: 2)]
    let fields = SearchFields(note)
    #expect(fields.matches(SearchQuery("CAFE thurs")!))
    #expect(!fields.matches(SearchQuery("cafe friday")!))
    #expect(SearchQuery("  ") == nil, "nothing searchable: every note shows")
    #expect(!fields.matches(SearchQuery("OR *")!))
}

@Test func timestampBoundaries() {
    #expect(TimeText.clock(3599.99) == "59:59")
    #expect(TimeText.clock(3600) == "1:00:00")
    #expect(TimeText.clock(-2) == "00:00")
    #expect(TimeText.subtitle(59.9996) == "00:01:00,000")
    #expect(TimeText.clock(.infinity) == "00:00")
}

@Test func atomicRoundTripAndCorruptionIsolation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try NoteRepository(root: root)
    var note = Note(title: "Original")
    note.transcript = [.init(text: "Words", start: 0, end: 1, words: [.init(text: "Words", start: 0, end: 1)])]
    note.bookmarks = [.init(time: 0.5)]
    try repository.save(note)
    note.title = "Updated"; note.isFavorite = true
    try repository.save(note)
    #expect(try repository.load().notes == [note])
    let damaged = Note(title: "Damaged")
    try repository.save(damaged)
    try Data("broken".utf8).write(to: repository.directory(for: damaged.id).appendingPathComponent("note.json"))
    #expect(try repository.load().notes == [note])
    #expect(try repository.load().unreadableCount == 1)
    try repository.delete(note.id)
    #expect(try repository.load().notes.isEmpty)
}

@Test func rejectPathTraversal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try NoteRepository(root: root)
    let note = Note(title: "Unsafe", audioFilename: "../outside.m4a")
    #expect(throws: RepositoryError.self) { try repository.save(note) }
}
