import Testing
@testable import CassiniNotebook

struct ExportClockTests {
    private let underAnHour: Int64 = 23 * 60_000 + 50_000

    // ports: ExportClockTest#shortFormBelowOneHour
    @Test func shortFormBelowOneHour() {
        #expect(ExportClock.clock(0, durationMs: underAnHour) == "00:00")
        #expect(ExportClock.clock(161_999, durationMs: underAnHour) == "02:41")
        #expect(ExportClock.clock(3_599_999, durationMs: 3_599_999) == "59:59")
    }

    // ports: ExportClockTest#longFormFromOneHourOfDuration
    @Test func longFormFromOneHourOfDuration() {
        #expect(ExportClock.clock(0, durationMs: 3_600_000) == "0:00:00")
        #expect(ExportClock.clock(65_000, durationMs: 3_600_000) == "0:01:05")
        #expect(ExportClock.clock(4_325_999, durationMs: 4_400_000) == "1:12:05")
        #expect(ExportClock.clock(43_200_000, durationMs: 43_200_000) == "12:00:00")
    }

    // ports: ExportClockTest#aTimeBeyondTheDurationStillReadsAsHours
    @Test func aTimeBeyondTheDurationStillReadsAsHours() {
        #expect(ExportClock.clock(3_600_000, durationMs: underAnHour) == "1:00:00")
    }

    // ports: ExportClockTest#negativeTimesAreZero
    @Test func negativeTimesAreZero() {
        #expect(ExportClock.clock(-5, durationMs: underAnHour) == "00:00")
        #expect(ExportClock.srt(-5) == "00:00:00,000")
    }

    // ports: ExportClockTest#subtitleStamps
    @Test func subtitleStamps() {
        #expect(ExportClock.srt(0) == "00:00:00,000")
        #expect(ExportClock.srt(3_723_456) == "01:02:03,456")
        #expect(ExportClock.vtt(3_723_456) == "01:02:03.456")
        #expect(ExportClock.vtt(59_999) == "00:00:59.999")
        #expect(ExportClock.srt(360_000_007) == "100:00:00,007")
    }
}
