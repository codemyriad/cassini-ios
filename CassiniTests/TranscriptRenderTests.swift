import SwiftUI
import XCTest
import CassiniNotebook
@testable import Cassini

/// The transcript redraws only the paragraphs whose active word changed (the plan's render-count check for long
/// notes; Android `TurnParagraph`'s recomposition probe).
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

    /// An hour of one speaker, then another: 120-word sentences make paragraphs of 120 words.
    private func longNote() -> Note {
        var note = Note(title: "Long")
        var start = 0.0
        for passage in 0..<60 {
            let words = (0..<120).map { i -> TimedWord in
                defer { start += 0.5 }
                return TimedWord(text: i == 119 ? "end." : "word\(i)", start: start, end: start + 0.4)
            }
            note.transcript.append(TranscriptSegment(text: words.map(\.text).joined(separator: " "), start: words[0].start,
                                                     end: words[119].end, speakerID: passage < 30 ? "a" : "b", words: words))
        }
        return note
    }

    private func settle(_ window: UIWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
    }

    func testANewActiveWordRedrawsOnlyTheParagraphsThatHoldTheOldAndTheNewWord() {
        let transcript = NoteTranscripts.sealed(longNote())
        XCTAssertEqual(transcript.turns.count, 60)
        let model = Model()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: Host(model: model, transcript: transcript))
        window.makeKeyAndVisible()
        settle(window)
        let first = transcript.turns[0].id, second = transcript.turns[1].id
        XCTAssertFalse(TurnRenderProbe.renders.isEmpty, "the paragraphs on screen were drawn")
        XCTAssertNil(TurnRenderProbe.renders[transcript.turns[59].id], "paragraphs far off screen are not made")

        TurnRenderProbe.reset()
        model.active = WordRef(turnID: first, index: 3)
        settle(window)
        XCTAssertEqual(Set(TurnRenderProbe.renders.keys), [first])

        TurnRenderProbe.reset()
        model.active = WordRef(turnID: first, index: 4)
        settle(window)
        XCTAssertEqual(Set(TurnRenderProbe.renders.keys), [first])

        TurnRenderProbe.reset()
        model.active = WordRef(turnID: second, index: 0)
        settle(window)
        XCTAssertEqual(Set(TurnRenderProbe.renders.keys), [first, second])

        TurnRenderProbe.reset()
        model.active = WordRef(turnID: second, index: 0)
        settle(window)
        XCTAssertTrue(TurnRenderProbe.renders.isEmpty, "a tick inside the same word redraws nothing")
        window.isHidden = true
    }
}
