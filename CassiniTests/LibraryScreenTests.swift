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
    /// so it is not part of the frame; the same search, on a copy of the index as the model runs it, has its own,
    /// looser bound.
    ///
    /// Both parts are synchronous and run here, on the main actor, so they are measured in this thread's CPU time:
    /// the main actor's own work, not the time a busy machine (a simulator that just booted) makes it wait (D88). CPU
    /// time still counts a slower core: one sample was once 12.1 ms against a 6.7 ms median (iOS 27). So the typing
    /// runs `passes` times, each keystroke measured twice per pass, and each part of a keystroke keeps its least of
    /// those samples, a second or more apart; the slowest keystroke must fit. A regression is slow in every sample.
    /// That code measured 7.7-8.4 ms on iOS 18.2, 6.4-6.8 ms on iOS 27 and 7.45 ms on iOS 26, about 2x under the
    /// frame; before a paragraph's text grew word by word it was 20 ms on iOS 18.2 and 13 ms on iOS 27, so this
    /// budget alone catches that regression only on iOS 18.2. How the cost grows with the words and the notes is
    /// checked without a budget, on every OS, in CassiniNotebookTests' LibraryScalingTests.
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

        let queries = ["d", "de", "deli", "delivery", "delivery thu", "zzz", ""]
        let passes = 3, never = Duration.seconds(1_000)
        var least = Array(repeating: (index: never, content: never, search: never), count: queries.count)
        for pass in 0..<passes {
            for (step, query) in queries.enumerated() {
                // One note changes between keystrokes; the model indexes the new array on the main actor.
                notes.all[(pass * queries.count + step) * 97 % 1_000].title += " edited"
                let changed = notes.all
                var indexed = index
                for _ in 0..<2 {
                    var trial = index
                    least[step].index = min(least[step].index, try measureThreadCPU { trial.update(changed) }.elapsed)
                    indexed = trial
                }
                index = indexed
                // The search the model runs off the main actor, on a copy of the index, measured here on its own.
                var searched = index
                least[step].search = min(least[step].search, try measureThreadCPU { searched.search(SearchQuery(query)) }.elapsed)
                index.adoptTokens(from: searched)
                model.query = query
                await model.settle() // the event gate: the model indexed the notes and its search answered
                for _ in 0..<2 {
                    let (content, elapsed) = try measureThreadCPU { model.content }
                    least[step].content = min(least[step].content, elapsed)
                    if query.isEmpty {
                        XCTAssertEqual(content.sections.flatMap(\.rows).count, 1_000, "the cleared query lists every note")
                    } else {
                        XCTAssertNotNil(content.results)
                    }
                }
            }
        }
        func ms(_ duration: Duration) -> String { String(format: "%.2f ms", duration / .milliseconds(1)) }
        let slowest = least.max { $0.index + $0.content < $1.index + $1.content }!
        let search = least.map(\.search).max()!
        // Printed when it passes too, so the logs show how much of the frame is left.
        let measured = "indexing \(ms(slowest.index)) + content \(ms(slowest.content)) = \(ms(slowest.index + slowest.content)), "
            + "main-thread CPU, least of \(2 * passes) each; every keystroke: "
            + least.map { ms($0.index + $0.content) }.joined(separator: ", ")
        print("the main actor's part of the slowest keystroke: \(measured); the slowest search: \(ms(search)) of CPU")
        XCTAssertLessThan(slowest.index + slowest.content, .milliseconds(16),
                          "the main actor's part of the slowest keystroke fits in a frame (\(measured))")
        XCTAssertLessThan(search, .milliseconds(400), "the search, off the main actor, costs \(ms(search)) of CPU")
    }
}

/// The notes of the thousand-note check, observed as `LibraryStore.notes` is.
@MainActor @Observable private final class Notes {
    var all: [Note]
    init(_ all: [Note]) { self.all = all }
}
