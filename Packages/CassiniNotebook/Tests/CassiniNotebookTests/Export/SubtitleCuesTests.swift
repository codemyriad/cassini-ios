import CassiniCore
import Testing
@testable import CassiniNotebook

struct SubtitleCuesTests {
    private func cues(_ words: [Word], srt: Bool = false) -> [Cue] { SubtitleCues.build(transcript(words), labelPrefixForSrt: srt) }
    private func texts(_ words: [Word], srt: Bool = false) -> [String] { cues(words, srt: srt).map(\.text) }
    private func spans(_ cues: [Cue]) -> [[Int64]] { cues.map { [$0.startMs, $0.endMs] } }
    private let eleven = Array(repeating: "sample", count: 11).joined(separator: " ")

    // ports: SubtitleCuesTest#noWordsGiveNoCues
    @Test func noWordsGiveNoCues() {
        #expect(cues([]).isEmpty)
    }

    // ports: SubtitleCuesTest#rule1SpeakerChange
    @Test func rule1SpeakerChange() {
        #expect(texts([w("spk_0", 0, 400, "Yes"), w("spk_0", 500, 900, "Good")]) == ["Yes Good"])
        #expect(texts([w("spk_0", 0, 400, "Yes"), w("spk_1", 500, 900, "Good")]) == ["Yes", "Good"])
    }

    // ports: SubtitleCuesTest#rule2PauseOfAtLeast1500Ms
    @Test func rule2PauseOfAtLeast1500Ms() {
        #expect(texts([w("spk_0", 0, 400, "one"), w("spk_0", 1899, 2300, "two")]) == ["one two"])
        #expect(texts([w("spk_0", 0, 400, "one"), w("spk_0", 1900, 2300, "two")]) == ["one", "two"])
    }

    // ports: SubtitleCuesTest#rule3CueLongerThan6000Ms
    @Test func rule3CueLongerThan6000Ms() {
        #expect(texts([w("spk_0", 0, 5000, "one"), w("spk_0", 5000, 6000, "two")]) == ["one two"])
        #expect(texts([w("spk_0", 0, 5000, "one"), w("spk_0", 5000, 6001, "two")]) == ["one", "two"])
    }

    // ports: SubtitleCuesTest#rule4TextLongerThan84
    @Test func rule4TextLongerThan84() {
        let fits = said("spk_0", 0, "\(eleven) seventh x", stepMs: 100)
        #expect(texts(fits) == ["\(eleven) seventh", "x"])
        #expect(texts(fits).first?.utf16.count == 84)
        let over = said("spk_0", 0, "\(eleven) eighth_8", stepMs: 100)
        #expect(texts(over) == [eleven, "eighth_8"])
    }

    // ports: SubtitleCuesTest#rule4CountsTheSrtPrefixOfASpeakersFirstCue
    @Test func rule4CountsTheSrtPrefixOfASpeakersFirstCue() {
        // "Paolo: " (7) + 76 + " x" would be 85 characters.
        let words = said("spk_0", 0, "\(eleven) x", stepMs: 100) + [w("spk_1", 3000, 3300, "Ok")]
        #expect(texts(words, srt: false) == ["\(eleven) x", "Ok"])
        let srt = cues(words, srt: true)
        #expect(srt.map(\.text) == [eleven, "x", "Ok"])
        #expect(srt.map(\.prefix) == ["Paolo: ", "", "Speaker 2: "])
    }

    // ports: SubtitleCuesTest#rule4WithOneSpeakerHasNoPrefixBudget
    @Test func rule4WithOneSpeakerHasNoPrefixBudget() {
        let one = cues(said("spk_0", 0, "\(eleven) x", stepMs: 100), srt: true)
        #expect(one.map(\.text) == ["\(eleven) x"])
        #expect(one.map(\.prefix) == [""])
    }

    // ports: SubtitleCuesTest#rule5SentenceEndOnceTheCueLasts1500Ms
    @Test func rule5SentenceEndOnceTheCueLasts1500Ms() {
        #expect(texts([w("spk_0", 0, 1499, "Yes."), w("spk_0", 1499, 1800, "Good")]) == ["Yes. Good"])
        for end in [".", "?", "!", "…", "。", "？", "！"] {
            let words = [w("spk_0", 0, 1500, "Yes\(end)"), w("spk_0", 1500, 1800, "Good")]
            #expect(texts(words) == ["Yes\(end)", "Good"], "\(end)")
        }
        #expect(texts([w("spk_0", 0, 1600, "Yes,"), w("spk_0", 1600, 1800, "Good")]) == ["Yes, Good"])
    }

    // ports: SubtitleCuesTest#shortCuesLastOneSecond
    @Test func shortCuesLastOneSecond() throws {
        let cue = try #require(cues([w("spk_0", 200, 400, "Ok")]).first)
        #expect(cue.startMs == 200)
        #expect(cue.endMs == 1200)
    }

    // ports: SubtitleCuesTest#theMinimumStopsAtTheSameSpeakersNextCue
    @Test func theMinimumStopsAtTheSameSpeakersNextCue() {
        // Rule 3 splits the two words; the second starts 600 ms after the first.
        #expect(spans(cues([w("spk_0", 0, 200, "Ok"), w("spk_0", 600, 6700, "verylong")])) == [[0, 600], [600, 6700]])
        // The next cue after a pause leaves the full second.
        #expect(spans(cues([w("spk_0", 0, 200, "Ok"), w("spk_0", 1700, 1900, "Good")])) == [[0, 1000], [1700, 2700]])
    }

    // ports: SubtitleCuesTest#differentSpeakersMayOverlap
    @Test func differentSpeakersMayOverlap() {
        #expect(spans(cues([w("spk_0", 0, 200, "Ok"), w("spk_1", 300, 700, "Yes")])) == [[0, 1000], [300, 1300]])
    }

    // ports: SubtitleCuesTest#cuesAreSortedWhileWordsKeepCanonicalOrder
    @Test func cuesAreSortedWhileWordsKeepCanonicalOrder() {
        let words = [w("spk_0", 5000, 5400, "second"), w("spk_0", 4900, 5600, "phrase"),
                     w("spk_1", 1000, 1400, "first"), w("spk_1", 1500, 1900, "part")]
        let sorted = cues(words)
        #expect(sorted.map(\.text) == ["first part", "second phrase"])
        #expect(spans(sorted) == [[1000, 2000], [5000, 6000]])
    }

    // ports: SubtitleCuesTest#equalStartsKeepCanonicalOrder
    @Test func equalStartsKeepCanonicalOrder() {
        #expect(texts([w("spk_1", 1000, 1400, "one"), w("spk_0", 1000, 1400, "two")]) == ["one", "two"])
    }

    // ports: SubtitleCuesTest#srtPrefixFollowsOutputOrder
    @Test func srtPrefixFollowsOutputOrder() {
        // Canonical order: Speaker 2, then Paolo twice (a pause splits Paolo). Sorted: Paolo, Speaker 2, Paolo.
        let words = [w("spk_1", 1000, 1400, "So"), w("spk_0", 0, 300, "I"), w("spk_0", 400, 700, "think"),
                     w("spk_0", 2500, 2900, "anyway"), w("spk_0", 4500, 4900, "enough")]
        let srt = cues(words, srt: true)
        #expect(srt.map(\.text) == ["I think", "So", "anyway", "enough"])
        #expect(srt.map(\.prefix) == ["Paolo: ", "Speaker 2: ", "Paolo: ", ""])
        #expect(srt.map(\.lines) == [["Paolo: I think"], ["Speaker 2: So"], ["Paolo: anyway"], ["enough"]])
    }

    // ports: SubtitleCuesTest#shortTextStaysOnOneLine
    @Test func shortTextStaysOnOneLine() {
        let text = String(repeating: "a", count: 42)
        #expect(SubtitleCues.lines(text) == [text])
    }

    // ports: SubtitleCuesTest#longTextIsBalancedOnTwoLines
    @Test func longTextIsBalancedOnTwoLines() {
        // 71 characters; the space at 33 balances the text into two lines of 33 and 37.
        let text = "We agreed that the date is right, but before closing we need signatures"
        #expect(SubtitleCues.lines(text) == ["We agreed that the date is right,", "but before closing we need signatures"])
        // The spaces at 20 and 22 of 43 characters balance equally (20 + 22, 22 + 20): the shorter first line wins.
        let a = String(repeating: "a", count: 20), c = String(repeating: "c", count: 20)
        #expect(SubtitleCues.lines("\(a) b \(c)") == [a, "b \(c)"])
    }

    // ports: SubtitleCuesTest#withoutABalancedSplitTheLastSpaceWithin42Wins
    @Test func withoutABalancedSplitTheLastSpaceWithin42Wins() {
        let long = String(repeating: "x", count: 45)
        #expect(SubtitleCues.lines("The code is \(long)") == ["The code is", long])
        let giant = String(repeating: "y", count: 50)
        #expect(SubtitleCues.lines("\(giant) and then") == [giant, "and then"])
        #expect(SubtitleCues.lines(String(repeating: "z", count: 90)) == [String(repeating: "z", count: 90)])
    }

    // ports: SubtitleCuesTest#theSplitNeverFallsInsideTheLabelPrefix
    @Test func theSplitNeverFallsInsideTheLabelPrefix() {
        let text = "Speaker 2: " + String(repeating: "a", count: 35) + " " + String(repeating: "b", count: 10)
        #expect(SubtitleCues.lines(text, from: 11) == ["Speaker 2: " + String(repeating: "a", count: 35), String(repeating: "b", count: 10)])
    }
}
