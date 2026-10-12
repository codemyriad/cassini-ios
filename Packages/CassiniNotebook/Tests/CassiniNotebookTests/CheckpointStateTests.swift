import Foundation
import Testing
import CassiniNotebook

/// checkpoint.json through its codec, and the rules a checkpoint must pass to resume.
@Suite struct CheckpointStateTests {
    private let segments = [
        TranscriptSegment(text: "La parte", start: 1.308, end: 1.788,
                          words: [TimedWord(text: "La", start: 1.308, end: 1.548), TimedWord(text: " parte", start: 1.548, end: 1.788)]),
        TranscriptSegment(text: "settentrionale", start: 1.788, end: 2.898,
                          words: [TimedWord(text: " settentrionale", start: 1.788, end: 2.898)]),
    ]

    private func state(signature: String = "4096:1700000000000") -> CheckpointState {
        CheckpointState(source: "audio.m4a", signature: signature, language: "it-IT", segments: segments, doneMs: 2_898,
                        totalMs: 59_968, elapsedMs: 18_754, inferenceMs: 4_776, resumedFromMs: 0)
    }

    private func expected(signature: String = "4096:1700000000000") -> CheckpointState.Expected {
        .init(source: "audio.m4a", signature: signature, language: "it-IT")
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

    // ports: CheckpointStateTest#encodingWritesExactlyTheVersionTwoMembers (adapted: iOS version 1 members)
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
        #expect(throws: CheckpointState.Mismatch.version(2)) { try stored(state()) { $0["version"] = 2 } }
        #expect(throws: CheckpointState.Mismatch.version(0)) { try stored(state()) { $0["version"] = 0 } }
        #expect(throws: (any Error).self) { try stored(state()) { $0["segments"] = nil } }
        rejects(.source) { $0.source = "audio.wav" }
        rejects(.signature) { $0.signature = "1:2" }
        rejects(.language) { $0.language = "en-US" }
        let limit = Int64(Limits.maxTranscribeDuration * 1000)
        rejects(.counters) { $0.doneMs = -1 }
        rejects(.counters) { $0.doneMs = limit + 1; $0.totalMs = 0 }
        rejects(.counters) { $0.totalMs = 2_000 }
        rejects(.counters) { $0.elapsedMs = -1 }
        rejects(.counters) { $0.resumedFromMs = 3_000 }
        rejects(.wordsPastDone) { $0.doneMs = 2_000 }
        // An unknown total still resumes.
        var unknown = state()
        unknown.totalMs = 0
        try unknown.validate(expected())
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
}
