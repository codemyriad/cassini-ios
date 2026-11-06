import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// Android's SpeakerStatsTest in seconds; the draft cases read the format's words in milliseconds, as Android's.
@Suite struct SpeakerStatsTests {
    /// One passage per word, as Android's words.
    func w(_ speaker: String, _ start: Double, _ end: Double, _ text: String = "sample") -> TranscriptSegment {
        TranscriptSegment(text: text, start: start, end: end, speakerID: speaker,
                          words: [TimedWord(text: text, start: start, end: end)])
    }

    func stat(_ speaker: String, _ transcript: [TranscriptSegment]) throws -> SpeakerStat {
        try #require(SpeakerStats.of(speaker, in: transcript))
    }

    // ports: SpeakerStatsTest#anEmptyTranscriptHasNoSpeakers
    @Test func anEmptyTranscriptHasNoSpeakers() {
        #expect(SpeakerStats.of([]).isEmpty)
    }

    // ports: SpeakerStatsTest#countsComeFromTheTurns
    @Test func countsComeFromTheTurns() throws {
        let words = [w("b", 0.5, 0.9, "So,"), w("b", 1.0, 2.5, "Thursday."), w("a", 2.6, 3.0, "Yes."),
                     w("b", 3.1, 3.6, "Good."), w("a", 3.7, 4.0, "Sure"), w("a", 4.1, 4.6, "Élodie.")]
        let stats = SpeakerStats.of(words)
        #expect(stats.map(\.speakerID) == ["b", "a"])

        let b = stats[0]
        #expect(b.ordinal == 0)
        #expect(abs(b.speakingTime - ((2.5 - 0.5) + (3.6 - 3.1))) < 1e-9)
        #expect(b.turnCount == 2)
        #expect(b.wordCount == 3)
        #expect(b.firstStart == 0.5)
        #expect(b.sample == SampleWindow(start: 0.5, end: 2.5))

        let a = stats[1]
        #expect(a.ordinal == 1)
        #expect(abs(a.speakingTime - ((3.0 - 2.6) + (4.6 - 3.7))) < 1e-9)
        #expect(a.turnCount == 2)
        #expect(a.wordCount == 3)
        #expect(a.firstStart == 2.6)
        #expect(a.sample == nil, "no turn of a reaches 1 s")
    }

    // ports: SpeakerStatsTest#theSampleIsTheLongestTurnCutAtTenSeconds
    @Test func theSampleIsTheLongestTurnCutAtTenSeconds() throws {
        let words = [w("a", 0, 2), w("b", 2.1, 2.5), w("a", 3, 20), w("b", 20.1, 20.5), w("a", 21, 30)]
        #expect(try stat("a", words).sample == SampleWindow(start: 3, end: 13))
    }

    // ports: SpeakerStatsTest#aTieGoesToTheEarliestTurn
    @Test func aTieGoesToTheEarliestTurn() throws {
        let words = [w("a", 5, 7), w("b", 7.1, 7.2), w("a", 1, 3), w("b", 3.1, 3.2), w("a", 8, 10)]
        #expect(try stat("a", words).sample == SampleWindow(start: 1, end: 3))
    }

    // ports: SpeakerStatsTest#aTurnOfExactlyOneSecondIsASample
    @Test func aTurnOfExactlyOneSecondIsASample() throws {
        #expect(try stat("a", [w("a", 0.25, 1.25)]).sample == SampleWindow(start: 0.25, end: 1.25))
        #expect(try stat("a", [w("a", 0.25, 1.24)]).sample == nil)
    }

    // ports: SpeakerStatsTest#aTurnSpansFirstStartToLastEnd
    @Test func aTurnSpansFirstStartToLastEnd() throws {
        // Several words make one turn: the sample covers the whole run, not one word.
        let stat = try stat("a", [w("a", 0, 0.4), w("a", 0.5, 0.9), w("a", 1.0, 1.4)])
        #expect(stat.speakingTime == 1.4)
        #expect(stat.sample == SampleWindow(start: 0, end: 1.4))
    }

    // ports: SpeakerStatsTest#aDraftAppliesItsMergesFirst
    @Test func aDraftAppliesItsMergesFirst() throws {
        let transcript = Transcript([Word("x1", 0, 1000, "sample"), Word("x2", 1100, 1500, "sample"),
                                     Word("x3", 1600, 2000, "sample"), Word("x1", 2100, 2500, "sample")])
        let stats = try SpeakerStats.of(draft: transcript, merges: ["x2": "x1"])
        #expect(stats.map(\.speakerID) == ["x1", "x3"])
        let x1 = stats[0]
        // x1 and the merged x2 form one turn 0..1500, then x1 again 2100..2500.
        #expect(x1.turnCount == 2)
        #expect(x1.wordCount == 3)
        #expect(abs(x1.speakingTime - (1.5 + 0.4)) < 1e-9)
        #expect(x1.sample == SampleWindow(start: 0, end: 1.5))
        #expect(stats[1].ordinal == 1)
    }

    // ports: SpeakerStatsTest#withoutMergesTheDraftOverloadMatchesThePlainOne
    @Test func withoutMergesTheDraftOverloadMatchesThePlainOne() throws {
        let words = [Word("a", 0, 1000, "sample"), Word("b", 1000, 3000, "sample"), Word("a", 3000, 3500, "sample")]
        #expect(SpeakerStats.of(words: words) == (try SpeakerStats.of(draft: Transcript(words), merges: [:])))
        #expect(SpeakerStats.of(words: words).map(\.speakerID) == ["a", "b"])
    }

    /// iOS: a passage without a speaker belongs to nobody but ends the turn before it.
    @Test func aPassageWithoutASpeakerEndsATurn() throws {
        let words = [w("a", 0, 1), TranscriptSegment(text: "…", start: 1, end: 2), w("a", 2, 3)]
        #expect(try stat("a", words).turnCount == 2)
        #expect(SpeakerStats.of(words).map(\.speakerID) == ["a"])
        var note = Note(title: "Stats")
        note.transcript = words
        #expect(note.speakingTime(for: "a") == 2)
        #expect(note.speakingTime(for: "nobody") == 0)
    }
}
