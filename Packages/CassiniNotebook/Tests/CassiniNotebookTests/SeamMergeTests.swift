import CassiniCore
import Testing
@testable import CassiniNotebook

/// Android's SeamMergeTest, one to one; its inputs and expectations mirror the desktop pipeline's overlap-dedup tests.
/// Android's `assertSame` checks which decode a kept copy came from; Swift words are values, so those checks run the
/// generic merge over words tagged with their decode.
@Suite struct SeamMergeTests {
    func w(_ text: String, _ startMs: Int64, _ endMs: Int64) -> Word { Word("a", startMs, endMs, text) }
    func merge(_ acc: [Word], _ next: [Word], _ windowStartMs: Int64, _ overlapMs: Int64, first: Bool = false) -> [Word] {
        SeamMerge.merge(acc, next, firstWindow: first, windowStartMs: windowStartMs, overlapMs: overlapMs)
    }
    func mergeFallback(_ acc: [Word], _ next: [Word], _ windowStartMs: Int64, _ overlapMs: Int64, first: Bool = false) -> [Word] {
        SeamMerge.merge(acc, next, firstWindow: first, windowStartMs: windowStartMs, overlapMs: overlapMs, midpointOnDisagreement: true)
    }

    struct Tagged { let from: String; let index: Int; let word: Word }
    func tag(_ words: [Word], _ from: String) -> [Tagged] { words.enumerated().map { Tagged(from: from, index: $0.offset, word: $0.element) } }
    /// Where each result came from, as "acc2" or "next1".
    func origins(_ items: [Tagged]) -> [String] { items.map { "\($0.from)\($0.index)" } }

    // ports: SeamMergeTest#keepsOverlapWordOnce
    @Test func keepsOverlapWordOnce() {
        let acc = [w("hello", 1000, 1400), w("world", 5000, 5400), w("shared", 14600, 14760), w("late", 14800, 14980)]
        let next = [w("shared", 14600, 14760), w("late", 14800, 14980), w("again", 16000, 16400), w("more", 20000, 20400)]
        let got = merge(acc, next, 14500, 500)
        #expect(got == [w("hello", 1000, 1400), w("world", 5000, 5400), w("shared", 14600, 14760),
                        w("late", 14800, 14980), w("again", 16000, 16400), w("more", 20000, 20400)])
        // "shared" has more left-window context, "late" more right-window context.
        let tagged = SeamMerge.merge(tag(acc, "acc"), tag(next, "next"), firstWindow: false, windowStartMs: 14500, overlapMs: 500) { $0.word }
        #expect(origins(tagged)[2] == "acc2")
        #expect(origins(tagged)[3] == "next1")
    }

    // ports: SeamMergeTest#handlesTimestampJitterAcrossOldMidpoint
    @Test func handlesTimestampJitterAcrossOldMidpoint() {
        for (accStart, nextStart) in [(Int64(9740), Int64(9760)), (9760, 9740)] {
            let acc = [w("before", 9000, 9200), w("Shared,", accStart, accStart + 100)]
            let next = [w("shared", nextStart, nextStart + 100), w("after", 10200, 10400)]
            let got = merge(acc, next, 9500, 500)
            #expect(got.count == 3)
            #expect(got.filter { SeamMerge.normalize($0.text) == "shared" }.count == 1)
        }
    }

    // ports: SeamMergeTest#retainsOneSidedOverlapWords
    @Test func retainsOneSidedOverlapWords() {
        let acc = [w("before", 9000, 9200), w("old-only", 9800, 9900)]
        let next = [w("new-only", 9700, 9800), w("after", 10200, 10400)]
        #expect(merge(acc, next, 9500, 500).map(\.text) == ["before", "new-only", "old-only", "after"])
    }

    // ports: SeamMergeTest#disagreeingFallbackSeamUsesMidpointOwnership
    @Test func disagreeingFallbackSeamUsesMidpointOwnership() {
        let acc = [w("before", 14000, 14200), w("recognize", 14600, 14900), w("old-late", 14820, 14920)]
        let next = [w("wreck", 14610, 14650), w("a", 14660, 14700), w("nice", 14810, 14850), w("after", 15100, 15300)]
        #expect(mergeFallback(acc, next, 14500, 500) == [acc[0], acc[1], next[2], next[3]])
        // The default policy keeps one-sided lexical evidence from both hypotheses.
        #expect(merge(acc, next, 14500, 500).count == acc.count + next.count)
    }

    // ports: SeamMergeTest#boundaryContactDoesNotTriggerDisagreementCut
    @Test func boundaryContactDoesNotTriggerDisagreementCut() {
        let acc = [w("before", 9300, 9500)]
        let next = [w("new-only", 9600, 9700), w("after", 10100, 10300)]
        #expect(mergeFallback(acc, next, 9500, 500) == [acc[0], next[0], next[1]])
    }

    // ports: SeamMergeTest#confidentMatchKeepsOneSidedWordUnderFallbackPolicy
    @Test func confidentMatchKeepsOneSidedWordUnderFallbackPolicy() {
        let acc = [w("shared", 9600, 9700)]
        let next = [w("shared", 9610, 9710), w("new-only", 9700, 9740), w("after", 10100, 10300)]
        #expect(mergeFallback(acc, next, 9500, 500).map(\.text) == ["shared", "new-only", "after"])
    }

    // ports: SeamMergeTest#replacesClampedBoundaryCopy
    @Test func replacesClampedBoundaryCopy() {
        let acc = [w("before", 9300, 9500), w("final", 10000, 10000)]
        let next = [w("final", 9800, 9950), w("after", 10100, 10300)]
        #expect(merge(acc, next, 9500, 500) == [w("before", 9300, 9500), w("final", 9800, 9950), w("after", 10100, 10300)])
    }

    // ports: SeamMergeTest#alignsShiftedPhrase
    @Test func alignsShiftedPhrase() {
        let acc = [w("I", 9400, 9500), w("can", 9500, 9660), w("pass", 9660, 9820), w("it", 9820, 9980)]
        let next = [w("pass", 9960, 10120), w("it", 10120, 10280), w("to", 10280, 10440)]
        #expect(merge(acc, next, 9500, 500).map(\.text) == ["I", "can", "pass", "it", "to"])
    }

    // ports: SeamMergeTest#keepsRapidRepeatedSingleton
    @Test func keepsRapidRepeatedSingleton() {
        let acc = [w("yes", 9550, 9650)]
        let next = [w("yes", 9900, 10000)]
        #expect(merge(acc, next, 9500, 500) == [acc[0], next[0]])
    }

    // ports: SeamMergeTest#keepsRapidZeroLengthNextSingleton
    @Test func keepsRapidZeroLengthNextSingleton() {
        let acc = [w("yes", 9600, 9700)]
        let next = [w("yes", 10000, 10000)]
        #expect(merge(acc, next, 9500, 500) == [acc[0], next[0]])
    }

    // ports: SeamMergeTest#preservesSemanticPunctuation
    @Test func preservesSemanticPunctuation() {
        let acc = [w("C++", 9700, 9800)]
        let next = [w("C#", 9710, 9810), w("C", 9720, 9820)]
        #expect(merge(acc, next, 9500, 500).count == 3)
        for (word, want) in [("C++", "c++"), ("C#", "c#"), ("a-b", "a-b"), ("ab", "ab"), ("\u{201C}DON\u{2019}T!\u{201D}", "don't"),
                             ("morning.", "morning"), ("morning,", "morning"), (".NET", ".net"), ("3.14", "3.14")] {
            #expect(scalars(SeamMerge.normalize(word)) == scalars(want), "\(word)")
        }
    }

    /// Compares code points, as Kotlin's String equality does; Swift's is canonical.
    func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    /// Expectations produced by running the Go normalizer on the same strings.
    // ports: SeamMergeTest#normalizeMatchesGoUnicodeHandling
    @Test func normalizeMatchesGoUnicodeHandling() {
        for (word, want) in [
            ("Perché?", "perché"), ("È", "è"), ("dell\u{2019}", "dell'"), ("L\u{2019}Aquila,", "l'aquila"), ("\u{2018}Sì\u{2019}", "'sì'"),
            ("po'", "po'"), ("«Ciao»", "«ciao»"), ("E\u{0300}", "e\u{0300}"), ("\u{00A0}più\u{00A0}", "più"), ("\u{2007}x\u{202F}", "x"),
            ("\u{001C}ok", "\u{001C}ok"), ("\u{200B}x", "\u{200B}x"), ("²", "²"), ("½.", "½"), ("Ⅻ", "ⅻ"), ("İstanbul", "istanbul"),
            ("ΣΟΦΟΣ", "σοφοσ"), ("\u{10400}", "\u{10428}"), ("...", ""), ("\u{201C}?\u{201D}", ""), ("morning,.", "morning,"),
            ("(nota.)", "nota"),
        ] {
            #expect(scalars(SeamMerge.normalize(word)) == scalars(want), "\(word)")
        }
    }

    // ports: SeamMergeTest#ignoresSentenceEndPunctuation
    @Test func ignoresSentenceEndPunctuation() {
        let acc = [w("Sunday", 85430, 85830), w("morning.", 85830, 86040)]
        let next = [w("Sunday", 85520, 85840), w("morning,", 85840, 86160), w("first", 86160, 86320)]
        let got = merge(acc, next, 85540, 500)
        #expect(got.count == 3)
        guard got.count == 3 else { return }
        #expect(SeamMerge.normalize(got[0].text) == "sunday")
        #expect(SeamMerge.normalize(got[1].text) == "morning")
        #expect(got[2].text == "first")
    }

    // ports: SeamMergeTest#italianApostropheVariantsMergeOnce
    @Test func italianApostropheVariantsMergeOnce() {
        let acc = [w("prima", 9000, 9200), w("dell\u{2019}anno.", 9700, 9900)]
        let next = [w("dell'anno,", 9720, 9920), w("dopo", 10100, 10300)]
        // The newer copy's midpoint sits 320 ms past the window start versus 200 ms before the overlap end.
        #expect(merge(acc, next, 9500, 500).map(\.text) == ["prima", "dell'anno,", "dopo"])
    }

    // ports: SeamMergeTest#keepsStableSourceOrderForEqualStarts
    @Test func keepsStableSourceOrderForEqualStarts() {
        let acc = [w("old", 9800, 10000)]
        let next = [w("new", 9800, 9900)]
        #expect(merge(acc, next, 9500, 500) == [acc[0], next[0]])
    }

    // ports: SeamMergeTest#firstWindowVerbatim
    @Test func firstWindowVerbatim() {
        let next = [w("a", 0, 100), w("b", 200, 300)]
        #expect(merge([], next, 0, 500, first: true) == next)
    }

    // ports: SeamMergeTest#expandedVadTurnSeamEmitsSharedWordOnce
    @Test func expandedVadTurnSeamEmitsSharedWordOnce() {
        // Context crops [0, 24000) and [16000, 40000) at 16 kHz: the seam starts at 1000 ms and overlaps 500 ms.
        let older = [w("yes.", 1200, 1350)]
        let newer = [w("yes,", 1210, 1360), w("next", 1600, 1800)]
        let got = merge(older, newer, 16000 / 16, (24000 - 16000) / 16)
        #expect(got.count == 2)
        guard got.count == 2 else { return }
        #expect(SeamMerge.normalize(got[0].text) == "yes")
        #expect(got[1].text == "next")
    }

    /// Model-free analogue of the chunked fallback: a word per second decoded by every window that covers it.
    // ports: SeamMergeTest#chunkedFallbackEndToEndKeepsEverySecondOnce
    @Test func chunkedFallbackEndToEndKeepsEverySecondOnce() {
        for rate in [16_000, 48_000] {
            let total = 75 * rate
            let window = 15 * rate
            let overlap = rate / 2
            let overlapMs = Int64(overlap) * 1000 / Int64(rate)
            var bounds: [(Int, Int)] = []
            var start = 0
            while start < total {
                let end = start + window
                if end >= total { bounds.append((start, total)); break }
                bounds.append((start, end))
                start += window - overlap
            }
            #expect(bounds.count >= 2)
            var merged: [Word] = []
            for (index, (from, to)) in bounds.enumerated() {
                let startMs = Int64(from) * 1000 / Int64(rate)
                let endMs = Int64(to) * 1000 / Int64(rate)
                let words = Swift.stride(from: (startMs / 1000) * 1000, to: endMs, by: 1000).filter { $0 >= startMs }
                    .map { w("w\($0 / 1000)", $0, $0 + 200) }
                merged = mergeFallback(merged, words, startMs, overlapMs, first: index == 0)
            }
            #expect(merged.map(\.text) == (0..<75).map { "w\($0)" })
            #expect(zip(merged, merged.dropFirst()).allSatisfy { $0.startMs <= $1.startMs })
        }
    }

    // ports: SeamMergeTest#alignmentPrefersMoreMatchesThenSmallerDistance
    @Test func alignmentPrefersMoreMatchesThenSmallerDistance() {
        let acc = [w("si", 9600, 9700), w("si", 9800, 9900)]
        let next = [w("si", 9790, 9890)]
        #expect(SeamMerge.align(acc, next, overlapStartMs: 9500, overlapEndMs: 10000, toleranceMs: SeamMerge.duplicateToleranceMs) ==
                [SeamMerge.Match(1, 0)])
        #expect(SeamMerge.midpointMs(w("x", 1, 2)) == 1)
        #expect(SeamMerge.midpointMs(w("x", 5, 5)) == 5)
    }

    // A forced cut at 11.0 s decoded with a second of the recording on each side: the overlap is 10.0 to 12.0 s.
    func splice(_ acc: [Word], _ next: [Word]) -> [Word] { SeamMerge.splice(acc, next, overlapStartMs: 10_000, overlapMs: 2_000) }
    func splicedOrigins(_ acc: [Word], _ next: [Word]) -> [String] {
        origins(SeamMerge.splice(tag(acc, "acc"), tag(next, "next"), overlapStartMs: 10_000, overlapMs: 2_000) { $0.word })
    }

    // ports: SeamMergeTest#aWordTheCutRunsThroughIsKeptOnceAndEachEdgeComesFromTheOtherDecode
    @Test func aWordTheCutRunsThroughIsKeptOnceAndEachEdgeComesFromTheOtherDecode() {
        let acc = [w("prima", 9_000, 9_400), w("la", 10_600, 10_750), w("batterica.", 10_780, 11_300), w("poi", 11_350, 11_600),
                   w("tronc", 11_800, 12_000)]
        let next = [w("ella", 10_050, 10_300), w("la", 10_620, 10_760), w("batterica.", 10_800, 11_310), w("poi", 11_360, 11_610),
                    w("troncato", 11_790, 12_300), w("dopo", 12_350, 12_600)]
        #expect(splice(acc, next).map(\.text) == ["prima", "la", "batterica.", "poi", "troncato", "dopo"])
        // Joined at the agreed word nearest the cut: the earlier decode up to it, the later one after it.
        let from = splicedOrigins(acc, next)
        #expect(from[2] == "acc2")
        #expect(from[3] == "next3")
    }

    // ports: SeamMergeTest#twoReadingsOfTheSameAudioAtACutKeepOne
    @Test func twoReadingsOfTheSameAudioAtACutKeepOne() {
        let got = splice([w("della", 10_400, 10_700), w("batterica.", 10_780, 11_300)],
                         [w("della", 10_410, 10_700), w("batteria", 10_790, 11_250), w("dopo", 11_400, 11_700)])
        #expect(got.map(\.text) == ["della", "batteria", "dopo"])
    }

    // ports: SeamMergeTest#aWordTimedOnOppositeSidesOfTheCutIsNeitherLostNorDoubled
    @Test func aWordTimedOnOppositeSidesOfTheCutIsNeitherLostNorDoubled() {
        // The same short word 240 ms apart: too far for a lone pair in the window merge, and with no time in common.
        for (early, late) in [(Int64(11_040), Int64(10_800)), (10_800, 11_040)] {
            let got = splice([w("prima", 9_000, 9_400), w("sì", early, early + 80)], [w("sì", late, late + 80), w("dopo", 12_100, 12_400)])
            #expect(got.map(\.text) == ["prima", "sì", "dopo"])
        }
    }

    // ports: SeamMergeTest#oneReadingOfASplitWordIsTakenWhole
    @Test func oneReadingOfASplitWordIsTakenWhole() {
        // One decode hears a word, the other two shorter ones: never half of each.
        let acc = [w("che", 10_300, 10_500), w("alimento", 10_800, 11_240)]
        let next = [w("che", 10_310, 10_500), w("a", 10_840, 10_920), w("lento", 10_920, 11_280), w("dopo", 11_500, 11_800)]
        #expect(splice(acc, next).map(\.text) == ["che", "a", "lento", "dopo"])
        // Without any agreed word the join is an instant outside every word: again one whole reading.
        let alone = splice([w("alimento", 10_800, 11_240)], [w("a", 10_840, 10_920), w("lento", 10_920, 11_280)]).map(\.text)
        #expect([["alimento"], ["a", "lento"]].contains(alone), "\(alone)")
    }

    // ports: SeamMergeTest#wordsOnlyOneDecodeFoundStayOnItsOwnSideOfTheJoin
    @Test func wordsOnlyOneDecodeFoundStayOnItsOwnSideOfTheJoin() {
        let acc = [w("prima", 10_200, 10_500), w("fantasma", 11_500, 11_700)]
        let next = [w("eco", 10_550, 10_700), w("dopo", 11_800, 12_100)]
        let got = splice(acc, next).map(\.text)
        #expect(got.first == "prima" && got.last == "dopo" && (2...3).contains(got.count), "\(got)")
        #expect(splice([w("solo", 10_200, 10_500)], []).map(\.text) == ["solo"])
    }

    // ports: SeamMergeTest#aRepeatedWordShiftedByMoreThanTheLoneToleranceIsStillOneWordAtACut
    @Test func aRepeatedWordShiftedByMoreThanTheLoneToleranceIsStillOneWordAtACut() {
        // Measured on the phone: copies of one word 220 ms apart, above the 200 ms the desktop accepts for a lone pair.
        let got = splice([w("di", 10_368, 10_448), w("cronometro.", 10_448, 10_928)], [w("Cronometro", 10_668, 11_228), w("che", 11_228, 11_388)])
        #expect(got.map { SeamMerge.normalize($0.text) } == ["di", "cronometro", "che"])
    }

    // ports: SeamMergeTest#aZeroLengthCopyAtTheJoinGivesWayToTheOtherDecodesCopyWithDuration
    @Test func aZeroLengthCopyAtTheJoinGivesWayToTheOtherDecodesCopyWithDuration() {
        // The earlier decode stamped "sì" in padding and it was clamped to the overlap end; the later one heard it whole.
        let clamped = w("sì", 12_000, 12_000)
        let whole = w("sì", 11_800, 12_320)
        let acc = [w("prima", 9_000, 9_400), clamped]
        let next = [whole, w("dopo", 12_400, 12_700)]
        #expect(splice(acc, next).map(\.text) == ["prima", "sì", "dopo"])
        #expect(splicedOrigins(acc, next)[1] == "next0")
        // The other way round the copy with duration is already the earlier decode's and stays.
        let kept = w("sì", 11_800, 12_320)
        let backAcc = [w("prima", 9_000, 9_400), kept]
        let backNext = [w("sì", 12_000, 12_000), w("dopo", 12_400, 12_700)]
        #expect(splicedOrigins(backAcc, backNext)[1] == "acc1")
        #expect(splice(backAcc, backNext).count == 3)
    }
}
