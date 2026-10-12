import Foundation
import Testing
import CassiniNotebook

struct PlaybackSkipTests {
    // ports: TranscriptSemanticsTest#theSliderIsPositionWithTenSecondSteps (the steps; the view's label and value are
    // checked by CassiniUITests)
    @Test func theSliderMovesInTenSecondSteps() {
        #expect(PlaybackSkip.interval == 10)
        #expect(PlaybackSkip.steps(duration: 1_430) == 142)
        #expect(PlaybackSkip.step(from: 704, forward: true, duration: 1_430) == 714)
        #expect(PlaybackSkip.step(from: 704, forward: false, duration: 1_430) == 694)
        #expect(PlaybackSkip.steps(duration: 5) == 0)
    }

    @Test func aSkipStaysInsideTheFile() {
        #expect(PlaybackSkip.target(from: 4, by: -10, duration: 60) == 0)
        #expect(PlaybackSkip.target(from: 55, by: 10, duration: 60) == 60)
        #expect(PlaybackSkip.step(from: 1_425, forward: true, duration: 1_430) == 1_430)
        #expect(PlaybackSkip.target(from: 3, by: 10, duration: 0) == 0)
    }
}
