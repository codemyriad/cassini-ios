import Testing
import CassiniNotebook

@Suite struct TimeLeftTests {
    private let second: Int64 = 1_000, minute: Int64 = 60_000

    // ports: FormatTest#progress (the minute spans; the app words them)
    @Test func spansFloorTheLowEndAndRoundUpTheHighEnd() {
        #expect(TimeLeft.range(lowMs: 6 * minute, highMs: 9 * minute).minutes == 6...9)
        #expect(TimeLeft.range(lowMs: 6 * minute + 50 * second, highMs: 8 * minute + 10 * second).minutes == 6...9)
        #expect(TimeLeft.range(lowMs: 6 * minute, highMs: 6 * minute).minutes == 6...6)
        #expect(TimeLeft.range(lowMs: 10 * second, highMs: 50 * second).minutes == nil)
        #expect(TimeLeft.range(lowMs: 10 * second, highMs: 2 * minute).minutes == 1...2)
        #expect(TimeLeft.range(lowMs: 70 * minute, highMs: 90 * minute).minutes == 70...90)
        #expect(TimeLeft.calculating.minutes == nil)
        #expect(TimeLeft.finishing.minutes == nil)
    }
}
