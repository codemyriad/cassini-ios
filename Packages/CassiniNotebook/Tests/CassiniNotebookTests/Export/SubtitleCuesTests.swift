import CassiniCore
import Testing
@testable import CassiniNotebook

struct SubtitleCuesTests {
    private func cues(_ words: [Word], srt: Bool = false) -> [Cue] { SubtitleCues.build(transcript(words), labelPrefixForSrt: srt) }
    private func texts(_ words: [Word], srt: Bool = false) -> [String] { cues(words, srt: srt).map(\.text) }
    private func spans(_ cues: [Cue]) -> [[Int64]] { cues.map { [$0.startMs, $0.endMs] } }
    private let eleven = Array(repeating: "parola", count: 11).joined(separator: " ")

    // ports: SubtitleCuesTest#noWordsGiveNoCues
    @Test func noWordsGiveNoCues() {
        #expect(cues([]).isEmpty)
    }

    // ports: SubtitleCuesTest#rule1SpeakerChange
    @Test func rule1SpeakerChange() {
        #expect(texts([w("spk_0", 0, 400, "Sì"), w("spk_0", 500, 900, "Bene")]) == ["Sì Bene"])
        #expect(texts([w("spk_0", 0, 400, "Sì"), w("spk_1", 500, 900, "Bene")]) == ["Sì", "Bene"])
    }

    // ports: SubtitleCuesTest#rule2PauseOfAtLeast1500Ms
    @Test func rule2PauseOfAtLeast1500Ms() {
        #expect(texts([w("spk_0", 0, 400, "uno"), w("spk_0", 1899, 2300, "due")]) == ["uno due"])
        #expect(texts([w("spk_0", 0, 400, "uno"), w("spk_0", 1900, 2300, "due")]) == ["uno", "due"])
    }

    // ports: SubtitleCuesTest#rule3CueLongerThan6000Ms
    @Test func rule3CueLongerThan6000Ms() {
        #expect(texts([w("spk_0", 0, 5000, "uno"), w("spk_0", 5000, 6000, "due")]) == ["uno due"])
        #expect(texts([w("spk_0", 0, 5000, "uno"), w("spk_0", 5000, 6001, "due")]) == ["uno", "due"])
    }

    // ports: SubtitleCuesTest#rule4TextLongerThan84
    @Test func rule4TextLongerThan84() {
        let fits = said("spk_0", 0, "\(eleven) settimo x", stepMs: 100)
        #expect(texts(fits) == ["\(eleven) settimo", "x"])
        #expect(texts(fits).first?.utf16.count == 84)
        let over = said("spk_0", 0, "\(eleven) ottavo_8", stepMs: 100)
        #expect(texts(over) == [eleven, "ottavo_8"])
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
        #expect(texts([w("spk_0", 0, 1499, "Sì."), w("spk_0", 1499, 1800, "Bene")]) == ["Sì. Bene"])
        for end in [".", "?", "!", "…", "。", "？", "！"] {
            let words = [w("spk_0", 0, 1500, "Sì\(end)"), w("spk_0", 1500, 1800, "Bene")]
            #expect(texts(words) == ["Sì\(end)", "Bene"], "\(end)")
        }
        #expect(texts([w("spk_0", 0, 1600, "Sì,"), w("spk_0", 1600, 1800, "Bene")]) == ["Sì, Bene"])
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
        #expect(spans(cues([w("spk_0", 0, 200, "Ok"), w("spk_0", 600, 6700, "lunghissima")])) == [[0, 600], [600, 6700]])
        // The next cue after a pause leaves the full second.
        #expect(spans(cues([w("spk_0", 0, 200, "Ok"), w("spk_0", 1700, 1900, "Bene")])) == [[0, 1000], [1700, 2700]])
    }

    // ports: SubtitleCuesTest#differentSpeakersMayOverlap
    @Test func differentSpeakersMayOverlap() {
        #expect(spans(cues([w("spk_0", 0, 200, "Ok"), w("spk_1", 300, 700, "Sì")])) == [[0, 1000], [300, 1300]])
    }

    // ports: SubtitleCuesTest#cuesAreSortedWhileWordsKeepCanonicalOrder
    @Test func cuesAreSortedWhileWordsKeepCanonicalOrder() {
        let words = [w("spk_0", 5000, 5400, "seconda"), w("spk_0", 4900, 5600, "frase"),
                     w("spk_1", 1000, 1400, "prima"), w("spk_1", 1500, 1900, "parte")]
        let sorted = cues(words)
        #expect(sorted.map(\.text) == ["prima parte", "seconda frase"])
        #expect(spans(sorted) == [[1000, 2000], [5000, 6000]])
    }

    // ports: SubtitleCuesTest#equalStartsKeepCanonicalOrder
    @Test func equalStartsKeepCanonicalOrder() {
        #expect(texts([w("spk_1", 1000, 1400, "uno"), w("spk_0", 1000, 1400, "due")]) == ["uno", "due"])
    }

    // ports: SubtitleCuesTest#srtPrefixFollowsOutputOrder
    @Test func srtPrefixFollowsOutputOrder() {
        // Canonical order: Speaker 2, then Paolo twice (a pause splits Paolo). Sorted: Paolo, Speaker 2, Paolo.
        let words = [w("spk_1", 1000, 1400, "Allora"), w("spk_0", 0, 300, "Io"), w("spk_0", 400, 700, "direi"),
                     w("spk_0", 2500, 2900, "comunque"), w("spk_0", 4500, 4900, "basta")]
        let srt = cues(words, srt: true)
        #expect(srt.map(\.text) == ["Io direi", "Allora", "comunque", "basta"])
        #expect(srt.map(\.prefix) == ["Paolo: ", "Speaker 2: ", "Paolo: ", ""])
        #expect(srt.map(\.lines) == [["Paolo: Io direi"], ["Speaker 2: Allora"], ["Paolo: comunque"], ["basta"]])
    }

    // ports: SubtitleCuesTest#shortTextStaysOnOneLine
    @Test func shortTextStaysOnOneLine() {
        let text = String(repeating: "a", count: 42)
        #expect(SubtitleCues.lines(text) == [text])
    }

    // ports: SubtitleCuesTest#longTextIsBalancedOnTwoLines
    @Test func longTextIsBalancedOnTwoLines() {
        // 71 characters; the spaces at 28, 36 and 39 give two lines of at most 42, and 36 gives 36 + 34.
        let text = "Abbiamo deciso che la data è giusta, ma prima di chiudere servono firme"
        #expect(SubtitleCues.lines(text) == ["Abbiamo deciso che la data è giusta,", "ma prima di chiudere servono firme"])
        // The spaces at 20 and 22 of 43 characters balance equally (20 + 22, 22 + 20): the shorter first line wins.
        let a = String(repeating: "a", count: 20), c = String(repeating: "c", count: 20)
        #expect(SubtitleCues.lines("\(a) b \(c)") == [a, "b \(c)"])
    }

    // ports: SubtitleCuesTest#withoutABalancedSplitTheLastSpaceWithin42Wins
    @Test func withoutABalancedSplitTheLastSpaceWithin42Wins() {
        let long = String(repeating: "x", count: 45)
        #expect(SubtitleCues.lines("Il codice è \(long)") == ["Il codice è", long])
        let giant = String(repeating: "y", count: 50)
        #expect(SubtitleCues.lines("\(giant) e poi") == [giant, "e poi"])
        #expect(SubtitleCues.lines(String(repeating: "z", count: 90)) == [String(repeating: "z", count: 90)])
    }

    // ports: SubtitleCuesTest#theSplitNeverFallsInsideTheLabelPrefix
    @Test func theSplitNeverFallsInsideTheLabelPrefix() {
        let text = "Speaker 2: " + String(repeating: "a", count: 35) + " " + String(repeating: "b", count: 10)
        #expect(SubtitleCues.lines(text, from: 11) == ["Speaker 2: " + String(repeating: "a", count: 35), String(repeating: "b", count: 10)])
    }
}
