import XCTest
import UniformTypeIdentifiers
import CassiniNotebook
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

/// The Library over the real app graph: its picker types, its rows after the launch and how fast it filters.
@MainActor final class LibraryScreenTests: XCTestCase {
    /// The picker offers what Info.plist declares (`org.xiph.opus` for `.opus` and `.ogg`) and plain audio.
    func testTheImportPickerOffersTheDeclaredTypes() throws {
        let types = ImportStore.contentTypes
        let opus = try XCTUnwrap(UTType("org.xiph.opus"))
        XCTAssertTrue(opus.isDeclared, "Info.plist declares org.xiph.opus")
        XCTAssertTrue(types.contains(opus))
        for name in ["talk.opus", "talk.ogg", "talk.m4a", "talk.mp3", "talk.wav"] {
            let type = try XCTUnwrap(UTType(filenameExtension: (name as NSString).pathExtension), name)
            XCTAssertTrue(types.contains { type.conforms(to: $0) }, "\(name) is \(type.identifier)")
        }
        XCTAssertFalse(types.contains { UTType.pdf.conforms(to: $0) })
    }

    func testTheLaunchFillsTheRowsAndTheEmptyStateWaitsForIt() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = Note(title: "Call with supplier", createdAt: test.clock.now)
        note.transcript = [TranscriptSegment(text: "quindi la consegna slitta a giovedì", start: 0, end: 3)]
        note.status = .ready
        try NoteRepository(root: test.root).save(note)
        let model = test.graph.libraryScreen
        XCTAssertTrue(model.content.loading)
        XCTAssertNil(model.content.emptyState, "an unread library is not an empty one")
        await test.graph.start()
        let row = try XCTUnwrap(model.content.sections.first?.rows.first)
        XCTAssertEqual(row.title, "Call with supplier")
        XCTAssertEqual(row.status, .transcribed(speakers: 0, hasWords: true))
        XCTAssertEqual(row.preview?.text, "quindi la consegna slitta a giovedì")
    }

    func testALibraryThatCannotBeOpenedSaysSo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root) // a file where the library folder should be
        let test = TestGraph(root: root); defer { test.tearDown() }
        await test.graph.start()
        XCTAssertEqual(test.graph.libraryScreen.content.emptyState, .unavailable)
    }

    /// The acceptance check: with a thousand notes, what a keystroke costs the main actor (building the rows from the
    /// results) fits in a frame; the search itself runs off the main actor once its tokens are cached.
    func testAThousandNotesFilterWithoutDroppingFrames() {
        let words = ["consegna", "giovedì", "prezzo", "fornitore", "ordine", "magazzino", "riunione", "budget"]
        let notes = (0..<1_000).map { index -> Note in
            var note = Note(title: "Note \(index) \(words[index % words.count])",
                            createdAt: Date(timeIntervalSince1970: 1_791_452_460 - Double(index) * 3_600))
            let text = (0..<120).map { words[($0 * 7 + index) % words.count] + "\($0 % 13)" }.joined(separator: " ")
            note.transcript = [TranscriptSegment(text: text, start: 0, end: 60)]
            return note
        }
        var index = LibraryIndex(notes)
        _ = index.search(SearchQuery("warm"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_452_460)
        let clock = ContinuousClock()
        var slowestRows = Duration.zero, slowestSearch = Duration.zero
        for query in ["c", "co", "cons", "consegna", "consegna gio", "zzz"] {
            var hits: [LibraryIndex.Hit] = []
            slowestSearch = max(slowestSearch, clock.measure { hits = index.search(SearchQuery(query)) })
            slowestRows = max(slowestRows, clock.measure {
                index.update(notes)
                _ = LibraryMapping.results(hits, context: RowContext(), now: now, calendar: calendar)
            })
        }
        XCTAssertLessThan(slowestRows, .milliseconds(16), "the main actor's part of the slowest keystroke")
        XCTAssertLessThan(slowestSearch, .milliseconds(250), "the search off the main actor")
        measure { _ = LibraryMapping.results(index.search(SearchQuery("consegna gio")), context: RowContext(), now: now, calendar: calendar) }
    }
}
