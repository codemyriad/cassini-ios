import Foundation
import Testing
@testable import CassiniNotebook

/// Bookmarks are an iOS extra.
@Suite struct BookmarkTests {
    @Test func aMarkedMomentHasNoLabelAndKeepsTimeOrder() {
        var note = Note(title: "T"); note.duration = 60
        let late = UUID(), early = UUID()
        note.addBookmark(at: 30, id: late)
        note.addBookmark(at: 5, id: early)
        note.addBookmark(at: 30.5, id: UUID())
        #expect(note.bookmarks.map(\.id) == [early, late], "a moment within a second of another is not marked again")
        #expect(note.bookmarks.allSatisfy { $0.label == nil }, "the screen names an unlabelled moment in its language")
    }

    @Test func removingABookmarkLeavesTheOthers() {
        var note = Note(title: "T"); note.duration = 60
        let first = UUID(), second = UUID()
        note.addBookmark(at: 1, id: first); note.addBookmark(at: 9, id: second)
        note.removeBookmark(first)
        note.removeBookmark(UUID())
        #expect(note.bookmarks.map(\.id) == [second])
    }
}
