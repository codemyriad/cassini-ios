import CassiniCore
import Testing
@testable import CassiniNotebook

/// iOS only: every constant of the decode rules, pinned to Android's value, and the provenance strings verbatim. A
/// change here is a change from Android and belongs in docs/differences.md.
@Suite struct DecodeConstantsTests {
    @Test func everyDecodeConstantIsAndroidsValue() {
        #expect(SpeechWindows.maxSafeMs == 55_000)
        #expect(SpeechWindows.tailPadMinSeconds == 10)
        #expect(SpeechWindows.wholeSpanMs == 28_000)
        #expect(SpeechWindows.cutFromMs == 20_000)
        #expect(SpeechWindows.cutToMs == 25_000)
        #expect(SpeechWindows.cutContextMs == 1_000)
        #expect(SpeechWindows.quietFrameMs == 30)
        #expect(SpeechWindows.quietStepMs == 10)
        #expect(DecodePolicy.wholeSpans == DecodePolicy(windowMs: 10_000, overlapMs: 500, graceMs: 500, minTerminalMs: 5_000,
                                                        tailPaddingMs: 500, headPaddingMs: 0, contextMs: 0, preserveSpan: true,
                                                        syntheticPadding: true))
        #expect(DecodePolicy.parakeetV3Reference == DecodePolicy(tailPaddingMs: 0, contextMs: 30, preserveSpan: true, syntheticPadding: false))
        #expect(DecodeSession.retryContextMs == 500)

        #expect(WordGate.minPeak == 0.001)
        #expect(WordGate.minRms == 0.0001)
        #expect(WordGate.minActive == 0.0005)
        #expect(WordGate.minActiveMs == 5)
        #expect(WordGate.preMarginMs == 100)
        #expect(WordGate.postMarginMs == 200)
        #expect(WordGate.scanWindowMs == 10)
        #expect(WordGate.gapToleranceMs == 200)

        #expect(SeamMerge.duplicateToleranceMs == 400)
        #expect(SeamMerge.singletonToleranceMs == 200)
        #expect(SeamMerge.shiftConsistencyMs == 100)

        #expect(Limits.asrRate == 16_000)
        #expect(Limits.maxSamples == (36 * 3_600_000 + 1000) * 16)
        #expect(IncrementalTranscript.windowSamples == 448_000)
        #expect(IncrementalTranscript.overlapSamples == 32_000)

        #expect(SpeechFeed.sampleRate == 16_000)
        #expect(SpeechFeed.threshold == 0.18)
        #expect(SpeechFeed.minSilenceSeconds == 0.5)
        #expect(SpeechFeed.minSpeechSeconds == 0.10)
        #expect(SpeechFeed.maxSpeechSeconds == 25)
        #expect(SpeechFeed.window == 512)
        #expect(SpeechFeed.drainEvery == 80_000)

        #expect(DecodeCutting.wholeMaxMs == 60_000)
        // iOS's own checkpoint cadence.
        #expect(SpeechWindows.checkpointMs == 30_000)
        #expect(SpeechWindows.checkpointMinIntervalMs == 10_000)
    }

    @Test func theCuttingProvenanceIsAndroidsTextVerbatim() {
        #expect(DecodeCutting.allCases.map(\.rawValue) == ["WHOLE", "FIXED", "QUIET", "SPEECH"])
        #expect(DecodeCutting.whole.provenance == "whole recording")
        #expect(DecodeCutting.fixed.provenance == "15 s windows, 0.5 s overlap, seams aligned by word")
        #expect(DecodeCutting.quiet.provenance ==
                "pieces of 20 to 28 s cut at the quietest point with 1 s of recorded context, 0.5 s synthetic tail")
        #expect(DecodeCutting.speech.provenance ==
                "Silero VAD 0.18 speech spans, cut at the quietest point with 1 s of recorded context when longer than 28 s, 0.5 s synthetic tail")
        #expect(DecodeCutting.cutting(detectorReady: true) == .speech)
        #expect(DecodeCutting.cutting(detectorReady: false) == .quiet)
        #expect(DecodeCutting.incrementalProvenance(detectorReady: false) ==
                "Incremental container decoding: 28 s PCM windows, 2 s recorded overlap, seams aligned by word; " +
                "pieces of 20 to 28 s cut at the quietest point with 1 s of recorded context, 0.5 s synthetic tail")
    }

    /// Android's restore `require`s; iOS throws, because the state comes from a checkpoint on disk.
    @Test func aRestoredStateNoRunCouldSaveIsRefused() {
        let window = [Float](repeating: 0, count: 32_000)
        let recognize: (PcmAudio, Int64) throws -> Transcript = { _, _ in Transcript([]) }
        #expect(throws: Never.self) { try IncrementalTranscript(restored: IncrementalState(start: 0, end: 32_000, window: window, words: []), recognize: recognize) }
        for bad in [IncrementalState(start: -1, end: 0, window: window, words: []),
                    IncrementalState(start: 0, end: 32_001, window: window, words: []),
                    IncrementalState(start: 10, end: 5, window: window, words: []),
                    IncrementalState(start: 0, end: 0, window: [Float](repeating: 0, count: 448_001), words: [])] {
            #expect(throws: IncrementalState.Invalid.self) { try IncrementalTranscript(restored: bad, recognize: recognize) }
        }
    }

    /// A token list the words cannot be built from is TIMINGS, as on Android.
    @Test func malformedTokensAreATimingsFailure() {
        #expect(throws: JobFailure.timings) { try TokenWords.timedWordsFromTokens(["▁hello"], timestamps: [], durations: []) }
        #expect(throws: JobFailure.timings) { try TokenWords.timedWordsFromTokens(["▁hello"], timestamps: [.nan], durations: [0.1]) }
    }
}
