import Foundation
import Testing
@testable import CassiniNotebook

/// Android `NoteSearchTest`, over the in-memory `LibraryIndex` that stands in for the FTS4 table. The SQLite probe and
/// the docid test have nothing to test on iOS.
final class NoteSearchTests {
    private var notes: [Note] = []

    private func note(_ title: String, _ text: String, createdAt: TimeInterval = 1) -> Note {
        var note = Note(title: title, createdAt: Date(timeIntervalSince1970: createdAt))
        if !text.isEmpty { note.transcript = [TranscriptSegment(text: text, start: 0, end: 5)]; note.status = .ready }
        return note
    }

    private func insert(_ text: String, title: String = "Note", createdAt: TimeInterval = 1) -> UUID {
        let note = note(title, text, createdAt: createdAt)
        notes.append(note)
        notes.sort { $0.createdAt > $1.createdAt }
        return note.id
    }

    private func search(_ input: String) -> [LibraryIndex.Hit] {
        var index = LibraryIndex(notes)
        return index.search(SearchQuery(input))
    }

    private func ids(_ input: String) -> [UUID] { search(input).map(\.entry.note.id) }

    // ports: NoteSearchTest#prefixFindsTheWholeWord
    @Test func prefixFindsTheWholeWord() {
        let a = insert("the delivery slips to Thursday")
        #expect(ids("deliv") == [a])
    }

    // ports: NoteSearchTest#diacriticsAreIgnored
    @Test func diacriticsAreIgnored() {
        let a = insert("meet at the café on Thursday")
        #expect(ids("cafe") == [a])
        #expect(ids("CAFÉ") == [a])
    }

    // ports: NoteSearchTest#caseIsIgnored
    @Test func caseIsIgnored() {
        let a = insert("the delivery slips to Thursday")
        #expect(ids("DELIVERY") == [a])
    }

    // ports: NoteSearchTest#everyTermMustMatchAndOperatorsAreWords
    @Test func everyTermMustMatchAndOperatorsAreWords() {
        let a = insert("the delivery slips to Thursday")
        _ = insert("the delivery is on time")
        #expect(ids("delivery Thur") == [a])
        #expect(ids("delivery OR timely").isEmpty)
    }

    /// The acceptance examples: "e-mail" finds "e mail", "cafe" finds "café", "deliv" finds "delivery".
    @Test func punctuationInTheQuerySplitsAsInTheNotes() {
        let a = insert("send the e mail from the café about the delivery")
        #expect(ids("e-mail") == [a])
        #expect(ids("cafe") == [a])
        #expect(ids("deliv") == [a])
        #expect(ids("mail-e").isEmpty, "the tokens of a phrase follow each other")
    }

    // ports: NoteSearchTest#trashedNotesAreExcluded
    @Test func trashedNotesAreExcluded() {
        let a = insert("the delivery slips", createdAt: 1)
        let b = insert("no delivery today", createdAt: 2)
        let index = notes.firstIndex { $0.id == b }!
        notes[index].trashedAt = Date(timeIntervalSince1970: 5)
        #expect(ids("delivery") == [a])
        notes[index].trashedAt = nil
        #expect(ids("delivery") == [b, a])
    }

    // ports: NoteSearchTest#snippetMarksTheMatchWithControlCharacters
    @Test func snippetMarksTheMatchWithControlCharacters() throws {
        _ = insert("so the delivery slips to Thursday but the price stays")
        let hit = try #require(search("deliv").first)
        #expect(hit.snippet.contains("\u{2}delivery\u{3}"), "\(hit.snippet)")
        let highlighted = Highlighted(marked: hit.snippet)
        #expect(!highlighted.text.contains("\u{2}"))
        #expect(highlighted.ranges.map { String(Array(highlighted.text)[$0]) } == ["delivery"])
    }

    // ports: NoteSearchTest#titleOnlyMatchMarksTheTitleAndNotTheBody
    @Test func titleOnlyMatchMarksTheTitleAndNotTheBody() throws {
        _ = insert("nothing relevant here", title: "Supplier meeting")
        let hit = try #require(search("suppl").first)
        #expect(hit.titleSnippet.contains("\u{2}Supplier\u{3}"))
        #expect(!hit.snippet.contains("\u{2}"))
    }

    // ports: NoteSearchTest#renameReindexesTheTitle
    @Test func renameReindexesTheTitle() {
        let a = insert("nothing relevant", title: "Old name")
        var index = LibraryIndex(notes)
        #expect(index.search(SearchQuery("old")).count == 1)
        notes[0].title = "Budget meeting"
        index.update(notes)
        #expect(index.search(SearchQuery("old")).isEmpty)
        #expect(index.search(SearchQuery("budget")).map(\.entry.note.id) == [a])
    }

    // ports: NoteSearchTest#selectingAnotherVariantReindexesTheBody
    @Test func selectingAnotherVariantReindexesTheBody() {
        let a = insert("first version")
        var index = LibraryIndex(notes)
        #expect(index.search(SearchQuery("first")).map(\.entry.note.id) == [a])
        notes[0].transcript = [TranscriptSegment(text: "second draft", start: 0, end: 5)]
        index.update(notes)
        #expect(index.search(SearchQuery("first")).isEmpty)
        #expect(index.search(SearchQuery("draft")).map(\.entry.note.id) == [a])
    }

    // ports: NoteSearchTest#audioOnlyNotesAreFoundByTitle
    @Test func audioOnlyNotesAreFoundByTitle() {
        let a = insert("", title: "Intervista Marco")
        #expect(ids("marco") == [a])
    }

    /// iOS extra: bookmark labels are searched too.
    @Test func bookmarkLabelsAreFound() {
        _ = insert("", title: "Standup")
        notes[0].bookmarks = [Bookmark(time: 3, label: "Budget decision")]
        #expect(ids("budget").count == 1)
    }

    /// iOS extra: each bookmark label is its own text, so a phrase never runs from one label into the next.
    @Test func aPhraseStaysInsideOneBookmarkLabel() {
        _ = insert("", title: "Standup")
        notes[0].bookmarks = [Bookmark(time: 3, label: "budget"), Bookmark(time: 9, label: "review")]
        #expect(ids("budget-review").isEmpty)
        #expect(ids("budget review").count == 1, "two phrases may match two labels")
        notes[0].bookmarks.append(Bookmark(time: 12, label: "Budget review"))
        #expect(ids("budget-review").count == 1)
    }

    /// Android `NoteRepository.search`: a query with nothing searchable lists every note, without marks.
    @Test func aQueryWithNothingSearchableListsEveryNote() {
        let a = insert("one", createdAt: 1), b = insert("two", createdAt: 2)
        let hits = search(" , ?! ")
        #expect(hits.map(\.entry.note.id) == [b, a])
        #expect(hits.allSatisfy { !$0.snippet.contains("\u{2}") })
    }

    /// FTS `snippet()`: 15 tokens around the match with "…" where cut, the match near the middle, and the text's
    /// punctuation kept between tokens.
    @Test func snippetsAreFifteenTokensAroundTheMatch() {
        let words = (1...40).map { "w\($0)" }
        let text = SearchText(words.joined(separator: ", ") + ".")
        let snippet = text.snippet([["w20"]], tokens: 15)
        #expect(snippet == "…w13, w14, w15, w16, w17, w18, w19, \u{2}w20\u{3}, w21, w22, w23, w24, w25, w26, w27…")
        #expect(text.snippet([["w5"]], tokens: 15).hasPrefix("w1, w2, w3, w4, \u{2}w5\u{3}, w6"), "the start of the text is not cut")
        #expect(text.snippet([["w39"]], tokens: 15).hasSuffix("\u{2}w39\u{3}, w40."), "nor is its end")
        #expect(SearchText("Short one.").snippet([["zzz"]], tokens: 15) == "Short one.")
    }

    @Test func aPhraseMarksEachOfItsTokens() {
        #expect(SearchText("Send the e-mail now").snippet([["e", "mail"]], tokens: 15) == "Send the \u{2}e\u{3}-\u{2}mail\u{3} now")
    }
}
