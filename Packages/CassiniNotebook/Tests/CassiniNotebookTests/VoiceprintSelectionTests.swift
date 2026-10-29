import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// Android's VoiceprintSelectionTest: which clean stretches of each speaker's speech the CAM++ print is made from
/// (`Voiceprints.select`), and how prints are normalised and compared.
@Suite struct VoiceprintSelectionTests {
    private let rate = 16_000
    private func samples(_ ms: Int64) -> Int { Int(ms * Int64(rate) / 1000) }
    private func ms(_ window: PrintWindow) -> [Int64] {
        [Int64(window.startSample) * 1000 / Int64(rate), Int64(window.endSample) * 1000 / Int64(rate)]
    }
    private func select(_ turns: [DiarizerTurn], _ words: [Word], totalMs: Int64 = 600_000) -> [String: [PrintWindow]] {
        Dictionary(uniqueKeysWithValues: Voiceprints.select(turns: turns, words: words, sampleRate: rate,
                                                            totalSamples: samples(totalMs)).map { ($0.speaker, $0.windows) })
    }

    // ports: VoiceprintSelectionTest#edgesAreTrimmedAndConsecutiveWordsFormOneRun
    @Test func edgesAreTrimmedAndConsecutiveWordsFormOneRun() {
        let words = [Word("spk_1", 1000, 3000, "a"), Word("spk_1", 3100, 6000, "b")]
        let windows = select([DiarizerTurn(0, 7000, 0)], words)
        #expect(windows["spk_1"]?.map(ms) == [[1200, 5800]])
    }

    // ports: VoiceprintSelectionTest#anotherSpeakersTurnIsCutOut
    @Test func anotherSpeakersTurnIsCutOut() {
        let words = [Word("spk_1", 0, 10_000, "a"), Word("spk_2", 20_000, 30_000, "b")]
        let turns = [DiarizerTurn(0, 10_000, 0), DiarizerTurn(4000, 5000, 1), DiarizerTurn(20_000, 30_000, 1)]
        #expect(select(turns, words)["spk_1"]?.map(ms) == [[200, 3800], [5200, 9800]])
        #expect(select(turns, words)["spk_2"]?.map(ms) == [[20_200, 29_800]])
    }

    // ports: VoiceprintSelectionTest#shortSegmentsAndQuietSpeakersAreDropped
    @Test func shortSegmentsAndQuietSpeakersAreDropped() {
        let words = [Word("spk_1", 0, 1800, "a"), Word("spk_2", 2000, 8000, "b"), Word("spk_1", 9000, 12_000, "c")]
        let turns = [DiarizerTurn(0, 1800, 0), DiarizerTurn(2000, 8000, 1), DiarizerTurn(9000, 12_000, 0)]
        let windows = select(turns, words)
        // spk_1 keeps only 2.6 s, under the minimum; its 1.4 s first run is too short anyway.
        #expect(windows["spk_1"] == nil)
        #expect(windows["spk_2"]?.map(ms) == [[2200, 7800]])
    }

    // ports: VoiceprintSelectionTest#longRunsAreSplitIntoBoundedWindows
    @Test func longRunsAreSplitIntoBoundedWindows() throws {
        let windows = try #require(select([DiarizerTurn(0, 30_000, 0)], [Word("spk_1", 0, 30_000, "a")])["spk_1"])
        #expect(windows.count == 3)
        #expect(windows.allSatisfy { $0.endSample - $0.startSample <= samples(Voiceprints.maxWindowMs) })
        #expect(windows.first?.startSample == samples(200))
        #expect(windows.last?.endSample == samples(29_800))
    }

    // ports: VoiceprintSelectionTest#speechIsCappedAndDrawnFromEachThird
    @Test func speechIsCappedAndDrawnFromEachThird() throws {
        // Ten 9 s runs at the start, two short ones in the middle and at the end.
        let runs: [(Int64, Int64)] = (0..<10).map { (1000 + Int64($0) * 10_000, 10_000 + Int64($0) * 10_000) }
            + [(300_000, 305_000), (550_000, 555_000)]
        let words = runs.flatMap { start, end in [Word("spk_1", start, end, "x"), Word("spk_2", end + 100, end + 200, "y")] }
        let turns = words.map { DiarizerTurn($0.startMs, $0.endMs, $0.speaker == "spk_1" ? 0 : 1) }
        let windows = try #require(select(turns, words)["spk_1"]).map(ms)
        let total = windows.reduce(Int64(0)) { $0 + $1[1] - $1[0] }
        #expect((45_000 - Voiceprints.minSegmentMs...45_000).contains(total))
        #expect(windows.contains { (300_000...305_000).contains($0[0]) })
        #expect(windows.contains { (550_000...555_000).contains($0[0]) })
        #expect(windows.sorted { $0[0] < $1[0] } == windows)
    }

    // ports: VoiceprintSelectionTest#windowsStayInsideTheAudio
    @Test func windowsStayInsideTheAudio() throws {
        let windows = try #require(select([DiarizerTurn(0, 9000, 0)], [Word("spk_1", 0, 9000, "a")], totalMs: 5000)["spk_1"])
        #expect(windows.count == 1 && windows[0].endSample == samples(5000))
        #expect(select([], []).isEmpty)
    }

    // ports: VoiceprintSelectionTest#printsAreNormalisedAndCompared
    @Test func printsAreNormalisedAndCompared() throws {
        let a = try #require(Voiceprints.normalised([3, 4]))
        let b = try #require(Voiceprints.normalised([-4, 3]))
        let same = try #require(Voiceprints.cosine(a, a))
        let across = try #require(Voiceprints.cosine(a, b))
        #expect(abs(same - 1) < 1e-6)
        #expect(abs(across) < 1e-6)
        #expect(Voiceprints.normalised([0, 0]) == nil)
        #expect(Voiceprints.normalised([.nan, 1]) == nil)
        #expect(Voiceprints.cosine([1], [1, 0]) == nil, "prints of another length are not compared")
    }

    /// iOS: the saved-voice matcher (`VoiceMatcher`, over iOS's samples) normalises and compares the same way.
    @Test func theMatcherNormalisesAndComparesAlike() throws {
        let a = try #require(VoiceMatcher.normalized([3, 4]))
        let same = try #require(VoiceMatcher.cosine(a, a))
        #expect(abs(same - 1) < 1e-6)
        #expect(VoiceMatcher.normalized([0, 0]) == nil)
        #expect(VoiceMatcher.normalized([.nan, 1]) == nil)
    }
}
