import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// Android's VoiceClipCacheTest and VoiceStalenessTest: the bounded clips the voiceprints are made from, and which
/// saved voices the pinned CAM++ model can still compare.
@Suite struct VoiceClipCacheTests {
    final class Clips: ClipStore, @unchecked Sendable {
        let sampleRate = Limits.asrRate
        var samples: [Float] = []
        var sampleCount: Int { samples.count }
        func append(_ samples: ArraySlice<Float>) throws { self.samples += samples }
        func read(_ start: Int, _ count: Int) throws -> [Float] { Array(samples[start..<(start + count)]) }
    }

    // ports: VoiceClipCacheTest#longMeetingsKeepOnlyTheBoundedSpeakerSampleBudget
    @Test func longMeetingsKeepOnlyTheBoundedSpeakerSampleBudget() throws {
        let source = Clips()
        let cache = try VoiceClipCache(audio: source)
        let chunk = PcmAudio([Float](repeating: 0.1, count: 28 * Limits.asrRate), sampleRate: Limits.asrRate)
        // 26 minutes of one voice cannot create a 26-minute PCM cache.
        for index in 0..<60 {
            try cache.accept(chunk, turns: [DiarizerTurn(0, 28_000, 0)], words: [Word("diar_test_1", 0, 28_000, "hello")],
                             startMs: Int64(index) * 26_000)
        }
        let durationMs = source.sampleCount * 1000 / Limits.asrRate
        #expect(durationMs <= 45_000)
        #expect(durationMs >= 43_000)
        #expect(source.sampleCount * 4 <= 45 * 16_000 * 4)
        #expect(Set(cache.windows.keys) == ["diar_test_1"])
        #expect(cache.windows.values.joined().allSatisfy { $0.endSample - $0.startSample <= 10 * Limits.asrRate })
    }

    /// The first second of a later window is the overlap the earlier one had: its clips start after it. A ninth speaker
    /// gets no clips, and a cache restored from a checkpoint goes on with the speaker's budget.
    @Test func laterWindowsSkipTheOverlapAndTheBudgetCarriesOver() throws {
        let source = Clips()
        let cache = try VoiceClipCache(audio: source)
        let chunk = PcmAudio([Float](repeating: 0.1, count: 10 * Limits.asrRate), sampleRate: Limits.asrRate)
        try cache.accept(chunk, turns: [DiarizerTurn(0, 10_000, 0)], words: [Word("a", 0, 10_000, "x")], startMs: 26_000)
        #expect(cache.windows["a"] == [PrintWindow(0, 9800 * 16 - 16_000)], "from 1 s in, the end trimmed by 200 ms")
        let speakers = (0..<9).map { "s\($0)" }
        try cache.accept(PcmAudio([Float](repeating: 0.1, count: 9 * 6 * Limits.asrRate), sampleRate: Limits.asrRate),
                         turns: speakers.indices.map { DiarizerTurn(Int64($0) * 6000, Int64($0) * 6000 + 6000, $0) },
                         words: speakers.indices.map { Word(speakers[$0], Int64($0) * 6000, Int64($0) * 6000 + 6000, "x") },
                         startMs: 0)
        #expect(cache.windows.count == SpeakerBudget.maxSpeakers, "a, then the first seven of nine")
        #expect(cache.windows["s7"] == nil && cache.windows["s8"] == nil)
        let restored = try VoiceClipCache(audio: source, restored: cache.windows)
        #expect(restored.windows == cache.windows)
        #expect(throws: VoiceClipCache.Invalid.self) {
            try VoiceClipCache(audio: source, restored: ["a": [PrintWindow(0, source.sampleCount + 1)]])
        }
    }

    // ports: VoiceStalenessTest#aVoiceOfThePinnedModelAndDimensionIsCurrent
    @Test func aVoiceOfThePinnedModelAndDimensionIsCurrent() {
        #expect(!VoiceStaleness.isStale(voice(VoiceprintModel.sha256, dim: 512), model: VoiceprintModel.sha256,
                                        dimension: VoiceprintModel.dimension))
    }

    // ports: VoiceStalenessTest#anotherModelIsStale
    @Test func anotherModelIsStale() {
        #expect(VoiceStaleness.isStale(voice(String(repeating: "0", count: 64), dim: 512), model: VoiceprintModel.sha256,
                                       dimension: VoiceprintModel.dimension))
        #expect(VoiceStaleness.isStale(voice("pyannote-community-1-wespeaker-coreml-v1:abc", dim: 256),
                                       model: VoiceprintModel.sha256, dimension: VoiceprintModel.dimension),
                "a voice of the FluidAudio builds is named again")
    }

    // ports: VoiceStalenessTest#anotherDimensionIsStale
    @Test func anotherDimensionIsStale() {
        for dim in [192, 513] {
            #expect(VoiceStaleness.isStale(voice(VoiceprintModel.sha256, dim: dim), model: VoiceprintModel.sha256,
                                           dimension: VoiceprintModel.dimension))
        }
    }

    // ports: VoiceStalenessTest#thePinnedDimensionIs512
    @Test func thePinnedDimensionIs512() {
        #expect(VoiceprintModel.dimension == 512)
        #expect(VoiceprintModel.sha256 == "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b")
    }

    private func voice(_ model: String, dim: Int) -> SavedVoice {
        SavedVoice(name: "Anna", samples: [VoiceSample(noteID: UUID(), print: SpeakerPrint(
            speakerID: "a", model: model, vector: [Float](repeating: 0.1, count: dim), speechSeconds: 5))])
    }
}
