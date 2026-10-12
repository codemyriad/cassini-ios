import Foundation

/// `work/checkpoint.json`: the finalized transcript of a stopped or interrupted job and what it was made from. A run
/// resumes from `doneMs` only when the checkpoint still matches the note's audio and language (`validate`).
///
/// iOS writes its own members (Android's checkpoint also carries encoder, diarizer and voice-clip state, which iOS does
/// not have): the source file name and signature, the language, the finalized segments with their words, and the
/// numbers the progress card and the provenance need. Every time is milliseconds on the recording clock.
public struct CheckpointState: Hashable, Sendable {
    /// The version `encode` writes and `decode` reads.
    public static let version = 1

    /// Every member `encode` writes.
    public static let keys: Set<String> = [
        "version", "source", "signature", "language", "segments", "doneMs", "totalMs", "elapsedMs", "inferenceMs",
        "resumedFromMs", "wordsComplete",
    ]

    /// The note's audio file name.
    public var source: String
    /// `length:mtime` of the source when the job began (`CheckpointState.signature(of:)`).
    public var signature: String
    /// BCP-47.
    public var language: String
    /// Finalized results, in time order; none ends after `doneMs`.
    public var segments: [TranscriptSegment]
    /// Audio up to here is transcribed.
    public var doneMs: Int64
    /// 0 when unknown.
    public var totalMs: Int64
    /// The jobs' running time so far, for the time-left estimate.
    public var elapsedMs: Int64
    /// The time spent in the speech analyzer so far.
    public var inferenceMs: Int64
    /// Where the latest run resumed; 0 when no run resumed.
    public var resumedFromMs: Int64
    /// Every word is final: a resumed run goes straight to the speaker step.
    public var wordsComplete: Bool

    public init(source: String, signature: String, language: String, segments: [TranscriptSegment], doneMs: Int64,
                totalMs: Int64, elapsedMs: Int64, inferenceMs: Int64 = 0, resumedFromMs: Int64 = 0,
                wordsComplete: Bool = false) {
        self.source = source; self.signature = signature; self.language = language; self.segments = segments
        self.doneMs = doneMs; self.totalMs = totalMs; self.elapsedMs = elapsedMs; self.inferenceMs = inferenceMs
        self.resumedFromMs = resumedFromMs; self.wordsComplete = wordsComplete
    }

    /// What a checkpoint must match to be resumed.
    public struct Expected: Hashable, Sendable {
        public var source: String
        public var signature: String
        public var language: String
        public init(source: String, signature: String, language: String) {
            self.source = source; self.signature = signature; self.language = language
        }
    }

    /// Why a checkpoint cannot be resumed.
    public enum Mismatch: Error, Hashable, Sendable {
        case version(Int)
        case source
        case signature
        case language
        case counters
        case wordsPastDone
    }

    /// The rules a checkpoint must pass before a run resumes from it.
    public func validate(_ expected: Expected) throws(Mismatch) {
        guard source == expected.source else { throw .source }
        guard signature == expected.signature else { throw .signature }
        guard language == expected.language else { throw .language }
        let limit = Int64(Limits.maxTranscribeDuration * 1000)
        guard (0...limit).contains(doneMs), (0...limit).contains(totalMs), totalMs == 0 || doneMs <= totalMs,
              elapsedMs >= 0, inferenceMs >= 0, (0...doneMs).contains(resumedFromMs) else { throw .counters }
        guard segments.allSatisfy({ Self.ms($0.end) <= doneMs }) else { throw .wordsPastDone }
    }

    /// `length:mtime` (epoch milliseconds) of the file at `url`; `nil:nil` when it cannot be read.
    public static func signature(of url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return "nil:nil" }
        return "\(size):\(Int64((modified.timeIntervalSince1970 * 1000).rounded()))"
    }

    /// Seconds on the recording clock as whole milliseconds, rounded to the nearest.
    public static func ms(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1000).rounded()) }

    /// The draft words of the finalized segments: one voice, recording-clock times.
    public var draftWords: [DraftWord] { segments.flatMap(\.draftWords) }
}

// MARK: - JSON

extension CheckpointState: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, source, signature, language, segments, doneMs, totalMs, elapsedMs, inferenceMs, resumedFromMs
        case wordsComplete
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == Self.version else { throw Mismatch.version(version) }
        source = try c.decode(String.self, forKey: .source)
        signature = try c.decode(String.self, forKey: .signature)
        language = try c.decode(String.self, forKey: .language)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        doneMs = try c.decode(Int64.self, forKey: .doneMs)
        totalMs = try c.decode(Int64.self, forKey: .totalMs)
        elapsedMs = try c.decode(Int64.self, forKey: .elapsedMs)
        inferenceMs = try c.decode(Int64.self, forKey: .inferenceMs)
        resumedFromMs = try c.decode(Int64.self, forKey: .resumedFromMs)
        wordsComplete = try c.decode(Bool.self, forKey: .wordsComplete)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .version)
        try c.encode(source, forKey: .source)
        try c.encode(signature, forKey: .signature)
        try c.encode(language, forKey: .language)
        try c.encode(segments, forKey: .segments)
        try c.encode(doneMs, forKey: .doneMs)
        try c.encode(totalMs, forKey: .totalMs)
        try c.encode(elapsedMs, forKey: .elapsedMs)
        try c.encode(inferenceMs, forKey: .inferenceMs)
        try c.encode(resumedFromMs, forKey: .resumedFromMs)
        try c.encode(wordsComplete, forKey: .wordsComplete)
    }

    /// Compact JSON with sorted members.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> CheckpointState {
        try JSONDecoder().decode(CheckpointState.self, from: data)
    }
}

// MARK: - Resume

extension TranscriptSegment {
    /// The draft words of the segment; a segment without word times is one word.
    public var draftWords: [DraftWord] {
        guard !words.isEmpty else {
            return [DraftWord(speaker: "", startMs: CheckpointState.ms(start), endMs: CheckpointState.ms(end), text: text)]
        }
        return words.map { word in
            DraftWord(speaker: "", startMs: CheckpointState.ms(word.start), endMs: CheckpointState.ms(word.end),
                      text: word.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The part of the segment a resumed run adds to a checkpoint covering audio up to `doneMs`: the words that end
    /// after it. Nil when the checkpoint already has all of it. A segment without word times counts from its middle.
    public func resumed(after doneMs: Int64) -> TranscriptSegment? {
        guard CheckpointState.ms(end) > doneMs else { return nil }
        guard !words.isEmpty else { return CheckpointState.ms((start + end) / 2) > doneMs ? self : nil }
        let kept = words.filter { CheckpointState.ms($0.end) > doneMs }
        guard kept.count < words.count else { return self }
        guard let first = kept.first else { return nil }
        var copy = self
        copy.words = kept
        copy.start = first.start
        copy.text = kept.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        return copy
    }
}
