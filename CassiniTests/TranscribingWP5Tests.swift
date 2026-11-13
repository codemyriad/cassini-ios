import SwiftUI
import Testing
import CassiniNotebook
@testable import Cassini

@MainActor @Suite struct TranscribingWP5Tests {
    // ports: TranscribingDraftInkTest#stableDraftWordsUseFullInkAndTentativeWordsUseFaint
    @Test(arguments: [ColorScheme.light, .dark])
    func draftTurnsRenderSettledWordsInFullInkAndUnsettledWordsInFaint(_ scheme: ColorScheme) throws {
        let words = [
            DraftWord(speaker: "speaker_0", startMs: 0, endMs: 400, text: "Settled"),
            DraftWord(speaker: "speaker_0", startMs: 450, endMs: 900, text: "words"),
            DraftWord(speaker: "speaker_0", startMs: 1_100, endMs: 1_500, text: "tentative"),
        ]
        let transcript = NoteTranscripts.draft(words, tentativeFromMs: 1_000)
        let turn = try #require(transcript.turns.first)
        #expect(turn.unsettledWordIndices == [2])

        let attributed = TurnView(input: TurnRenderInput(turn: turn, style: .draft)).attributed
        var env = EnvironmentValues()
        env.colorScheme = scheme
        let expectedInk = Color.ink.resolve(in: env)
        let expectedMuted = Color.muted.resolve(in: env)
        let expectedFaint = Color.faint.resolve(in: env)

        func resolvedForeground(for wordIndex: Int) throws -> Color.Resolved {
            let offsets = turn.range(ofWord: wordIndex)
            let start = attributed.characters.index(attributed.characters.startIndex, offsetBy: offsets.lowerBound)
            let end = attributed.characters.index(start, offsetBy: offsets.count)
            let color = try #require(attributed[start..<end].foregroundColor)
            return color.resolve(in: env)
        }

        let first = try resolvedForeground(for: 0)
        let second = try resolvedForeground(for: 1)
        let third = try resolvedForeground(for: 2)
        #expect(first == expectedInk)
        #expect(second == expectedInk)
        #expect(first != expectedMuted)
        #expect(third == expectedFaint)
    }

    // ports: TranscribingPresentationTest + TranscriptionStopFeedbackTest
    @Test func transcribingPresentationRetainsLiveFiguresWhileStoppingAndMarksStopBusy() {
        let starting = TranscribingPresentation.of(phase: .starting)
        #expect(starting.percent == 0)
        #expect(starting.progress.step == .reading)
        #expect(!starting.stopBusy)

        let waiting = TranscribingPresentation.of(phase: .waitingForPrevious)
        #expect(waiting.progress.headline == .waitingForPrevious)
        #expect(!waiting.stopBusy)

        let live = RunningProgress(
            headline: .findingWords,
            percent: 52,
            step: .words,
            speakersSkipped: false,
            timeLeft: .range(lowMs: 360_000, highMs: 540_000),
            doneMs: 1_793_000,
            totalMs: 2_893_000,
            battery: .projected(percentNow: 78, percentAtFinish: 69),
            words: 1_420,
            lowMemory: true
        )
        let draft = DraftState(words: [DraftWord(speaker: "speaker_0", startMs: 0, endMs: 500, text: "Hello")],
                               tentativeFromMs: 500)

        let running = TranscribingPresentation.of(phase: .transcribing(live, draft))
        #expect(running.percent == 52)
        #expect(running.progress == live)
        #expect(!running.stopBusy)

        let reentrantStopping = TranscribingPresentation.of(phase: .transcribing(live, draft), runningStateStopping: true)
        #expect(reentrantStopping.percent == 52)
        #expect(reentrantStopping.progress == live)
        #expect(reentrantStopping.stopBusy)

        let stopping = TranscribingPresentation.of(phase: .stopping(StoppingProgress(progress: live, draft: draft)))
        #expect(stopping.percent == 52)
        #expect(stopping.progress == live)
        #expect(stopping.stopBusy)

        let stoppingFromStart = TranscribingPresentation.of(phase: .stopping())
        #expect(stoppingFromStart.percent == 0)
        #expect(stoppingFromStart.stopBusy)
    }

    @Test func compactSuggestionQuestionEmphasizesTheSuggestedSpeakerName() throws {
        let text = CompactSuggestionRow.question("Luca")
        #expect(String(text.characters) == MeetingPhase1Copy.speakerSuggestion(name: "Luca"))
        let emphasized = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(emphasized.count == 1)
        let run = try #require(emphasized.first)
        #expect(String(text[run.range].characters) == "Luca")
    }
}
