import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// Android's DiarizationTest: `Diarization.assign`, the word-to-speaker rule of the streaming job.
@Suite struct DiarizationTests {
    private func word(_ start: Int64, _ end: Int64) -> Word { Word("original", start, end, "w") }

    // ports: DiarizationTest#majorityOverlapWinsAndIdsFollowFirstAppearance
    @Test func majorityOverlapWinsAndIdsFollowFirstAppearance() {
        let turns = [DiarizerTurn(0, 1000, 7), DiarizerTurn(1000, 2000, 3)]
        let words = Diarization.assign([word(100, 400), word(900, 1300), word(1100, 1500)], turns: turns)
        #expect(words.map(\.speaker) == ["spk_1", "spk_2", "spk_2"])
    }

    // ports: DiarizationTest#aWordInAGapTakesTheNearestTurn
    @Test func aWordInAGapTakesTheNearestTurn() {
        let turns = [DiarizerTurn(0, 1000, 0), DiarizerTurn(2000, 3000, 1)]
        #expect(Diarization.assign([word(1100, 1200), word(1700, 1800)], turns: turns).map(\.speaker) == ["spk_1", "spk_2"])
    }

    // ports: DiarizationTest#noValidTurnsLeavesTheWordsAlone
    @Test func noValidTurnsLeavesTheWordsAlone() {
        let words = [word(0, 10)]
        #expect(Diarization.assign(words, turns: []) == words)
        #expect(Diarization.assign(words, turns: [DiarizerTurn(-1, 10, 0), DiarizerTurn(10, 0, 1), DiarizerTurn(0, 0, 1),
                                                   DiarizerTurn(0, 20, -1)]) == words)
    }

    // ports: DiarizationTest#disjointTurnsAreSummedPerSpeaker
    @Test func disjointTurnsAreSummedPerSpeaker() {
        let turns = [DiarizerTurn(0, 100, 0), DiarizerTurn(100, 200, 1), DiarizerTurn(200, 400, 0)]
        let words = [word(0, 50), word(110, 150), word(50, 300)]
        #expect(Diarization.assign(words, turns: turns).map(\.speaker) == ["spk_1", "spk_2", "spk_1"])
    }

    // ports: DiarizationTest#overlappingCopiesCannotDoubleCountTheSameSpeaker
    @Test func overlappingCopiesCannotDoubleCountTheSameSpeaker() {
        let turns = [DiarizerTurn(0, 400, 0), DiarizerTurn(200, 500, 0), DiarizerTurn(1000, 1600, 1), DiarizerTurn(1600, 1700, 1)]
        let words = [word(0, 10), word(1010, 1020), word(0, 1700)]
        #expect(Diarization.assign(words, turns: turns).map(\.speaker) == ["spk_1", "spk_2", "spk_2"])
    }

    // ports: DiarizationTest#equalOverlapsAndGapTiesAreIndependentOfNativeOrder
    @Test func equalOverlapsAndGapTiesAreIndependentOfNativeOrder() {
        let turns = [DiarizerTurn(0, 100, 8), DiarizerTurn(200, 300, 1)]
        let words = [word(0, 10), word(200, 210), word(50, 250), word(150, 150)]
        let result = Diarization.assign(words, turns: turns)
        #expect(result == Diarization.assign(words, turns: turns.reversed()))
        #expect(result.map(\.speaker) == ["spk_1", "spk_2", "spk_1", "spk_1"])
    }

    // ports: DiarizationTest#wordOrderAndTimingArePreservedIncludingOverlappingTurns
    @Test func wordOrderAndTimingArePreservedIncludingOverlappingTurns() {
        let words = [word(1000, 1200), word(0, 200), word(1200, 1200)]
        let result = Diarization.assign(words, turns: [DiarizerTurn(0, 400, 0), DiarizerTurn(900, 1400, 1)], prefix: "new_")
        #expect(result.map { Word("original", $0.startMs, $0.endMs, $0.text) } == words)
        #expect(result.map(\.speaker) == ["new_1", "new_2", "new_1"])
    }

    /// iOS: the streaming job's ids are the slot's, whatever order the slots first speak in.
    @Test func stableIdsAreTheSlots() {
        let turns = [DiarizerTurn(0, 1000, 4), DiarizerTurn(1000, 2000, 0)]
        #expect(Diarization.assign([word(0, 500), word(1200, 1500)], turns: turns, prefix: "P_", stableIds: true)
            .map(\.speaker) == ["P_5", "P_1"])
    }
}
