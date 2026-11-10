import SwiftUI
import XCTest
import CassiniEngine
import CassiniNotebook
@testable import Cassini

/// The transcript redraws only the paragraphs whose active word changed, and a playback tick leaves the rest of the
/// Note screen alone (the plan's render-count check for long notes; Android `TurnParagraph`'s recomposition probe).
@MainActor final class TranscriptRenderTests: XCTestCase {
    @Observable final class Model {
        var active: WordRef?
    }

    private struct Host: View {
        let model: Model
        let transcript: NoteTranscript
        var body: some View {
            ScrollView { TranscriptList(transcript: transcript, activeWord: model.active) }
        }
    }

    /// Three hours of two speakers, a minute each, with word times: 120-word sentences make paragraphs of 120 words.
    private func longNote(passages: Int = 180) -> Note {
        var note = Note(title: "Long", audioFilename: "audio.caf")
        note.status = .ready
        note.duration = Double(passages) * 60
        note.speakers = [NoteSpeaker(id: "a", name: "Ada"), NoteSpeaker(id: "b", name: "Bruno")]
        var start = 0.0
        for passage in 0..<passages {
            let words = (0..<120).map { i -> TimedWord in
                defer { start += 0.5 }
                return TimedWord(text: i == 119 ? "end." : "word\(i)", start: start, end: start + 0.4)
            }
            note.transcript.append(TranscriptSegment(text: words.map(\.text).joined(separator: " "), start: words[0].start,
                                                     end: words[119].end, speaker: passage % 2 == 0 ? "Ada" : "Bruno",
                                                     speakerID: passage % 2 == 0 ? "a" : "b", words: words))
        }
        return note
    }

    /// A real display callback gives SwiftUI a rendering opportunity. No elapsed interval decides
    /// success. The timeout only reports a simulator that stopped delivering frames.
    private final class Frame: NSObject {
        let event = XCTestExpectation(description: "display frame")
        var link: CADisplayLink?

        func start() {
            link = CADisplayLink(target: self, selector: #selector(drawn))
            link?.add(to: .main, forMode: .common)
        }

        @objc private func drawn() {
            link?.invalidate()
            event.fulfill()
        }
    }

    /// Drain rendering opportunities until the probe stays unchanged across three consecutive
    /// passes. A plain run-loop idle callback can fire before SwiftUI has rendered anything.
    private func settle(_ window: UIWindow, quietPasses: Int = 3,
                        file: StaticString = #filePath, line: UInt = #line) async {
        var previous = RenderProbe.renders
        var quiet = 0
        for _ in 0..<120 {
            let frame = Frame()
            frame.start()
            await fulfillment(of: [frame.event], timeout: 30)
            frame.link?.invalidate()
            window.layoutIfNeeded()
            let current = RenderProbe.renders
            quiet = current == previous ? quiet + 1 : 0
            if quiet == quietPasses { return }
            previous = current
        }
        XCTFail("the transcript kept drawing across 120 display passes: \(RenderProbe.renders)", file: file, line: line)
    }

    /// SwiftUI learns view comparisons in the background. Exercise real input changes until
    /// three consecutive updates render exactly the expected paragraphs; idle alone is not readiness.
    /// An attempt cap replaces the old deadline as the bound on this warm-up.
    private func warmUp(_ window: UIWindow, expected: Set<String>, steady: Int = 3, attempts: Int = 120,
                        _ change: (Int) -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        var inARow = 0
        var last: [String: Int] = [:]
        for attempt in 0..<attempts {
            RenderProbe.reset()
            change(attempt)
            await settle(window)
            last = RenderProbe.renders
            inARow = Set(last.keys) == expected ? inARow + 1 : 0
            if inARow == steady { return }
        }
        XCTFail("never redrew only \(expected) \(steady) times in a row across \(attempts) updates; last: \(last)",
                file: file, line: line)
    }

    func testANewActiveWordRedrawsOnlyTheParagraphsThatHoldTheOldAndTheNewWord() async {
        RenderProbe.reset()
        let transcript = NoteTranscripts.sealed(longNote())
        XCTAssertEqual(transcript.turns.count, 180)
        let model = Model()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: Host(model: model, transcript: transcript))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await settle(window)
        let first = transcript.turns[0].id, second = transcript.turns[1].id
        XCTAssertFalse(RenderProbe.renders.isEmpty, "the paragraphs on screen were drawn")
        XCTAssertNil(RenderProbe.renders[transcript.turns[179].id], "paragraphs far off screen are not made")
        await settle(window)
        await warmUp(window, expected: [first]) { model.active = WordRef(turnID: first, index: 5 + $0 % 2) }

        RenderProbe.reset()
        model.active = WordRef(turnID: first, index: 3)
        await settle(window)
        XCTAssertEqual(Set(RenderProbe.renders.keys), [first])

        RenderProbe.reset()
        model.active = WordRef(turnID: first, index: 4)
        await settle(window)
        XCTAssertEqual(Set(RenderProbe.renders.keys), [first])

        RenderProbe.reset()
        model.active = WordRef(turnID: second, index: 0)
        await settle(window)
        XCTAssertEqual(Set(RenderProbe.renders.keys), [first, second])

        RenderProbe.reset()
        model.active = WordRef(turnID: second, index: 0)
        await settle(window)
        XCTAssertTrue(RenderProbe.renders.isEmpty, "a tick inside the same word redraws nothing")
    }

    /// The whole Note screen over the app's player: moving the position redraws the paragraphs of the old and the new
    /// active word, and not the screen, its header or its banners.
    func testAPlaybackTickOnTheNoteScreenRedrawsOnlyTheActiveParagraphs() async throws {
        RenderProbe.reset()
        let test = TestGraph(); defer { test.tearDown() }
        let note = longNote()
        try NoteRepository(root: test.root).save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        test.playback.fileDuration = note.duration
        await test.graph.start()
        let transcript = NoteTranscripts.sealed(note)
        XCTAssertEqual(transcript.turns.count, 180)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(
            rootView: NavigationStack { NoteDetailView(model: test.graph.noteScreens.model(note.id, query: nil)) }.environment(test.graph))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await settle(window)
        let playback = test.graph.playback
        XCTAssertTrue(playback.owns(note.id), "the screen opened the player")
        XCTAssertNotNil(RenderProbe.renders["header"])

        let first = transcript.turns[0].id, second = transcript.turns[1].id
        await warmUp(window, expected: [first]) { playback.seek($0 % 2 == 0 ? 2.6 : 3.1) }
        playback.seek(1.1)
        // The launch's own updates (the banners, the lazy stack's rows ahead) land over a few passes on a busy machine.
        await settle(window)
        RenderProbe.reset()
        playback.seek(1.6)
        await settle(window)
        XCTAssertEqual(Set(RenderProbe.renders.keys), [first], "a new word in the same paragraph")

        // The lazy stack finishes its work over a few run loop passes; once it has, nothing draws on its own.
        RenderProbe.reset()
        await settle(window)
        XCTAssertTrue(RenderProbe.renders.isEmpty, "an idle screen draws nothing: \(RenderProbe.renders)")

        // Ticks inside one word (word 3 spans 1.5-1.9 s) reach their steady state, then one more draws nothing.
        await warmUp(window, expected: []) { playback.seek($0 % 2 == 0 ? 1.7 : 1.8) }
        RenderProbe.reset()
        playback.seek(1.75)
        await settle(window)
        XCTAssertTrue(RenderProbe.renders.isEmpty, "a tick inside the same word: \(RenderProbe.renders)")

        RenderProbe.reset()
        playback.seek(60.1)
        await settle(window)
        XCTAssertEqual(Set(RenderProbe.renders.keys), [first, second], "the old and the new active paragraph only")
    }
}
