import CassiniCore
import Foundation
import Testing
import CassiniNotebook

/// checkpoint.json through its codec, and the rules a checkpoint must pass to resume.
@Suite struct CheckpointStateTests {
    /// `ModelCatalog.parakeetRevision` (CassiniEngine).
    static let ultra = CheckpointGoldenTests.ultra
    /// A window decoded to 2.898 s, read 0.1 s further.
    private static let recognition = RecognitionCheckpoint(start: 0, end: 46_368, position: 47_968)
    /// The streaming speakers after that window: one slot heard, one second of its speech kept.
    static let speakers = SpeakerCheckpoint(prefix: "P_", diarizer: DiarizerState(cache: [0.25, -1.5, .leastNonzeroMagnitude],
                                                                                  elapsedMs: 41, turns: [DiarizerTurn(1_300, 2_900, 0)]),
                                            clipSamples: 16_000, voiceClips: ["P_1": [PrintWindow(0, 16_000)]])

    private let segments = [
        TranscriptSegment(text: "La parte", start: 1.308, end: 1.788,
                          words: [TimedWord(text: "La", start: 1.308, end: 1.548), TimedWord(text: " parte", start: 1.548, end: 1.788)]),
        TranscriptSegment(text: "settentrionale", start: 1.788, end: 2.898,
                          words: [TimedWord(text: " settentrionale", start: 1.788, end: 2.898)]),
    ]

    private func state(signature: String = "4096:1700000000000") -> CheckpointState {
        CheckpointState(source: "audio.m4a", signature: signature, model: Self.ultra, segments: segments, doneMs: 2_898,
                        totalMs: 59_968, elapsedMs: 18_754, inferenceMs: 4_776, resumedFromMs: 0,
                        recognition: Self.recognition, speakers: Self.speakers)
    }

    private func expected(signature: String = "4096:1700000000000") -> CheckpointState.Expected {
        .init(source: "audio.m4a", signature: signature, model: Self.ultra)
    }

    private func members(_ data: Data) throws -> Set<String> {
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(json.keys)
    }

    /// The state as stored and read back.
    private func stored(_ state: CheckpointState, _ change: (inout [String: Any]) -> Void = { _ in }) throws -> CheckpointState {
        var json = try #require(try JSONSerialization.jsonObject(with: state.encoded()) as? [String: Any])
        change(&json)
        return try CheckpointState.decode(JSONSerialization.data(withJSONObject: json))
    }

    // ports: CheckpointStateTest#encodingWritesExactlyTheVersionTwoMembers (adapted: iOS members)
    @Test func encodingWritesExactlyTheMembers() throws {
        let data = try state().encoded()
        #expect(try members(data) == CheckpointState.keys)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == CheckpointState.version)
        #expect(!String(decoding: data, as: UTF8.self).contains("\n"), "Compact")
    }

    // ports: CheckpointStateTest#decodingRestoresEveryMemberBitForBit
    @Test func decodingRestoresEveryMember() throws {
        var original = state()
        original.resumedFromMs = 1_000
        original.wordsComplete = true
        #expect(try stored(original) == original)
    }

    // ports: CheckpointStateTest#aValidCheckpointPassesTheResumeRules
    @Test func aValidCheckpointPassesTheResumeRules() throws {
        try state().validate(expected())
        try stored(state()).validate(expected())
    }

    // ports: CheckpointStateTest#eachResumeRuleRejects
    @Test func eachResumeRuleRejects() throws {
        func rejects(_ mismatch: CheckpointState.Mismatch, _ change: (inout CheckpointState) -> Void) {
            var copy = state()
            change(&copy)
            #expect(throws: mismatch) { try copy.validate(expected()) }
        }
        #expect(throws: CheckpointState.Mismatch.version(3)) { try stored(state()) { $0["version"] = 3 } }
        #expect(throws: CheckpointState.Mismatch.version(0)) { try stored(state()) { $0["version"] = 0 } }
        #expect(throws: (any Error).self) { try stored(state()) { $0["segments"] = nil } }
        rejects(.source) { $0.source = "audio.wav" }
        rejects(.signature) { $0.signature = "1:2" }
        rejects(.model) { $0.model = CheckpointState.appleModel(language: "it-IT") }
        let limit = Int64(Limits.maxTranscribeDuration * 1000)
        rejects(.counters) { $0.doneMs = -1 }
        rejects(.counters) { $0.doneMs = limit + 1; $0.totalMs = 0 }
        rejects(.counters) { $0.totalMs = 2_000 }
        rejects(.counters) { $0.elapsedMs = -1 }
        rejects(.counters) { $0.resumedFromMs = 3_000 }
        rejects(.wordsPastDone) { $0.doneMs = 2_000; $0.recognition = nil }
        // IncrementalState's restore rules, and a window decoded past the checkpoint.
        rejects(.recognition) { $0.recognition = RecognitionCheckpoint(start: -1, end: 0, position: 0) }
        rejects(.recognition) { $0.recognition = RecognitionCheckpoint(start: 100, end: 50, position: 200) }
        rejects(.recognition) { $0.recognition = RecognitionCheckpoint(start: 0, end: 300, position: 200) }
        rejects(.recognition) {
            $0.recognition = RecognitionCheckpoint(start: 0, end: 0, position: Int64(IncrementalTranscript.windowSamples) + 1)
        }
        rejects(.recognition) { $0.recognition = RecognitionCheckpoint(start: 0, end: 48_000, position: 48_000) }
        // An unknown total still resumes, as does an Apple Speech checkpoint, which has no window.
        var unknown = state()
        unknown.totalMs = 0
        try unknown.validate(expected())
        var apple = state()
        apple.recognition = nil
        apple.model = CheckpointState.appleModel(language: "it-IT")
        try apple.validate(.init(source: "audio.m4a", signature: apple.signature, model: apple.model))
    }

    @Test func theRecognitionMemberHoldsTheWindowAndRestoresIt() throws {
        let window: [Float] = (0..<1_600).map { Float($0) }
        let state = IncrementalState(start: 16_000, end: 16_800, window: window, words: [Word("", 1_000, 1_040, "ciao")])
        let recognition = RecognitionCheckpoint(state)
        #expect(recognition == RecognitionCheckpoint(start: 16_000, end: 16_800, position: 17_600))
        #expect(recognition.doneMs == 1_050)
        #expect(recognition.state(window: window, words: state.words) == state)
        var checkpoint = self.state()
        checkpoint.recognition = recognition
        #expect(try stored(checkpoint).recognition == recognition)
        // An Apple Speech checkpoint writes none.
        checkpoint.recognition = nil
        #expect(try !members(checkpoint.encoded()).contains("recognition"))
    }

    @Test func wordsBecomeSegmentsAtASpeakerAPauseOrFortyFiveWords() {
        let words = (0..<50).map { Word("", Int64($0) * 300, Int64($0) * 300 + 200, "w\($0)") }
            + [Word("", 20_000, 20_400, "late"), Word("spk_2", 20_500, 20_900, "other")]
        let segments = TranscriptSegment.segments(of: words) { $0 == "spk_2" ? "Anna" : nil }
        #expect(segments.map(\.words.count) == [45, 5, 1, 1])
        #expect(segments[0].text.hasPrefix("w0 w1 w2"))
        #expect(segments[0].words[0].text == "w0 " && segments[0].words[44].text == "w44")
        #expect(segments[0].speakerID == nil && segments[0].speaker == nil)
        #expect(segments[3].speakerID == "spk_2" && segments[3].speaker == "Anna")
        #expect(segments[2].start == 20 && segments[2].end == 20.4)
        // The words come back as they went in.
        let back = segments.flatMap(\.draftWords).map { Word($0.speaker.isEmpty ? "" : $0.speaker, $0.startMs, $0.endMs, $0.text) }
        #expect(back.map(\.text) == words.map(\.text) && back.map(\.startMs) == words.map(\.startMs))
    }

    @Test func aParakeetCheckpointFollowsEachWindowAtMostEveryTenSeconds() {
        #expect(!SpeechWindows.windowCheckpointDue(doneMs: 28_000, savedMs: 28_000, nowMs: 100_000, savedAt: nil))
        #expect(SpeechWindows.windowCheckpointDue(doneMs: 28_000, savedMs: 0, nowMs: 100, savedAt: nil))
        #expect(!SpeechWindows.windowCheckpointDue(doneMs: 54_000, savedMs: 28_000, nowMs: 9_999, savedAt: 0))
        #expect(SpeechWindows.windowCheckpointDue(doneMs: 54_000, savedMs: 28_000, nowMs: 10_000, savedAt: 0))
    }

    // ports: CheckpointStateTest#aChangedSourceInvalidatesTheCheckpoint
    @Test func aChangedSourceInvalidatesTheCheckpoint() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("audio.m4a")
        try Data(count: 4096).write(to: source)
        let checkpoint = state(signature: CheckpointState.signature(of: source))
        try checkpoint.validate(expected(signature: CheckpointState.signature(of: source)))
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: source.path)
        #expect(throws: CheckpointState.Mismatch.signature) {
            try checkpoint.validate(expected(signature: CheckpointState.signature(of: source)))
        }
    }

    // ports: CheckpointStateTest#theSignatureIsLengthAndModificationTime
    @Test func theSignatureIsLengthAndModificationTime() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data(count: 4096).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let modified = Date(timeIntervalSince1970: 1_700_000_000.123)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
        #expect(CheckpointState.signature(of: source) == "4096:1700000000123")
        #expect(CheckpointState.signature(of: source.appendingPathExtension("missing")) == "nil:nil")
    }

    // ports: CheckpointStateTest#recognitionRestoresWhereTheJobStopped (adapted: a resumed run hears the overlap again)
    @Test func aResumedRunKeepsOnlyTheWordsAfterTheCheckpoint() throws {
        let overlap = TranscriptSegment(text: "settentrionale, conosciuta", start: 1.788, end: 3.468, words: [
            TimedWord(text: " settentrionale,", start: 1.788, end: 2.898), TimedWord(text: " conosciuta", start: 2.908, end: 3.468),
        ])
        let kept = try #require(overlap.resumed(after: 2_898))
        #expect(kept.text == "conosciuta")
        #expect(kept.start == 2.908)
        #expect(kept.words.map(\.text) == [" conosciuta"])
        #expect(segments[1].resumed(after: 2_898) == nil)
        let later = TranscriptSegment(text: "come", start: 3.468, end: 3.708, words: [TimedWord(text: "come", start: 3.468, end: 3.708)])
        #expect(later.resumed(after: 2_898) == later)
        // Without word times a segment counts from its middle.
        #expect(TranscriptSegment(text: "a", start: 2, end: 3.5).resumed(after: 2_898) == nil)
        #expect(TranscriptSegment(text: "b", start: 2.5, end: 3.5).resumed(after: 2_898) != nil)
    }

    // ports: CheckpointStateTest#decodingRestoresEveryMemberBitForBit (its speaker members: Android's `diarizer`,
    // `speakerPrefix`, `speakerFailure`, `clipSamples` and `voiceClips` as iOS's `speakers` member)
    @Test func theStreamingSpeakersRoundTripExactly() throws {
        let decoded = try CheckpointState.decode(state().encoded())
        #expect(decoded.speakers == Self.speakers, "every float of the cache, bit for bit")
        let json = try #require(try JSONSerialization.jsonObject(with: state().encoded()) as? [String: Any])
        let speakers = try #require(json["speakers"] as? [String: Any])
        #expect(Set(speakers.keys) == ["prefix", "failed", "diarizer", "clipSamples", "voiceClips"])
        let diarizer = try #require(speakers["diarizer"] as? [String: Any])
        #expect(Set(diarizer.keys) == ["cache", "elapsedMs", "turns"])
        let cache = try #require(diarizer["cache"] as? String)
        #expect(Data(base64Encoded: cache)?.count == 12, "three little-endian floats")
        #expect(diarizer["turns"] as? [[Int]] == [[1_300, 2_900, 0]])
        #expect((speakers["voiceClips"] as? [String: [[Int]]])?["P_1"] == [[0, 16_000]])
        #expect(DiarizerState.floats(Data([0, 0, 0x80, 0x3F])) == [1], "little-endian")
        #expect(DiarizerState.floats(Data([0, 0, 0x80])) == nil)
    }

    /// Speakers no run could have saved (clips past the clip file, a cache over the cap, a damaged cache) do not resume.
    // ports: CheckpointStateTest#oversizedArraysAreRefused (the diarizer cache)
    @Test func speakersNoRunCouldHaveSavedDoNotResume() throws {
        var past = state()
        past.speakers?.voiceClips = ["P_1": [PrintWindow(0, 16_001)]]
        #expect(throws: CheckpointState.Mismatch.speakers) { try past.validate(expected()) }
        var many = state()
        many.speakers?.voiceClips = Dictionary(uniqueKeysWithValues: (0...SpeakerBudget.maxSpeakers).map { ("P_\($0)", [PrintWindow(0, 1)]) })
        #expect(throws: CheckpointState.Mismatch.speakers) { try many.validate(expected()) }
        try state().validate(expected())
        #expect(throws: (any Error).self) {
            try stored(state()) { json in
                var speakers = json["speakers"] as? [String: Any] ?? [:]
                var diarizer = speakers["diarizer"] as? [String: Any] ?? [:]
                diarizer["cache"] = "AAA="
                speakers["diarizer"] = diarizer
                json["speakers"] = speakers
            }
        }
        let big = DiarizerState(cache: [Float](repeating: 0, count: SpeakerBudget.diarizerStateFloats + 1), elapsedMs: 0, turns: [])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DiarizerState.self, from: JSONEncoder().encode(big)) }
    }

    /// A run that does not tell speakers apart as it goes writes no `speakers`.
    // ports: CheckpointStateTest#aJobWithoutEncoderOrDiarizerOmitsThem
    @Test func aCheckpointWithoutSpeakersStillReads() throws {
        let decoded = try stored(state()) { $0["speakers"] = nil }
        #expect(decoded.speakers == nil)
        #expect(decoded.segments == segments)
    }

    /// The draft words carry each passage's speaker id; a passage without one has none.
    @Test func theDraftWordsKeepTheStreamedSpeakers() {
        var checkpoint = state()
        checkpoint.segments[1].speakerID = "P_1"
        #expect(checkpoint.draftWords.map(\.speaker) == ["", "", "P_1"])
        #expect(checkpoint.words.map(\.speaker) == ["", "", "P_1"])
    }
}
