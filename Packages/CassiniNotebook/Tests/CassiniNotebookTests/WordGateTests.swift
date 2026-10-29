import CassiniCore
import Testing
@testable import CassiniNotebook

/// Android's WordGateTest, one to one, at 16 and 48 kHz. The token cases run `TokenWords`, as Android's do. The gate
/// measures AC level (D26.1), so where Android's fixture is one steady level over the whole recording, which is all DC,
/// the level alternates in sign here (`steady`): the same magnitude, with no DC for the gate to take off.
@Suite struct WordGateTests {
    let rates = [16_000, 48_000]

    func timed(_ text: String, _ startMs: Int64, _ endMs: Int64, _ capMs: Int64 = 0) -> DecodedWord {
        DecodedWord(Word("spk_1", startMs, endMs, text), capMs: capMs)
    }
    func word(_ text: String, _ startMs: Int64, _ endMs: Int64) -> Word { Word("spk_1", startMs, endMs, text) }

    /// `totalMs` of digital silence with steady ±0.05 energy, far above the -66 dBFS floor, over each [from, to) span.
    func activeAudio(_ sampleRate: Int, _ totalMs: Int64, _ spans: (Int64, Int64)...) -> [Float] {
        activeAudio(sampleRate, totalMs, spans: spans)
    }

    func activeAudio(_ sampleRate: Int, _ totalMs: Int64, spans: [(Int64, Int64)]) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(totalMs * Int64(sampleRate) / 1000))
        for (from, to) in spans {
            var i = from * Int64(sampleRate) / 1000
            while i < to * Int64(sampleRate) / 1000 && i < Int64(samples.count) {
                samples[Int(i)] = i % 2 == 0 ? 0.05 : -0.05
                i += 1
            }
        }
        return samples
    }

    func fill(_ samples: inout [Float], _ sampleRate: Int, _ fromMs: Int, _ toMs: Int, _ value: Float) {
        for i in (fromMs * sampleRate / 1000)..<(toMs * sampleRate / 1000) { samples[i] = value }
    }

    /// `count` samples of `value` alternating in sign.
    func steady(_ value: Float, count: Int) -> [Float] { (0..<count).map { $0 % 2 == 0 ? value : -value } }

    // ports: WordGateTest#clampKeepsBoundaryTokensWithinDecoderPadding
    @Test func clampKeepsBoundaryTokensWithinDecoderPadding() {
        let words = [
            timed("within", 13000, 14000), timed("straddles", 14000, 14950), timed("boundary", 14455, 14800),
            timed("inside-padding", 14800, 14950), timed("padding-limit", 14955, 15000),
            timed("beyond-padding", 14956, 15000), timed("reversed-padding", 14800, 14799),
        ]
        let got = WordGate.clampWordsToTimelineEnd(words, endMs: 14455, paddedTailMs: 500).map(\.word)
        #expect(got == [
            word("within", 13000, 14000), word("straddles", 14000, 14455), word("boundary", 14455, 14455),
            word("inside-padding", 14455, 14455), word("padding-limit", 14455, 14455),
        ])
    }

    // ports: WordGateTest#clampWithoutPaddingKeepsOnlyTheExactBoundary
    @Test func clampWithoutPaddingKeepsOnlyTheExactBoundary() {
        let got = WordGate.clampWordsToTimelineEnd([timed("boundary", 1000, 1100), timed("past-boundary", 1001, 1100)], endMs: 1000, paddedTailMs: 0)
        #expect(got.map(\.word) == [word("boundary", 1000, 1000)])
    }

    // ports: WordGateTest#clampSaturatesAnOverflowingPaddedEnd
    @Test func clampSaturatesAnOverflowingPaddedEnd() {
        let got = WordGate.clampWordsToTimelineEnd([timed("far", .max - 1, .max - 1)], endMs: 1000, paddedTailMs: .max)
        #expect(got.map(\.word) == [word("far", 1000, 1000)])
    }

    /// Synthetic padding cannot justify reaching into it: the cap is clipped to the real PCM end too.
    // ports: WordGateTest#clampClipsTheExtentCap
    @Test func clampClipsTheExtentCap() {
        let got = WordGate.clampWordsToTimelineEnd([
            timed("straddles", 900, 1100, 1400), timed("boundary", 1000, 1000, 1400), timed("inside", 800, 900, 950),
        ], endMs: 1000, paddedTailMs: 32)
        #expect(got.map(\.capMs) == [1000, 1000, 950])
    }

    // ports: WordGateTest#offsetRemovesHeadPaddingThenMovesWordsAndCapsOntoTheRecordingClock
    @Test func offsetRemovesHeadPaddingThenMovesWordsAndCapsOntoTheRecordingClock() {
        let got = WordGate.offsetDecoderWords([timed("a", 100, 400, 600), timed("pad", 0, 20, 30)], offsetMs: 5000, headPaddingMs: 50)
        #expect(got == [timed("a", 5050, 5350, 5550), timed("pad", 5000, 5000, 5000)])
        #expect(WordGate.offsetDecoderWords([timed("a", 100, 400, 600)], offsetMs: 5000, headPaddingMs: 0) == [timed("a", 5100, 5400, 5600)])
    }

    // ports: WordGateTest#overlappingSpeechIsStrictAtBothEdges
    @Test func overlappingSpeechIsStrictAtBothEdges() {
        let words = [timed("before", 500, 1000), timed("into", 900, 1100), timed("inside", 1200, 1300),
                     timed("at-end", 2000, 2000), timed("out", 2100, 2200)]
        #expect(WordGate.wordsOverlappingSpeech(words, startMs: 1000, endMs: 2000).map(\.word.text) == ["into", "inside"])
    }

    // ports: WordGateTest#gateRejectsSilenceAndClicksButKeepsQuietInterjections
    @Test func gateRejectsSilenceAndClicksButKeepsQuietInterjections() {
        for rate in rates {
            var samples = [Float](repeating: 0, count: 3 * rate)
            // A quiet 30 ms utterance 50 ms before its timestamp, exactly at the -60 dBFS peak floor.
            fill(&samples, rate, 950, 980, WordGate.minPeak)
            // Negative PCM counts by magnitude.
            fill(&samples, rate, 1500, 1530, -0.01)
            // A lone full-scale click passes peak and RMS but not the active-duration floor.
            samples[1950 * rate / 1000] = 1
            let words = [timed("quiet", 1000, 1100), timed("negative", 1500, 1600), timed("click", 2000, 2100),
                         timed("silence", 2400, 2500), timed("outside", 4000, 4100)]
            #expect(WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: words) ==
                    [word("quiet", 1000, 1100), word("negative", 1500, 1600)], "\(rate) Hz")
        }
    }

    // ports: WordGateTest#gateAllowsTheMeasuredDecoderLead
    @Test func gateAllowsTheMeasuredDecoderLead() {
        for rate in rates {
            #expect(WordGate.preMarginMs == 100)
            #expect(WordGate.postMarginMs == 200)
            // Parakeet has placed a word up to 180 ms before its own PCM.
            var samples = [Float](repeating: 0, count: 2 * rate)
            fill(&samples, rate, 780, 830, 0.01)
            #expect(WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: [timed("delayed-energy", 500, 600)]) ==
                    [word("delayed-energy", 500, 600)], "\(rate) Hz")
        }
    }

    // ports: WordGateTest#gateRejectsMalformedTimestamps
    @Test func gateRejectsMalformedTimestamps() {
        for rate in rates {
            let samples = steady(0.1, count: rate)
            let words = [timed("max", .max, .max), timed("min", .min, .min), timed("reversed", 800, 700)]
            #expect(WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: words).isEmpty)
        }
    }

    // ports: WordGateTest#finalizeClampsBeforeTheGate
    @Test func finalizeClampsBeforeTheGate() {
        for rate in rates {
            let samples = steady(0.01, count: rate)
            let words = [timed("straddles", 900, 1100), timed("boundary", 1000, 1200),
                         timed("inside-vad-padding", 1032, 1100), timed("beyond-vad-padding", 1033, 1100)]
            let want = [word("straddles", 900, 1000), word("boundary", 1000, 1000), word("inside-vad-padding", 1000, 1000)]
            #expect(WordGate.finalizeTranscriptWords(samples, sampleRate: rate, words: words, audioEndMs: 1000, paddedTailMs: 32) == want, "\(rate) Hz")
            #expect(WordGate.finalizeTranscriptWords(PcmAudio(samples, sampleRate: rate), words: words, paddedTailMs: 32) == want, "\(rate) Hz")
        }
    }

    /// The duration head saturates at 320 ms; the gate follows the speaker's audio to its real end, and not past it.
    // ports: WordGateTest#gateFollowsAudioPastTheLastSpeechToken
    @Test func gateFollowsAudioPastTheLastSpeechToken() {
        for rate in rates {
            let samples = activeAudio(rate, 3000, (1000, 1600))
            #expect(WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: [timed("Okay.", 1000, 1150, 2500)]) ==
                    [word("Okay.", 1000, 1600)], "\(rate) Hz")
        }
    }

    // ports: WordGateTest#gateStopsWhereTheAudioStops
    @Test func gateStopsWhereTheAudioStops() {
        for rate in rates {
            let samples = activeAudio(rate, 3000, (1000, 1150), (2400, 2600))
            #expect(WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: [timed("Yeah.", 1000, 1150, 2500)]) ==
                    [word("Yeah.", 1000, 1150)], "\(rate) Hz")
        }
    }

    // ports: WordGateTest#gateBridgesAClosureButNotAPause
    @Test func gateBridgesAClosureButNotAPause() {
        for rate in rates {
            #expect(WordGate.gapToleranceMs == 200)
            let spoken = [timed("Okay.", 1000, 1150, 2500)]
            // "o-", "-kay" after a 60 ms closure, then the next utterance where the "." is stamped.
            let closure = activeAudio(rate, 3000, (1000, 1150), (1210, 1450), (2400, 2600))
            #expect(WordGate.filterWordsByEnergy(closure, sampleRate: rate, words: spoken).first?.endMs == 1450, "\(rate) Hz")
            let tolerance = WordGate.gapToleranceMs
            let justUnder = activeAudio(rate, 3000, (1000, 1150), (1150 + tolerance - 10, 1600))
            #expect(WordGate.filterWordsByEnergy(justUnder, sampleRate: rate, words: spoken).first?.endMs == 1600, "\(rate) Hz")
            let justOver = activeAudio(rate, 3000, (1000, 1150), (1150 + tolerance + 10, 1600))
            #expect(WordGate.filterWordsByEnergy(justOver, sampleRate: rate, words: spoken).first?.endMs == 1150, "\(rate) Hz")
        }
    }

    // ports: WordGateTest#gateNeverExceedsTheCapAndNeverExtendsAnUncappedWord
    @Test func gateNeverExceedsTheCapAndNeverExtendsAnUncappedWord() {
        for rate in rates {
            let samples = activeAudio(rate, 4000, (1000, 3500))
            let got = WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: [timed("capped", 1000, 1150, 1400), timed("uncapped", 2000, 2150)])
            #expect(got.map(\.endMs) == [1400, 2150], "\(rate) Hz")
        }
    }

    // ports: WordGateTest#gateStillDropsSilentWordsWithACap
    @Test func gateStillDropsSilentWordsWithACap() {
        for rate in rates {
            let samples = activeAudio(rate, 4000, (3000, 3500))
            #expect(WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: [timed("hallucinated.", 1000, 1150, 3400)]).isEmpty)
        }
    }

    /// Seam test: the token stage decides whether a cap exists and the gate how much of it to spend.
    // ports: WordGateTest#punctuationOnlyWordIsNotExtendedOverTheNextUtterance
    @Test func punctuationOnlyWordIsNotExtendedOverTheNextUtterance() throws {
        for rate in rates {
            // "Okay" 1000-1300 ms, a pause, then "Marco" 1600-2400 ms; the mark is stamped 100 ms before it.
            let samples = activeAudio(rate, 3500, (1000, 1300), (1600, 2400))
            let words = try TokenWords.timedWordsFromTokens(["▁Okay", "▁…", "▁Marco", "."],
                                                            timestamps: [1, 1.5, 1.6, 2.6], durations: [0.3, 0.32, 0.32, 0])
            #expect(words[1].word.text == "…")
            #expect(words[1].extentCapMs == words[1].word.endMs)
            let got = WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: words)
            #expect(got.count == 3, "\(rate) Hz: the mark must clear the gate for this to test anything")
            guard got.count == 3 else { continue }
            #expect(got[1] == word("…", 1500, 1500))
            // The control: the spoken word in the same call is extended from 1920 ms to where its audio ends.
            #expect(got[2] == word("Marco.", 1600, 2400))
        }
    }

    /// A start never moves, an end never goes backwards or collapses, and an end never passes the cap.
    // ports: WordGateTest#extensionPropertiesHoldForEveryLayout
    @Test func extensionPropertiesHoldForEveryLayout() {
        for rate in [16_000, 44_100, 48_000] {
            let layouts: [[(Int64, Int64)]] = [
                [(1000, 1150)], [(1000, 1600)], [(1000, 1150), (1210, 1450)],
                [(1000, 1150), (1400, 1450), (1900, 2600)], [(900, 2999)],
            ]
            for (layout, spans) in layouts.enumerated() {
                let samples = activeAudio(rate, 3000, spans: spans)
                for endMs: Int64 in [1050, 1150, 1320, 1470] {
                    for capMs: Int64 in [0, 1000, 1155, 1600, 2500, 9000] {
                        let input = timed("w", 1000, endMs, capMs)
                        let out = WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: [input])
                        guard out.count == 1, let first = out.first else { continue }
                        let comment: Comment = "\(rate) Hz layout \(layout) end=\(endMs) cap=\(capMs) -> \(first.startMs)-\(first.endMs)"
                        #expect(first.startMs == input.word.startMs, comment)
                        #expect(first.endMs >= input.word.endMs, comment)
                        #expect(first.endMs <= input.extentCapMs, comment)
                        #expect(first.endMs > first.startMs, comment)
                    }
                }
            }
        }
    }

    // ports: WordGateTest#gateWithoutAudioPassesWordsThrough
    @Test func gateWithoutAudioPassesWordsThrough() {
        #expect(WordGate.filterWordsByEnergy([], sampleRate: 48_000, words: [timed("a", 0, 10, 50)]) == [word("a", 0, 10)])
    }

    /// The punctuation-inclusive end travels as a cap only; the end still stops at the last speech-bearing piece.
    // ports: WordGateTest#tokensCarryThePunctuationEndAsACapOnly
    @Test func tokensCarryThePunctuationEndAsACapOnly() throws {
        let got = try TokenWords.timedWordsFromTokens(["▁Right", "?", "!", "▁U", ".", "S", ".", "▁then", ".", "▁Next"],
                                                      timestamps: [1, 3.5, 3.52, 3.6, 3.72, 3.8, 3.96, 4.2, 9, 9.1],
                                                      durations: [0.4, 0.08, 0.08, 0.12, 0.08, 0.16, 0.08, 0.8, 0.08, 0.2])
        #expect(got.map(\.word.text) == ["Right?!", "U.S.", "then.", "Next"])
        #expect(got.map(\.word.endMs) == [1400, 3960, 5000, 9300])
        #expect(got.map(\.extentCapMs) == [3600, 4040, 9080, 9300])
        #expect(try TokenWords.fromTokens(["▁Right", "?"], timestamps: [1, 3.5], durations: [0.4, 0.08]).words ==
                (try TokenWords.timedWordsFromTokens(["▁Right", "?"], timestamps: [1, 3.5], durations: [0.4, 0.08])).map(\.word))
    }

    // ports: WordGateTest#tokensDoNotInheritThePreviousCap
    @Test func tokensDoNotInheritThePreviousCap() throws {
        // The zero-duration word shares the mark's timestamp, so a leaked cap would sit 80 ms above its end.
        let got = try TokenWords.timedWordsFromTokens(["▁Done", ".", "▁mm"], timestamps: [1, 9, 9], durations: [0.56, 0.08, 0])
        #expect(got[0].extentCapMs == 9080)
        #expect(got[1].extentCapMs == got[1].word.endMs)
        #expect(got[1].capMs == 9000)
    }

    /// The real failing microphone's offset, -2060 of 32768 (D26.1).
    static let offset: Float = -2060.0 / 32768

    func offset(_ samples: [Float], by dc: Float = offset) -> [Float] { samples.map { $0 + dc } }

    /// A DC offset on its own is silence: no word in it passes, and none reaches into it. Measured raw, every sample
    /// would be active and both words would pass, the capped one extended to its cap.
    @Test func aDCOffsetIsSilence() {
        for rate in rates {
            let samples = offset([Float](repeating: 0, count: 3 * rate))
            #expect(WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: [timed("hallucinated", 1000, 1150),
                                                                                   timed("capped.", 2000, 2100, 2800)]).isEmpty,
                    "\(rate) Hz")
        }
    }

    /// Speech over an offset is gated and extended as it is without one.
    @Test func speechOverADCOffsetIsGatedAsWithoutIt() {
        for rate in rates {
            let words = [timed("Okay.", 1000, 1150, 2500), timed("silent", 2700, 2800), timed("capped", 3000, 3150, 3400)]
            let clean = activeAudio(rate, 4000, (1000, 1150), (1210, 1450), (2400, 2600), (3000, 3500))
            let want = [word("Okay.", 1000, 1450), word("capped", 3000, 3400)]
            #expect(WordGate.filterWordsByEnergy(clean, sampleRate: rate, words: words) == want, "\(rate) Hz")
            for dc: Float in [Self.offset, 4000.0 / 32768] {
                #expect(WordGate.filterWordsByEnergy(offset(clean, by: dc), sampleRate: rate, words: words) == want, "\(rate) Hz, \(dc)")
            }
        }
    }

    /// The DC comes from at least `dcContextMs` around the word, so a click cannot move it: a lone tap after a capped
    /// word does not stretch the word over it (a 10 ms window's own mean would make the whole window active).
    @Test func aClickAfterAWordDoesNotExtendIt() {
        for rate in rates {
            #expect(WordGate.dcContextMs == 1000)
            #expect(WordGate.minDC == WordGate.minActive / 2)
            var samples = activeAudio(rate, 3000, (1000, 1150))
            samples[1300 * rate / 1000] = 0.3
            #expect(WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: [timed("Okay.", 1000, 1150, 2000)]) ==
                    [word("Okay.", 1000, 1150)], "\(rate) Hz")
            #expect(WordGate.wordEndOverContinuingAudio(samples, sampleRate: rate, timed: timed("Okay.", 1000, 1150, 2000),
                                                        audioEndMs: 3000) == 1150, "\(rate) Hz")
        }
    }

    /// A few full-scale samples stay a click, also in the short window at the end of the recording.
    @Test func aFewClickSamplesAreNotAWord() {
        for rate in rates {
            var samples = [Float](repeating: 0, count: 3 * rate)
            for i in 0..<4 { samples[1950 * rate / 1000 + i] = 1 }
            samples[2950 * rate / 1000] = 1
            let words = [timed("click", 2000, 2100), timed("end", 3000, 3000)]
            #expect(WordGate.filterWordsByEnergy(samples, sampleRate: rate, words: words).isEmpty, "\(rate) Hz")
        }
    }
}
