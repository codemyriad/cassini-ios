import Testing
import CassiniNotebook

/// Android's ProcessingSpeedTest.
@Suite struct ProcessingSpeedTests {
    // ports: ProcessingSpeedTest#realtimeSpeedIsAudioOverElapsedTime
    @Test func realtimeSpeedIsAudioOverElapsedTime() {
        #expect(ProcessingSpeed.realtime(audioMs: 60_000, elapsedMs: 30_000) == 2.0)
        #expect(ProcessingSpeed.realtime(audioMs: 30_000, elapsedMs: 60_000) == 0.5)
        #expect(ProcessingSpeed.realtime(audioMs: 60_000, elapsedMs: 0) == nil)
        #expect(ProcessingSpeed.realtime(audioMs: 0, elapsedMs: 30_000) == nil)
    }
}
