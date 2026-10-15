import Foundation
import Testing
@testable import CassiniNotebook

/// Android's SpeakerBudgetTest, plus the rules of the streaming diarizer's results (`Diarization`) that Android keeps
/// inside `SortformerStream` and `VoiceprintExtractor`.
@Suite struct SpeakerBudgetTests {
    private static let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../scripts").standardized

    private func bound(in patch: String, after function: String, pattern: String) throws -> Int {
        let text = try String(contentsOf: Self.scripts.appendingPathComponent(patch), encoding: .utf8)
        let body = try #require(text.range(of: function).map { String(text[$0.upperBound...]) }, "no \(function) in \(patch)")
        let match = try #require(try Regex(pattern).firstMatch(in: body), "no state bound in \(function) of \(patch)")
        let digits = try #require(match.output[1].substring, "no number in \(patch)")
        return try #require(Int(String(digits)))
    }

    /// The patches are pinned by hash with the runtime, so they cannot name `SpeakerBudget`; this test keeps the
    /// bounds equal instead: Android's JNI and the C API that iOS calls.
    // ports: SpeakerBudgetTest#theDiarizerStateCapIsTheBoundTheJniPatchEnforces
    @Test func theDiarizerStateCapIsTheBoundTheJniPatchEnforces() throws {
        #expect(try bound(in: "streaming-diarization.patch", after: "OfflineSpeakerDiarization_restoreStreamingState(",
                          pattern: #"if \(n > (\d+)\) return false;"#) == SpeakerBudget.diarizerStateFloats)
        #expect(try bound(in: "streaming-diarization-c-api.patch",
                          after: "SherpaOnnxOfflineSpeakerDiarizationRestoreStreamingState(",
                          pattern: #"if \(n < 0 \|\| n > (\d+) "#) == SpeakerBudget.diarizerStateFloats)
    }

    /// Android's figures, which the voice-clip cache and Sortformer's slots depend on.
    @Test func theBudgetAndTheDiarizerSettingsAreAndroids() {
        #expect(SpeakerBudget.maxSpeakers == 8)
        #expect(SpeakerBudget.secondsPerSpeaker == 45)
        #expect(SpeakerBudget.turnOverlapMs == 1000)
        #expect(Diarization.threshold == 0.5)
        #expect(Diarization.minDurationOn == 0.3)
        #expect(Diarization.minDurationOff == 0.5)
    }

    /// `SortformerStream.process`: finite segments of slots 0..7 only, in milliseconds held to the chunk, without
    /// empty turns, in the native order (sorted by start time).
    @Test func aChunkKeepsTheModelsSlotsHeldToTheChunk() {
        let segments = [DiarizerSegment(start: 0.25, end: 1.5, speaker: 0), DiarizerSegment(start: 1, end: 2, speaker: 8),
                        DiarizerSegment(start: -1, end: 0.0004, speaker: 1), DiarizerSegment(start: .nan, end: 3, speaker: 2),
                        DiarizerSegment(start: 2, end: .infinity, speaker: 3), DiarizerSegment(start: 27.5, end: 1e30, speaker: 7),
                        DiarizerSegment(start: 3, end: 2, speaker: 1), DiarizerSegment(start: 1, end: 2, speaker: -1)]
        #expect(Diarization.chunkTurns(segments, durationMs: 28_000) == [DiarizerTurn(250, 1500, 0), DiarizerTurn(27_500, 28_000, 7)])
        // The whole-recording call keeps any non-negative slot.
        #expect(Diarization.wholeTurns(segments, durationMs: 28_000)
            == [DiarizerTurn(250, 1500, 0), DiarizerTurn(1000, 2000, 8), DiarizerTurn(27_500, 28_000, 7)])
    }

    /// Kotlin's `(seconds * 1000).toLong()`: the Float product cut toward zero.
    @Test func millisecondsAreTheFloatProductCutTowardZero() {
        #expect(Diarization.ms(0.0019, 10_000) == 1)
        #expect(Diarization.ms(1.2345, 10_000) == Int64(Float(1.2345) * 1000))
        #expect(Diarization.ms(-0.5, 10_000) == 0)
    }

    /// Slot n is `<prefix><n + 1>`, whatever order the slots come in (Android's `stableIds`).
    // ports: VoiceClipCacheTest#speakerSlotsKeepTheirIdsWhenTheOrderWithinAChunkChanges
    @Test func speakerSlotsKeepTheirIdsWhenTheOrderWithinAChunkChanges() {
        let first = [DiarizerTurn(0, 1000, 3)].map { $0.speakerTurn(prefix: "diar_test_") }
        let later = [DiarizerTurn(0, 1000, 3), DiarizerTurn(1200, 2000, 0)].map { $0.speakerTurn(prefix: "diar_test_") }
        #expect(first == [SpeakerTurn(speakerID: "diar_test_4", start: 0, end: 1)])
        #expect(later.first == first.first)
        #expect(later.last?.speakerID == "diar_test_1")
        let passage = TranscriptSegment(text: "hello", start: 0.1, end: 0.5, words: [TimedWord(text: "hello", start: 0.1, end: 0.5)])
        let assigned = [first, later].map { SpeakerAttribution.assign([passage], turns: $0).first?.speakerID }
        #expect(assigned == ["diar_test_4", "diar_test_4"])
    }

    /// Android's `Voiceprints.normalised`: L2 over Double sums; a zero or non-finite norm gives nothing.
    @Test func voiceprintsAreNormalisedOrRefused() throws {
        let unit = try #require(Voiceprints.normalised([3, 4]))
        #expect(abs(unit[0] - 0.6) < 1e-7 && abs(unit[1] - 0.8) < 1e-7)
        #expect(Voiceprints.normalised([0, 0]) == nil)
        #expect(Voiceprints.normalised([.nan, 1]) == nil)
        #expect(Voiceprints.normalised([1e30, 1e30]) != nil, "summed in Double, as Android does")
    }
}
