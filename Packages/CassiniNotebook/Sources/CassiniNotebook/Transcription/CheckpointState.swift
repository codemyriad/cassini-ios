import CassiniCore
import Foundation

/// `work/checkpoint.json`: the words of a stopped or interrupted job and what they were made from. A run resumes only
/// when the checkpoint still matches the note's audio and the recognizer (`validate`).
///
/// iOS writes its own members (Android's checkpoint also carries the encoder state, which iOS does not have): the source
/// file name and signature, the recognizer (`model`), the words as segments, Parakeet's resume point (`recognition`),
/// the streaming speakers (`speakers`: Android's diarizer, speaker prefix and voice-clip members) and the numbers the
/// progress card and the provenance need. Every time is milliseconds on the recording clock. A file of another
/// version, or of another recognizer, is not resumed: its job fails with `CHECKPOINT_MISMATCH` and starts over.
public struct CheckpointState: Hashable, Sendable {
    /// The version `encode` writes and `decode` reads.
    public static let version = 1

    /// Every member `encode` writes; `recognition` only for a Parakeet run, `speakers` only for one that tells speakers
    /// apart as it goes.
    public static let keys: Set<String> = [
        "version", "source", "signature", "model", "segments", "doneMs", "totalMs", "elapsedMs", "inferenceMs",
        "resumedFromMs", "wordsComplete", "recognition", "speakers",
    ]

    /// The note's audio file name.
    public var source: String
    /// `length:mtime` of the source when the job began (`CheckpointState.signature(of:)`).
    public var signature: String
    /// The recognizer the words came from: Parakeet's model revision (Android's `model` member), or
    /// `appleModel(language:)` for the Apple Speech fallback, whose words also depend on the language.
    public var model: String
    /// The words so far, in time order; none ends after `doneMs`.
    public var segments: [TranscriptSegment]
    /// Audio up to here is transcribed.
    public var doneMs: Int64
    /// 0 when unknown.
    public var totalMs: Int64
    /// The jobs' running time so far, for the time-left estimate.
    public var elapsedMs: Int64
    /// The time spent recognizing so far: for Parakeet each window's decode alone (Android's `recognition.inferenceMs`),
    /// for Apple Speech the analyzer's running time.
    public var inferenceMs: Int64
    /// Where the latest run resumed; 0 when no run resumed.
    public var resumedFromMs: Int64
    /// Every word is final: a resumed run goes straight to the speaker step.
    public var wordsComplete: Bool
    /// Where a Parakeet run goes on from (`IncrementalTranscript`'s window); nil for Apple Speech.
    public var recognition: RecognitionCheckpoint?
    /// The streaming speakers of a Parakeet run (Android's `diarizer`, `speakerPrefix`, `speakerFailure`,
    /// `clipSamples` and `voiceClips` members); nil when the run does not tell speakers apart as it goes.
    public var speakers: SpeakerCheckpoint?
    /// Detected language of Whistle words; nil in legacy checkpoints.
    public var reportedLanguage: String?

    public init(source: String, signature: String, model: String, segments: [TranscriptSegment], doneMs: Int64,
                totalMs: Int64, elapsedMs: Int64, inferenceMs: Int64 = 0, resumedFromMs: Int64 = 0,
                wordsComplete: Bool = false, recognition: RecognitionCheckpoint? = nil, speakers: SpeakerCheckpoint? = nil) {
        self.source = source; self.signature = signature; self.model = model; self.segments = segments
        self.doneMs = doneMs; self.totalMs = totalMs; self.elapsedMs = elapsedMs; self.inferenceMs = inferenceMs
        self.resumedFromMs = resumedFromMs; self.wordsComplete = wordsComplete; self.recognition = recognition
        self.speakers = speakers
        self.reportedLanguage = nil
    }

    /// The `model` of an Apple Speech run in `language` (BCP-47): the words of another language do not resume.
    public static func appleModel(language: String) -> String { "\(TranscriptProvenance.appleSpeech) \(language)" }

    /// The language an Apple Speech checkpoint was asked for (`appleModel(language:)`); nil for Parakeet's.
    public var appleLanguage: String? {
        let prefix = Self.appleModel(language: "")
        return model.hasPrefix(prefix) ? String(model.dropFirst(prefix.count)) : nil
    }

    /// What a checkpoint must match to be resumed.
    public struct Expected: Hashable, Sendable {
        public var source: String
        public var signature: String
        public var model: String
        public init(source: String, signature: String, model: String) {
            self.source = source; self.signature = signature; self.model = model
        }
    }

    /// Why a checkpoint cannot be resumed.
    public enum Mismatch: Error, Hashable, Sendable {
        case version(Int)
        case source
        case signature
        case model
        case counters
        case wordsPastDone
        case recognition
        case speakers
    }

    /// The rules a checkpoint must pass before a run resumes from it.
    public func validate(_ expected: Expected) throws(Mismatch) {
        guard source == expected.source else { throw .source }
        guard signature == expected.signature else { throw .signature }
        guard model == expected.model else { throw .model }
        let limit = Int64(Limits.maxTranscribeDuration * 1000)
        guard (0...limit).contains(doneMs), (0...limit).contains(totalMs), totalMs == 0 || doneMs <= totalMs,
              elapsedMs >= 0, inferenceMs >= 0, (0...doneMs).contains(resumedFromMs) else { throw .counters }
        guard segments.allSatisfy({ Self.ms($0.end) <= doneMs }) else { throw .wordsPastDone }
        if let recognition {
            guard recognition.valid, recognition.doneMs <= doneMs else { throw .recognition }
        }
        if let speakers, !speakers.valid { throw .speakers }
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

    /// The draft words of the finalized segments, with the speaker each passage has (none on the Apple path),
    /// recording-clock times.
    public var draftWords: [DraftWord] { segments.flatMap(\.draftWords) }

    /// The words as the recognizer keeps them: the streaming speaker id or none, recording-clock milliseconds.
    public var words: [Word] { draftWords.map { Word($0.speaker, $0.startMs, $0.endMs, $0.text, lowConfidenceSpeaker: $0.lowConfidenceSpeaker == true) } }
}

/// The `recognition` member: where `IncrementalTranscript` stood at the checkpoint, in samples at the recognition rate
/// (16 kHz) on the recording clock. Its window holds the samples `start..<position`, decoded up to `end`. Android stores
/// the window's samples; iOS reads them again from the audio, which the signature says is unchanged, so the file
/// stays small (`ParakeetTranscriber`).
public struct RecognitionCheckpoint: Codable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64
    public var position: Int64

    public init(start: Int64, end: Int64, position: Int64) { self.start = start; self.end = end; self.position = position }

    /// Of a state that `IncrementalTranscript.checkpoint()` returned.
    public init(_ state: IncrementalState) {
        self.init(start: state.start, end: state.end, position: state.start + Int64(state.window.count))
    }

    /// Audio up to here is decoded.
    public var doneMs: Int64 { end * 1000 / Int64(Limits.asrRate) }

    /// `IncrementalState.validate`'s rules: `start <= end <= position`, a window of at most 28 s, within the longest
    /// recording.
    public var valid: Bool {
        start >= 0 && start <= end && end <= position && position - start <= Int64(IncrementalTranscript.windowSamples)
            && position <= Int64(Limits.maxSamples)
    }

    /// The state to restore: the window read again from the audio, and the checkpoint's words.
    public func state(window: [Float], words: [Word]) -> IncrementalState {
        IncrementalState(start: start, end: end, window: window, words: words)
    }
}

// MARK: - JSON

extension CheckpointState: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, source, signature, model, segments, doneMs, totalMs, elapsedMs, inferenceMs, resumedFromMs
        case wordsComplete, recognition, speakers, reportedLanguage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == Self.version else { throw Mismatch.version(version) }
        source = try c.decode(String.self, forKey: .source)
        signature = try c.decode(String.self, forKey: .signature)
        model = try c.decode(String.self, forKey: .model)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        doneMs = try c.decode(Int64.self, forKey: .doneMs)
        totalMs = try c.decode(Int64.self, forKey: .totalMs)
        elapsedMs = try c.decode(Int64.self, forKey: .elapsedMs)
        inferenceMs = try c.decode(Int64.self, forKey: .inferenceMs)
        resumedFromMs = try c.decode(Int64.self, forKey: .resumedFromMs)
        wordsComplete = try c.decode(Bool.self, forKey: .wordsComplete)
        recognition = try c.decodeIfPresent(RecognitionCheckpoint.self, forKey: .recognition)
        speakers = try c.decodeIfPresent(SpeakerCheckpoint.self, forKey: .speakers)
        reportedLanguage = try c.decodeIfPresent(String.self, forKey: .reportedLanguage)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .version)
        try c.encode(source, forKey: .source)
        try c.encode(signature, forKey: .signature)
        try c.encode(model, forKey: .model)
        try c.encode(segments, forKey: .segments)
        try c.encode(doneMs, forKey: .doneMs)
        try c.encode(totalMs, forKey: .totalMs)
        try c.encode(elapsedMs, forKey: .elapsedMs)
        try c.encode(inferenceMs, forKey: .inferenceMs)
        try c.encode(resumedFromMs, forKey: .resumedFromMs)
        try c.encode(wordsComplete, forKey: .wordsComplete)
        try c.encodeIfPresent(recognition, forKey: .recognition)
        try c.encodeIfPresent(speakers, forKey: .speakers)
        try c.encodeIfPresent(reportedLanguage, forKey: .reportedLanguage)
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
    /// The draft words of the segment, with its speaker id (empty without one); a segment without word times is one
    /// word.
    public var draftWords: [DraftWord] {
        let speaker = speakerID ?? ""
        guard !words.isEmpty else {
            return [DraftWord(speaker: speaker, startMs: CheckpointState.ms(start), endMs: CheckpointState.ms(end), text: text)]
        }
        return words.map { word in
            DraftWord(speaker: speaker, startMs: CheckpointState.ms(word.start), endMs: CheckpointState.ms(word.end),
                      text: word.text.trimmingCharacters(in: .whitespacesAndNewlines), lowConfidenceSpeaker: word.lowConfidenceSpeaker)
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

    /// The most words one segment groups.
    public static let maxGroupWords = 45
    /// A pause longer than this starts a new segment.
    public static let maxGroupGapMs: Int64 = 2_000

    /// `words` as the note's segments: a new one at a change of speaker, a pause over 2 s, or after 45 words (the
    /// grouping of an imported document). `label` names a speaker id; an empty id has no speaker.
    public static func segments(of words: [Word], label: (String) -> String? = { _ in nil }) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var group: [Word] = []
        func flush() {
            guard let first = group.first else { return }
            let timed = group.map { word in
                TimedWord(text: word.text, start: Double(word.startMs) / 1000, end: Double(word.endMs) / 1000,
                          lowConfidenceSpeaker: word.lowConfidenceSpeaker ? true : nil)
            }
            segments.append(TranscriptSegment(
                text: group.map(\.text).joined(separator: " "), start: Double(first.startMs) / 1000,
                end: Double(group.map(\.endMs).max() ?? first.endMs) / 1000,
                speaker: first.speaker.isEmpty ? nil : label(first.speaker) ?? first.speaker,
                speakerID: first.speaker.isEmpty ? nil : first.speaker, words: timed))
            group.removeAll(keepingCapacity: true)
        }
        for word in words {
            if let previous = group.last, previous.speaker != word.speaker || group.count >= maxGroupWords
                || word.startMs - previous.endMs > maxGroupGapMs { flush() }
            group.append(word)
        }
        flush()
        return segments
    }
}
