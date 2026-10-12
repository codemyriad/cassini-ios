import Testing
import CassiniNotebook

@Suite struct TranscriptionProgressTests {
    // ports: TranscriptionProgressTest#stagesDoNotAdvanceOrResetCompletedAudio
    @Test func stagesDoNotAdvanceOrResetCompletedAudio() {
        var state = TranscriptionProgress(totalMs: 100_000)
        state.complete(done: 28_000, total: 100_000, words: 40, at: 10_000)
        for stage in TranscriptionStage.allCases {
            state.stage(stage, at: 11_000, startMs: 26_000, endMs: 54_000)
            let sample = state.snapshot(at: 12_000)
            #expect(sample.percent == 28)
            #expect(sample.doneMs == 28_000)
            #expect(sample.words == 40)
        }
    }

    // ports: TranscriptionProgressTest#briefReadingStagesDoNotFlashBetweenNativeCalls
    @Test func briefReadingStagesDoNotFlashBetweenResults() {
        var state = TranscriptionProgress(totalMs: 100_000)
        state.stage(.words, at: 1_000, startMs: 0, endMs: 28_000)
        #expect(state.snapshot(at: 1_500).stage == .words)
        state.stage(.reading, at: 1_600, endMs: 28_000)
        state.stage(.speakers, at: 1_650, startMs: 0, endMs: 28_000)
        #expect(state.snapshot(at: 1_700).stage == .words)
        #expect(state.snapshot(at: 2_100).stage == .speakers)
    }

    // ports: TranscriptionProgressTest#paceWaitsForWholeChunksAndIgnoresColdModelLoading
    @Test func paceWaitsForWholeResultsAndIgnoresColdModelLoading() {
        var state = TranscriptionProgress(totalMs: 200_000)
        state.complete(done: 28_000, total: 200_000, words: 20, at: 100_000)
        #expect(state.snapshot(at: 100_000).remainingMs == nil)
        state.complete(done: 54_000, total: 200_000, words: 40, at: 113_000)
        #expect(state.snapshot(at: 113_000).remainingMs == nil)
        state.complete(done: 80_000, total: 200_000, words: 60, at: 126_000)
        #expect(state.snapshot(at: 126_000).remainingMs == 60_000)
        state.stage(.words, at: 127_000, startMs: 78_000, endMs: 106_000)
        #expect(state.snapshot(at: 128_000).remainingMs == 58_000)
        state.complete(done: 106_000, total: 200_000, words: 80, at: 152_000)
        #expect(state.snapshot(at: 152_000).remainingMs == 56_400)
    }

    // ports: TranscriptionProgressTest#unknownDurationsRemainUnknownUntilMeasuredAndFinalizationIsExplicit
    @Test func unknownDurationsRemainUnknownUntilMeasuredAndFinalizationIsExplicit() {
        var state = TranscriptionProgress(totalMs: 0)
        #expect(state.snapshot(at: 1_000).percent == nil)
        state.total(54_000)
        #expect(state.snapshot(at: 1_000).percent == 0)
        state.complete(done: 54_000, total: 54_000, words: 50, at: 10_000)
        state.stage(.saving, at: 10_000)
        #expect(state.snapshot(at: 11_000).percent == 100)
        #expect(state.snapshot(at: 11_000).remainingMs == 0)
        #expect(state.snapshot(at: 11_000).stage == .saving)
    }

    // ports: TranscriptionProgressTest#estimatesAreRoundedWithoutPretendingToBePreciseToTheSecond
    @Test func estimatesAreRoundedWithoutPretendingToBePreciseToTheSecond() {
        #expect(TranscriptionProgress.roundedRemaining(330_001) == 360_000)
        #expect(TranscriptionProgress.roundedRemaining(81_000) == 90_000)
        #expect(TranscriptionProgress.roundedRemaining(21_000) == 25_000)
        #expect(TranscriptionProgress.roundedRemaining(0) == 0)
    }

    // ports: TranscriptionProgressTest#estimateRangesWidenWhenProcessingSlowsAndResumeIgnoresReloadTime
    @Test func estimateRangesWidenWhenProcessingSlowsAndResumeIgnoresReloadTime() throws {
        var state = TranscriptionProgress(totalMs: 400_000)
        state.complete(done: 28_000, total: 400_000, words: 30, at: 50_000)
        state.complete(done: 54_000, total: 400_000, words: 60, at: 63_000)
        state.complete(done: 80_000, total: 400_000, words: 90, at: 76_000)
        let steady = state.snapshot(at: 76_000)
        let steadyLow = try #require(steady.remainingLowMs), steadyHigh = try #require(steady.remainingHighMs)
        #expect(steadyLow < steady.remainingMs!)
        #expect(steadyHigh > steady.remainingMs!)
        state.complete(done: 106_000, total: 400_000, words: 120, at: 128_000)
        let slow = state.snapshot(at: 128_000)
        #expect(slow.remainingHighMs! - slow.remainingLowMs! > steadyHigh - steadyLow)
        var resumed = TranscriptionProgress(totalMs: 400_000)
        resumed.restore(doneMs: 106_000, totalMs: 400_000, words: 120, elapsedMs: 128_000)
        resumed.complete(done: 132_000, total: 400_000, words: 150, at: 228_000)
        resumed.complete(done: 158_000, total: 400_000, words: 180, at: 241_000)
        resumed.complete(done: 184_000, total: 400_000, words: 210, at: 254_000)
        #expect(resumed.snapshot(at: 254_000).remainingMs == 108_000)
    }
}
