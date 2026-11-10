import XCTest
import Observation
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
        note.transcript = [TranscriptSegment(text: "so the delivery slips to Thursday", start: 0, end: 3)]
        note.status = .ready
        try NoteRepository(root: test.root).save(note)
        let model = test.graph.libraryScreen
        XCTAssertTrue(model.content.loading)
        XCTAssertNil(model.content.emptyState, "an unread library is not an empty one")
        await test.graph.start()
        await model.settle()
        let row = try XCTUnwrap(model.content.sections.first?.rows.first)
        XCTAssertEqual(row.title, "Call with supplier")
        XCTAssertEqual(row.status, .transcribed(speakers: 0, hasWords: true))
        XCTAssertEqual(row.preview?.text, "so the delivery slips to Thursday")
    }

    func testALibraryThatCannotBeOpenedSaysSo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root) // a file where the library folder should be
        let test = TestGraph(root: root); defer { test.tearDown() }
        await test.graph.start()
        XCTAssertEqual(test.graph.libraryScreen.content.emptyState, .unavailable)
    }

    /// The acceptance check: with a thousand notes, what a keystroke costs the main actor fits in a frame. That is
    /// indexing the notes after one of them changed (a new array, so nothing is compared by storage; the changed
    /// note's preview is worked out again) and building the Library's content: the flat results while searching, the
    /// day sections once the query is cleared. The search itself runs off the main actor once its tokens are cached,
    /// so it is not part of the frame; it has its own, looser bound.
    ///
    /// Both parts are synchronous and run here, on the main actor, so they are measured in this thread's CPU time:
    /// the main actor's own work, not the time a busy machine (a simulator that just booted) makes it wait (D88).
    /// Each part of each keystroke is measured three times and its least kept, as one sample can still be inflated
    /// (once 12.1 ms against a 6.7 ms median, iOS 27); the slowest keystroke must fit. That code measured 7.7-8.4 ms
    /// on iOS 18.2, 6.4-6.8 ms on iOS 27 and 7.45 ms on iOS 26; before a paragraph's text grew word by word it was
    /// 20 ms on iOS 18.2 and 13 ms on iOS 27. How that cost grows with the words and the notes is checked without a
    /// budget in CassiniNotebookTests' LibraryScalingTests.
    func testAThousandNotesFilterWithoutDroppingFrames() async throws {
        let words = ["delivery", "Thursday", "price", "supplier", "order", "warehouse", "meeting", "budget"]
        let notes = Notes((0..<1_000).map { index -> Note in
            var note = Note(title: "Note \(index) \(words[index % words.count])",
                            createdAt: Date(timeIntervalSince1970: 1_791_452_460 - Double(index) * 3_600))
            let text = (0..<120).map { words[($0 * 7 + index) % words.count] + "\(index % 13)" }.joined(separator: " ")
            note.transcript = [TranscriptSegment(text: text, start: 0, end: 60)]
            note.status = .ready
            return note
        })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let model = LibraryScreenModel(ports: .init(
            notes: { notes.all }, loading: { false }, unavailable: { false }, processing: { ProcessingState() },
            phase: { _ in nil }, install: { nil }, recording: { .idle }, finishing: { nil },
            transcribe: { _, _ in .queued(changed: true) }, startOver: { _ in .queued(changed: true) },
            stop: { _ in }, dequeue: { _ in }, update: { _, _ in }, trash: { _ in }, speakerModelsReady: { false },
            clock: FakeClock(now: Date(timeIntervalSince1970: 1_791_452_460)), calendar: calendar))
        model.query = "warm"
        await model.settle() // the tokens are worked out once
        var index = LibraryIndex(notes.all)
        _ = index.search(SearchQuery("warm"))

        var slowest: (index: Duration, content: Duration, search: Duration) = (.zero, .zero, .zero)
        for (step, query) in ["d", "de", "deli", "delivery", "delivery thu", "zzz", ""].enumerated() {
            // One note changes between keystrokes; the model indexes the new array on the main actor.
            notes.all[step * 97].title += " edited"
            let changed = notes.all
            var indexed = index, indexing = Duration.seconds(1)
            for _ in 0..<3 {
                var trial = index
                indexing = min(indexing, try measureThreadCPU { trial.update(changed) }.elapsed)
                indexed = trial
            }
            index = indexed
            // The search the model runs off the main actor, on a copy of the index, measured here on its own.
            var searched = index
            let searching = try measureThreadCPU { searched.search(SearchQuery(query)) }.elapsed
            index.adoptTokens(from: searched)
            model.query = query
            await model.settle() // the event gate: the model indexed the notes and its search answered
            var content = LibraryContent(), building = Duration.seconds(1)
            for _ in 0..<3 {
                let (built, elapsed) = try measureThreadCPU { model.content }
                content = built
                building = min(building, elapsed)
            }
            if indexing + building > slowest.index + slowest.content { (slowest.index, slowest.content) = (indexing, building) }
            slowest.search = max(slowest.search, searching)
            if query.isEmpty {
                XCTAssertEqual(content.sections.flatMap(\.rows).count, 1_000, "the cleared query lists every note")
            } else {
                XCTAssertNotNil(content.results)
            }
        }
        // Printed when it passes too, so the logs show how much of the frame is left.
        let measured = "indexing \(slowest.index), content \(slowest.content), main-thread CPU, least of 3 each"
        print("the main actor's part of the slowest keystroke: \(measured); the slowest search: \(slowest.search) of CPU")
        XCTAssertLessThan(slowest.index + slowest.content, .milliseconds(16),
                          "the main actor's part of the slowest keystroke fits in a frame (\(measured))")
        XCTAssertLessThan(slowest.search, .milliseconds(400), "the search, off the main actor (\(slowest.search) of CPU)")
    }
}

/// The notes of the thousand-note check, observed as `LibraryStore.notes` is.
@MainActor @Observable private final class Notes {
    var all: [Note]
    init(_ all: [Note]) { self.all = all }
}
