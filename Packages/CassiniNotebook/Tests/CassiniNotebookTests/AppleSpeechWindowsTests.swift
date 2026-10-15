import Testing
import CassiniNotebook

/// iOS only: the block reading of the Apple Speech fallback, and the checkpoint cadence both recognizers share.
/// Android has no fallback recognizer.
@Suite struct AppleSpeechWindowsTests {
    @Test func blocksAreOneSecondAtTheFilesRate() {
        #expect(AppleSpeechWindows.samples(AppleSpeechWindows.blockMs, sampleRate: 16_000) == 16_000)
        #expect(AppleSpeechWindows.samples(AppleSpeechWindows.blockMs, sampleRate: 44_100) == 44_100)
    }

    @Test func aResumedRunStartsOneSecondBeforeTheCheckpoint() {
        #expect(AppleSpeechWindows.resumeStartMs(doneMs: 54_000) == 53_000)
        #expect(AppleSpeechWindows.resumeStartMs(doneMs: 400) == 0)
        #expect(AppleSpeechWindows.frame(atMs: 53_000, sampleRate: 44_100) == 2_337_300)
        #expect(AppleSpeechWindows.frame(atMs: 1, sampleRate: 44_100) == 45)
    }

    @Test func checkpointsAreDueEvery30SecondsOfAudioButNotMoreOftenThanEvery10Seconds() {
        #expect(!SpeechWindows.checkpointDue(doneMs: 29_999, savedMs: 0, nowMs: 100_000, savedAt: nil))
        #expect(SpeechWindows.checkpointDue(doneMs: 30_000, savedMs: 0, nowMs: 100, savedAt: nil))
        #expect(!SpeechWindows.checkpointDue(doneMs: 70_000, savedMs: 30_000, nowMs: 9_000, savedAt: 0))
        #expect(SpeechWindows.checkpointDue(doneMs: 70_000, savedMs: 30_000, nowMs: 10_000, savedAt: 0))
    }
}
