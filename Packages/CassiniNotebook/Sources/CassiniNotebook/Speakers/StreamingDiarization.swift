import CassiniCore
import Foundation

/// The speaker limits that several components must agree on, in one place (Android's `SpeakerBudget`).
public enum SpeakerBudget {
    /// Speakers the Sortformer model tells apart (slots 0..7), and speakers the voice-clip cache keeps.
    public static let maxSpeakers = 8
    /// Seconds of clean clips kept per speaker for its voiceprint.
    public static let secondsPerSpeaker = 45
    /// Turns of an earlier window are kept up to this far into the next window, which overlaps it.
    public static let turnOverlapMs: Int64 = 1000
    /// Floats a saved Sortformer streaming state may hold. Both patches enforce the same bound as a literal
    /// (scripts/streaming-diarization.patch for the JNI, scripts/streaming-diarization-c-api.patch for the C API that
    /// iOS calls); SpeakerBudgetTests fails when they differ from this constant.
    public static let diarizerStateFloats = 200_000
}

/// One stretch of a Sortformer result: `speaker` is the model's slot (0..7), times in milliseconds. Android's
/// `SpeakerTurn`; iOS's `SpeakerTurn` is the attribution's turn in seconds with a string id (`speakerTurn(prefix:)`).
public struct DiarizerTurn: Hashable, Sendable {
    public var startMs: Int64
    public var endMs: Int64
    public var speaker: Int
    public init(_ startMs: Int64, _ endMs: Int64, _ speaker: Int) {
        self.startMs = startMs; self.endMs = endMs; self.speaker = speaker
    }

    /// The turn as the attribution reads it, with Android's stable id: slot `n` is `<prefix><n + 1>`.
    public func speakerTurn(prefix: String) -> SpeakerTurn {
        SpeakerTurn(speakerID: "\(prefix)\(speaker + 1)", start: Double(startMs) / 1000, end: Double(endMs) / 1000)
    }
}

/// One segment as the native diarizer returns it, in seconds of the samples passed in.
public struct DiarizerSegment: Hashable, Sendable {
    public var start: Float
    public var end: Float
    public var speaker: Int
    public init(start: Float, end: Float, speaker: Int) { self.start = start; self.end = end; self.speaker = speaker }
}

/// Sortformer's settings and the rules that turn its segments into turns (Android's `Diarization` constants and
/// `SortformerStream`'s filtering). The native diarizer lives in CassiniSherpa.
public enum Diarization {
    /// Speaker activity above this probability counts as speech. The model decides the number of speakers (up to 8).
    public static let threshold: Float = 0.5
    public static let minDurationOn: Float = 0.3
    public static let minDurationOff: Float = 0.5

    /// The turns of one streaming chunk of `durationMs`: finite segments of a slot below `SpeakerBudget.maxSpeakers`,
    /// in milliseconds cut toward zero and held to the chunk, without empty ones. The order is the native one (sorted
    /// by start time).
    public static func chunkTurns(_ segments: [DiarizerSegment], durationMs: Int64) -> [DiarizerTurn] {
        turns(segments.filter { (0..<SpeakerBudget.maxSpeakers).contains($0.speaker) }, durationMs: durationMs)
    }

    /// The turns of a whole recording in one call: as `chunkTurns`, but any non-negative slot counts (Android's
    /// `SortformerStream.turns`).
    public static func wholeTurns(_ segments: [DiarizerSegment], durationMs: Int64) -> [DiarizerTurn] {
        turns(segments.filter { $0.speaker >= 0 }, durationMs: durationMs)
    }

    /// Android's `Diarization.assign`: every word keeps its order, text and times and gets the speaker whose turns
    /// overlap it most, a speaker's overlapping turns counted once; a word between turns gets the nearest turn. Ties go
    /// to the turn that comes first in time (then the lower slot), so the native order does not matter. With
    /// `stableIds` slot `n` is `<prefix><n + 1>` in every window (the streaming job); otherwise speakers are numbered
    /// from 1 in order of their first word. Without a valid turn the words come back as they are.
    public static func assign(_ words: [Word], turns: [DiarizerTurn], prefix: String = "spk_",
                              stableIds: Bool = false) -> [Word] {
        let union = unionTurns(turns)
        guard !union.isEmpty else { return words }
        var ids: [Int: String] = [:]
        return words.map { word in
            var overlaps: [(speaker: Int, ms: Int64)] = []
            for turn in union {
                let overlap = min(word.endMs, turn.endMs) - max(word.startMs, turn.startMs)
                guard overlap > 0 else { continue }
                if let index = overlaps.firstIndex(where: { $0.speaker == turn.speaker }) {
                    overlaps[index].ms += overlap
                } else {
                    overlaps.append((turn.speaker, overlap))
                }
            }
            // Kotlin's maxByOrNull and minBy return the first of equal values.
            var best = overlaps.first
            for overlap in overlaps.dropFirst() where overlap.ms > best!.ms { best = overlap }
            let speaker: Int
            if let best {
                speaker = best.speaker
            } else {
                var nearest = union[0]
                for turn in union.dropFirst() where gap(word, turn) < gap(word, nearest) { nearest = turn }
                speaker = nearest.speaker
            }
            let id: String
            if stableIds {
                id = "\(prefix)\(speaker + 1)"
            } else if let known = ids[speaker] {
                id = known
            } else {
                id = "\(prefix)\(ids.count + 1)"
                ids[speaker] = id
            }
            return Word(id, word.startMs, word.endMs, word.text)
        }
    }

    /// The valid turns with each speaker's overlapping turns joined, sorted by start, end and slot.
    static func unionTurns(_ turns: [DiarizerTurn]) -> [DiarizerTurn] {
        let valid = turns.filter { $0.startMs >= 0 && $0.endMs > $0.startMs && $0.speaker >= 0 }
        var order: [Int] = []
        var bySpeaker: [Int: [DiarizerTurn]] = [:]
        for turn in valid {
            if bySpeaker[turn.speaker] == nil { order.append(turn.speaker) }
            bySpeaker[turn.speaker, default: []].append(turn)
        }
        var union: [DiarizerTurn] = []
        for speaker in order {
            var merged: [DiarizerTurn] = []
            for turn in bySpeaker[speaker, default: []].sorted(by: { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }) {
                if let last = merged.indices.last, turn.startMs <= merged[last].endMs {
                    merged[last].endMs = max(merged[last].endMs, turn.endMs)
                } else {
                    merged.append(turn)
                }
            }
            union += merged
        }
        return union.sorted { ($0.startMs, $0.endMs, $0.speaker) < ($1.startMs, $1.endMs, $1.speaker) }
    }

    private static func gap(_ word: Word, _ turn: DiarizerTurn) -> Int64 {
        max(turn.startMs - word.endMs, word.startMs - turn.endMs, 0)
    }

    private static func turns(_ segments: [DiarizerSegment], durationMs: Int64) -> [DiarizerTurn] {
        segments.filter { $0.start.isFinite && $0.end.isFinite }
            .map { DiarizerTurn(ms($0.start, durationMs), ms($0.end, durationMs), $0.speaker) }
            .filter { $0.endMs > $0.startMs }
    }

    /// Kotlin's `(seconds * 1000).toLong().coerceIn(0, duration)`: the product in Float, cut toward zero. Held to the
    /// range before the conversion, which would trap on a huge value where Kotlin saturates.
    static func ms(_ seconds: Float, _ durationMs: Int64) -> Int64 {
        let product = Double(seconds * 1000)
        return Int64(min(max(product, 0), Double(durationMs)).rounded(.towardZero))
    }
}

/// The speaker turns of a streaming diarization on the recording clock, window after window. Windows overlap, so the
/// turns of a later window replace those of the earlier one from `SpeakerBudget.turnOverlapMs` into it.
public struct TurnHistory: Hashable, Sendable {
    public private(set) var turns: [DiarizerTurn]

    public init(_ restored: [DiarizerTurn] = []) { turns = restored }

    /// Adds the turns `found` in the window that starts at `startMs`, each relative to that start.
    public mutating func add(_ found: [DiarizerTurn], startMs: Int64) {
        let cut = startMs == 0 ? 0 : startMs + SpeakerBudget.turnOverlapMs
        for index in turns.indices.reversed() {
            if turns[index].startMs >= cut {
                turns.remove(at: index)
            } else if turns[index].endMs > cut {
                turns[index].endMs = cut
            }
        }
        turns += found.map { DiarizerTurn(max(cut, startMs + $0.startMs), startMs + $0.endMs, $0.speaker) }
            .filter { $0.endMs > $0.startMs }
    }
}

/// What a streaming diarizer saves into a checkpoint (Android's `diarizer` member, `DiarizerState`): the native
/// speaker cache, the diarizer's own time and the turns so far on the recording clock. The cache is written as the
/// base64 of its little-endian 32-bit floats, as compact as Android's `CheckpointData.floats`.
public struct DiarizerState: Hashable, Sendable {
    public var cache: [Float]
    public var elapsedMs: Int64
    public var turns: [DiarizerTurn]
    public init(cache: [Float], elapsedMs: Int64, turns: [DiarizerTurn]) {
        self.cache = cache; self.elapsedMs = elapsedMs; self.turns = turns
    }

    /// The bytes of `floats`, little-endian.
    public static func bytes(_ floats: [Float]) -> Data {
        var data = Data(capacity: floats.count * 4)
        for value in floats { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// The floats of `data`; nil when its length is not a whole number of floats.
    public static func floats(_ data: Data) -> [Float]? {
        guard data.count % 4 == 0 else { return nil }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
    }
}

extension DiarizerState: Codable {
    private enum CodingKeys: String, CodingKey { case cache, elapsedMs, turns }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .cache)
        guard let data = Data(base64Encoded: text), let cache = Self.floats(data),
              cache.count <= SpeakerBudget.diarizerStateFloats else {
            throw DecodingError.dataCorruptedError(forKey: .cache, in: c, debugDescription: "Not a speaker cache")
        }
        self.cache = cache
        elapsedMs = try c.decode(Int64.self, forKey: .elapsedMs)
        turns = try c.decode([[Int64]].self, forKey: .turns).map { values in
            guard values.count == 3, let speaker = Int(exactly: values[2]) else {
                throw DecodingError.dataCorruptedError(forKey: .turns, in: c, debugDescription: "Not a turn")
            }
            return DiarizerTurn(values[0], values[1], speaker)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.bytes(cache).base64EncodedString(), forKey: .cache)
        try c.encode(elapsedMs, forKey: .elapsedMs)
        try c.encode(turns.map { [$0.startMs, $0.endMs, Int64($0.speaker)] }, forKey: .turns)
    }
}

/// Audio a voiceprint is read from, by sample (Android's `PcmSource`), so the voice-clip cache can stay on disk.
public protocol PcmSource {
    var sampleRate: Int { get }
    var sampleCount: Int { get }
    func read(_ start: Int, _ count: Int) throws -> [Float]
}

extension PcmAudio: PcmSource {
    public var sampleCount: Int { samples.count }
    public func read(_ start: Int, _ count: Int) throws -> [Float] { Array(samples[start..<(start + count)]) }
}
