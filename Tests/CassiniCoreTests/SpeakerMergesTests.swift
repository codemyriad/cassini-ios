@testable import CassiniCore
import Testing

@Suite struct SpeakerMergesTests {
    // ports: SpeakerMergesTest#chainedMergesApplyToCurrentAndFutureWordsWithoutChangingTheirClock
    @Test func chainedMergesApplyToCurrentAndFutureWordsWithoutChangingTheirClock() throws {
        let first = try SpeakerMerges.merge([:], source: "b", into: "a")
        let next = try SpeakerMerges.merge(first, source: "a", into: "c")
        #expect(next == ["b": "c", "a": "c"])
        let raw = Transcript([Word("b", 200, 400, "Hello"), Word("a", 300, 500, "world"), Word("d", 600, 700, "!")], language: "it")
        let edited = try SpeakerMerges.apply(raw, aliases: next)
        #expect(edited.words.map(\.speaker) == ["c", "c", "d"])
        var restored = edited
        restored.words = zip(edited.words, raw.words).map { Word($1.speaker, $0.startMs, $0.endMs, $0.text) }
        #expect(restored == raw)
        #expect(try SpeakerMerges.apply(Transcript([Word("b", 10_000, 11_000, "Poi")]), aliases: next).words.map(\.speaker) == ["c"])
    }

    // ports: SpeakerMergesTest#anExistingMergeCannotBecomeACycle
    @Test func anExistingMergeCannotBecomeACycle() {
        #expect(throws: CassiniError.self) { try SpeakerMerges.merge(["b": "a"], source: "a", into: "b") }
        #expect(throws: CassiniError.self) { try SpeakerMerges.resolve("a", aliases: ["a": "b", "b": "a"]) }
    }

    // ports: SpeakerMergesTest#provenanceRecordsAnEditWithoutMutatingTheRecognitionRecord
    @Test func provenanceRecordsAnEditWithoutMutatingTheRecognitionRecord() throws {
        let before = JSONObject([("engine", .string("Parakeet")), ("x-inferenceMs", .int(23))])
        let edited = SpeakerMerges.processing(before, aliases: ["b": "a"], sourceVariant: "words")
        #expect(!before.has("x-speakerMerges"))
        #expect(try edited.string("engine") == "Parakeet")
        #expect(try edited.string("x-derivedFromTranscript") == "words")
        #expect(try edited.object("x-speakerMerges").string("b") == "a")
        #expect(try edited.string("x-speakerAssignmentEditedBy") == "user")
    }

    // ports: SpeakerMergesTest#mergedVoiceClipsStayWithinTheFortyFiveSecondBudget
    @Test func mergedVoiceClipsStayWithinTheFortyFiveSecondBudget() throws {
        let rate: Int64 = 16_000
        let clips: [String: [Range<Int64>]] = [
            "a": [0..<10 * rate, 10 * rate..<20 * rate, 20 * rate..<30 * rate],
            "b": [30 * rate..<40 * rate, 40 * rate..<50 * rate, 50 * rate..<60 * rate],
        ]
        let result = try SpeakerMerges.windows(clips, aliases: ["b": "a"])
        #expect(Set(result.keys) == ["a"])
        #expect(result["a"]!.reduce(0) { $0 + $1.count } == 45 * rate)
        #expect(result["a"]!.allSatisfy { $0.count <= 10 * rate })
    }
}
