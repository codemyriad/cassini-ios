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

    private func settle(_ window: UIWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
    }

    /// The lazy stack finishes its work (rows it makes ahead of the scroll) over a few run loop passes, later on a
    /// busy machine; waits until a pass draws nothing.
    private func settleUntilIdle(_ window: UIWindow, passes: Int = 20) {
        for _ in 0..<passes {
            RenderProbe.reset()
            settle(window)
            if RenderProbe.renders.isEmpty { return }
        }
        XCTFail("the transcript kept drawing on its own: \(RenderProbe.renders)")
    }

    /// SwiftUI learns how to compare a view type in the background, and until it has, it redraws a paragraph whose
    /// inputs did not change (for seconds on a busy machine). Makes `change` until it redraws only `expected`, for up
    /// to `timeout`, so the checks that follow measure the steady state a long playback runs in.
    private func warmUp(_ window: UIWindow, expected: Set<String>, timeout: TimeInterval = 30, _ change: (Int) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            RenderProbe.reset()
            change(attempt)
            settle(window)
            if Set(RenderProbe.renders.keys) == expected { return }
            attempt += 1
        }
    }

    func testANewActiveWordRedrawsOnlyTheParagraphsThatHoldTheOldAndTheNewWord() {
        let transcript = NoteTranscripts.sealed(longNote())
        XCTAssertEqual(transcript.turns.count, 180)
        let model = Model()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: Host(model: model, transcript: transcript))
        window.makeKeyAndVisible()
        settle(window)
        let first = transcript.turns[0].id, second = transcript.turns[1].id
        XCTAssertFalse(RenderProbe.renders.isEmpty, "the paragraphs on screen were drawn")
        XCTAssertNil(RenderProbe.renders[transcript.turns[179].id], "paragraphs far off screen are not made")
        settleUntilIdle(window)
        warmUp(window, expected: [first]) { model.active = WordRef(turnID: first, index: 5 + $0 % 2) }

        RenderProbe.reset()
        model.active = WordRef(turnID: first, index: 3)
        settle(window)
        XCTAssertEqual(Set(RenderProbe.renders.keys), [first])

        RenderProbe.reset()
        model.active = WordRef(turnID: first, index: 4)
        settle(window)
        XCTAssertEqual(Set(RenderProbe.renders.keys), [first])

        RenderProbe.reset()
        model.active = WordRef(turnID: second, index: 0)
        settle(window)
        XCTAssertEqual(Set(RenderProbe.renders.keys), [first, second])

        RenderProbe.reset()
        model.active = WordRef(turnID: second, index: 0)
        settle(window)
        XCTAssertTrue(RenderProbe.renders.isEmpty, "a tick inside the same word redraws nothing")
        window.isHidden = true
    }

    /// The whole Note screen over the app's player: moving the position redraws the paragraphs of the old and the new
    /// active word, and not the screen, its header or its banners.
    func testAPlaybackTickOnTheNoteScreenRedrawsOnlyTheActiveParagraphs() async throws {
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
            rootView: NavigationStack { NoteDetailView(noteID: note.id) }.environment(test.graph))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        settle(window)
        let playback = test.graph.playback
        XCTAssertTrue(playback.owns(note.id), "the screen opened the player")
        XCTAssertNotNil(RenderProbe.renders["header"])

        let first = transcript.turns[0].id, second = transcript.turns[1].id
        warmUp(window, expected: [first]) { playback.seek($0 % 2 == 0 ? 2.6 : 3.1) }
        playback.seek(1.1)
        settle(window)
        RenderProbe.reset()
        playback.seek(1.6)
        settle(window)
        XCTAssertEqual(Set(RenderProbe.renders.keys), [first], "a new word in the same paragraph")

        // The lazy stack finishes its work over a few run loop passes; once it has, nothing draws on its own.
        settle(window); settle(window)
        RenderProbe.reset()
        settle(window)
        XCTAssertTrue(RenderProbe.renders.isEmpty, "an idle screen draws nothing: \(RenderProbe.renders)")

        playback.seek(1.7)
        settle(window)
        XCTAssertTrue(RenderProbe.renders.isEmpty, "a tick inside the same word: \(RenderProbe.renders)")

        RenderProbe.reset()
        playback.seek(60.1)
        settle(window)
        XCTAssertEqual(Set(RenderProbe.renders.keys), [first, second], "the old and the new active paragraph only")
    }
}
