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

/// A span of a speaker's clean speech to embed, in samples of the audio it is read from (Android's `PrintWindow`).
public struct PrintWindow: Hashable, Sendable {
    public var startSample: Int
    public var endSample: Int
    public init(_ startSample: Int, _ endSample: Int) { self.startSample = startSample; self.endSample = endSample }
}

/// CAM++ voiceprints (Android's `Voiceprints`, the part the extractor needs).
public enum Voiceprints {
    /// The vector divided by its L2 norm, summed in Double as Android does; nil for a zero or non-finite norm.
    public static func normalised(_ vector: [Float]) -> [Float]? {
        let norm = Float(vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot())
        guard norm.isFinite, norm != 0 else { return nil }
        return vector.map { $0 / norm }
    }
}
