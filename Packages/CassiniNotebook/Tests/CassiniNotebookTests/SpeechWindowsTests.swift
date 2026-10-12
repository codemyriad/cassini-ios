import Testing
import CassiniNotebook

/// Android's window, context and padding arithmetic belongs to Parakeet's windows and is not ported (docs/differences/WP5.md).
@Suite struct SpeechWindowsTests {
    @Test func blocksAreOneSecondAtTheFilesRate() {
        #expect(SpeechWindows.samples(SpeechWindows.blockMs, sampleRate: 16_000) == 16_000)
        #expect(SpeechWindows.samples(SpeechWindows.blockMs, sampleRate: 44_100) == 44_100)
    }

    @Test func aResumedRunStartsOneSecondBeforeTheCheckpoint() {
        #expect(SpeechWindows.resumeStartMs(doneMs: 54_000) == 53_000)
        #expect(SpeechWindows.resumeStartMs(doneMs: 400) == 0)
        #expect(SpeechWindows.frame(atMs: 53_000, sampleRate: 44_100) == 2_337_300)
        #expect(SpeechWindows.frame(atMs: 1, sampleRate: 44_100) == 45)
    }

    @Test func checkpointsAreDueEvery30SecondsOfAudioButNotMoreOftenThanEvery10Seconds() {
        #expect(!SpeechWindows.checkpointDue(doneMs: 29_999, savedMs: 0, nowMs: 100_000, savedAt: nil))
        #expect(SpeechWindows.checkpointDue(doneMs: 30_000, savedMs: 0, nowMs: 100, savedAt: nil))
        #expect(!SpeechWindows.checkpointDue(doneMs: 70_000, savedMs: 30_000, nowMs: 9_000, savedAt: 0))
        #expect(SpeechWindows.checkpointDue(doneMs: 70_000, savedMs: 30_000, nowMs: 10_000, savedAt: 0))
    }
}
