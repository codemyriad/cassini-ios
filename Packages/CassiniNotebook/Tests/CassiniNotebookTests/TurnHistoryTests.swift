import Foundation
import Testing
@testable import CassiniNotebook

/// Android's TurnHistoryTest: the streaming diarizer's turns on the recording clock, window after window.
@Suite struct TurnHistoryTests {
    typealias T = DiarizerTurn

    // ports: TurnHistoryTest#theFirstWindowIsKeptOnTheRecordingClock
    @Test func theFirstWindowIsKeptOnTheRecordingClock() {
        var history = TurnHistory()
        history.add([T(500, 9000, 0), T(9000, 27000, 1)], startMs: 0)
        #expect(history.turns == [T(500, 9000, 0), T(9000, 27000, 1)])
    }

    // ports: TurnHistoryTest#aLaterWindowReplacesTurnsFromOneSecondIntoIt
    @Test func aLaterWindowReplacesTurnsFromOneSecondIntoIt() {
        var history = TurnHistory([T(0, 10_000, 0), T(20_000, 28_000, 1), T(27_500, 28_000, 0)])
        // The window starts at 26 s; its turns are relative to that start.
        history.add([T(0, 5000, 1), T(5000, 9000, 0)], startMs: 26_000)
        #expect(history.turns == [T(0, 10_000, 0), T(20_000, 27_000, 1), T(27_000, 31_000, 1), T(31_000, 35_000, 0)])
    }

    // ports: TurnHistoryTest#turnsThatEndBeforeTheCutAreDropped
    @Test func turnsThatEndBeforeTheCutAreDropped() {
        var history = TurnHistory()
        history.add([T(0, 800, 0), T(800, 3000, 1)], startMs: 26_000)
        #expect(history.turns == [T(27_000, 29_000, 1)])
    }
}
