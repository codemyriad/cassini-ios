import CassiniCore
import Foundation

/// A span of a speaker's clean speech to embed, in samples of the audio it is read from (Android's `PrintWindow`).
/// Written into a checkpoint as `[start, end]`, as Android's `voiceClips` member is.
public struct PrintWindow: Hashable, Sendable {
    public var startSample: Int
    public var endSample: Int
    public init(_ startSample: Int, _ endSample: Int) { self.startSample = startSample; self.endSample = endSample }
}

extension PrintWindow: Codable {
    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        startSample = try c.decode(Int.self)
        endSample = try c.decode(Int.self)
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a window") }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(startSample)
        try c.encode(endSample)
    }
}

/// One speaker's windows, in the order `Voiceprints.select` found the speakers.
public struct SpeakerWindows: Hashable, Sendable {
    public var speaker: String
    public var windows: [PrintWindow]
    public init(_ speaker: String, _ windows: [PrintWindow]) { self.speaker = speaker; self.windows = windows }
}

/// CAM++ voiceprints (Android's `Voiceprints`): one print per speaker from its clean single-voice speech. Prints never
/// leave the device.
public enum Voiceprints {
    public static let minSegmentMs: Int64 = 1_500
    public static let edgeTrimMs: Int64 = 200
    public static let maxSecondsPerSpeaker = Double(SpeakerBudget.secondsPerSpeaker)
    public static let minSecondsPerSpeaker = 4.0
    public static let maxWindowMs: Int64 = 10_000

    /// The vector divided by its L2 norm, summed in Double as Android does; nil for a zero or non-finite norm.
    public static func normalised(_ vector: [Float]) -> [Float]? {
        let norm = Float(vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot())
        guard norm.isFinite, norm != 0 else { return nil }
        return vector.map { $0 / norm }
    }

    /// Both prints are L2-normalised, so this is their dot product, summed in Double. Nil for different lengths.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count else { return nil }
        var sum = 0.0
        for index in a.indices { sum += Double(a[index]) * Double(b[index]) }
        return Float(sum)
    }

    /// The windows to embed for each speaker of `words` (Android's `Voiceprints.select`), in samples of an audio of
    /// `totalSamples` at `sampleRate`. A speaker's own voice is the diarizer slot that overlaps their words most; their
    /// runs of consecutive words lose every stretch where another slot speaks, then 200 ms at each edge; what is left
    /// under 1.5 s goes, and longer pieces are cut into windows of at most 10 s. The longest windows are taken first,
    /// alternating between the recording's thirds, up to 45 s; a speaker with less than 4 s gets none.
    public static func select(turns: [DiarizerTurn], words: [Word], sampleRate: Int, totalSamples: Int) -> [SpeakerWindows] {
        precondition(sampleRate > 0 && totalSamples >= 0)
        let valid = turns.filter { $0.endMs > $0.startMs && $0.speaker >= 0 }
        var speakers: [String] = []
        var spoken: [String: [Word]] = [:]
        for word in words {
            if spoken[word.speaker] == nil { speakers.append(word.speaker) }
            spoken[word.speaker, default: []].append(word)
        }
        var slots: [Int] = []
        var bySlot: [Int: [DiarizerTurn]] = [:]
        for turn in valid {
            if bySlot[turn.speaker] == nil { slots.append(turn.speaker) }
            bySlot[turn.speaker, default: []].append(turn)
        }
        // The diarizer slot that most overlaps a document speaker's words is that speaker's own voice.
        var own: [String: Int] = [:]
        for speaker in speakers {
            var best: (slot: Int, ms: Int64)?
            for slot in slots {
                let ms = spoken[speaker, default: []].reduce(Int64(0)) { sum, word in
                    sum + bySlot[slot, default: []].reduce(Int64(0)) { $0 + overlap(word.startMs, word.endMs, $1) }
                }
                if ms > 0, best == nil || ms > best!.ms { best = (slot, ms) }
            }
            own[speaker] = best?.slot
        }
        var runs: [(speaker: String, start: Int64, end: Int64)] = []
        for word in words where word.endMs > word.startMs {
            if let last = runs.indices.last, runs[last].speaker == word.speaker {
                runs[last].end = max(runs[last].end, word.endMs)
            } else {
                runs.append((word.speaker, word.startMs, word.endMs))
            }
        }
        let totalMs = Int64(totalSamples) * 1000 / Int64(sampleRate)
        var order: [String] = []
        var spans: [String: [(start: Int64, end: Int64)]] = [:]
        for run in runs {
            if spans[run.speaker] == nil { order.append(run.speaker) }
            spans[run.speaker, default: []].append((run.start, run.end))
        }
        var result: [SpeakerWindows] = []
        for speaker in order {
            let others = valid.filter { $0.speaker != own[speaker] }
            let segments = spans[speaker, default: []].flatMap { clean($0.start, $0.end, others) }.flatMap { piece in
                let s = piece.start + edgeTrimMs, e = piece.end - edgeTrimMs
                guard e - s >= minSegmentMs else { return [(start: Int64, end: Int64)]() }
                let parts = (e - s + maxWindowMs - 1) / maxWindowMs
                return (0..<parts).map { (start: s + (e - s) * $0 / parts, end: s + (e - s) * ($0 + 1) / parts) }
            }
            // Longest first, alternating between the recording's thirds so the print is not one moment.
            var thirds = (0...2).map { third in
                segments.filter { self.third($0, totalMs) == third }
                    .sorted { ($0.start - $0.end, $0.start) < ($1.start - $1.end, $1.start) }
            }
            var chosen: [(start: Int64, end: Int64)] = []
            var budget = Int64(maxSecondsPerSpeaker * 1000)
            outer: while budget > 0, thirds.contains(where: { !$0.isEmpty }) {
                for index in thirds.indices {
                    guard !thirds[index].isEmpty else { continue }
                    let (s, e) = thirds[index].removeFirst()
                    let end = min(e, s + budget)
                    if end - s >= minSegmentMs {
                        chosen.append((s, end))
                        budget -= end - s
                    }
                    if budget < minSegmentMs {
                        budget = 0
                        break outer
                    }
                }
            }
            guard Double(chosen.reduce(Int64(0)) { $0 + $1.end - $1.start }) >= minSecondsPerSpeaker * 1000 else { continue }
            let windows = chosen.sorted { $0.start < $1.start }.map { s, e in
                PrintWindow(clamp(s * Int64(sampleRate) / 1000, totalSamples), clamp(e * Int64(sampleRate) / 1000, totalSamples))
            }.filter { $0.endSample > $0.startSample }
            if !windows.isEmpty { result.append(SpeakerWindows(speaker, windows)) }
        }
        return result
    }

    private static func overlap(_ start: Int64, _ end: Int64, _ turn: DiarizerTurn) -> Int64 {
        max(0, min(end, turn.endMs) - max(start, turn.startMs))
    }

    private static func third(_ segment: (start: Int64, end: Int64), _ totalMs: Int64) -> Int {
        guard totalMs > 0 else { return 0 }
        return Int(min(max((segment.start + segment.end) / 2 * 3 / totalMs, 0), 2))
    }

    private static func clamp(_ sample: Int64, _ total: Int) -> Int { Int(min(max(sample, 0), Int64(total))) }

    /// The parts of `start..<end` where no turn of `others` is active.
    private static func clean(_ start: Int64, _ end: Int64, _ others: [DiarizerTurn]) -> [(start: Int64, end: Int64)] {
        var pieces = [(start: start, end: end)]
        for turn in others {
            pieces = pieces.flatMap { piece -> [(start: Int64, end: Int64)] in
                if turn.endMs <= piece.start || turn.startMs >= piece.end { return [piece] }
                var kept: [(start: Int64, end: Int64)] = []
                if turn.startMs > piece.start { kept.append((piece.start, turn.startMs)) }
                if turn.endMs < piece.end { kept.append((turn.endMs, piece.end)) }
                return kept
            }
        }
        return pieces
    }
}

/// Where the voice-clip cache keeps its clips: `work/clips.pcm` in a job, memory in a test.
public protocol ClipStore: AnyObject, PcmSource, Sendable {
    func append(_ samples: ArraySlice<Float>) throws
}

/// At most 45 seconds per speaker of clean speech for the voiceprints, on disk, whatever the recording's length
/// (Android's `VoiceClipCache`). Each window of the job adds the windows `Voiceprints.select` finds there; a speaker
/// past the eighth is not kept, and an earlier window's overlap (its first second) is not taken again.
public final class VoiceClipCache {
    public struct Invalid: Error, Hashable, Sendable {}

    private let audio: any ClipStore
    private var order: [String] = []
    private var selected: [String: [PrintWindow]] = [:]
    private var used: [String: Int] = [:]

    /// `restored` is a checkpoint's `voiceClips`; it must fit `audio` and the budget.
    public init(audio: any ClipStore, restored: [String: [PrintWindow]]? = nil) throws(Invalid) {
        self.audio = audio
        for (id, windows) in (restored ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard windows.allSatisfy({ $0.startSample >= 0 && $0.endSample > $0.startSample && $0.endSample <= audio.sampleCount })
            else { throw Invalid() }
            order.append(id)
            selected[id] = windows
            used[id] = windows.reduce(0) { $0 + $1.endSample - $1.startSample }
        }
        guard selected.count <= SpeakerBudget.maxSpeakers,
              used.values.allSatisfy({ $0 <= SpeakerBudget.secondsPerSpeaker * Limits.asrRate }) else { throw Invalid() }
    }

    /// The clips of each speaker, in samples of the clip store.
    public var windows: [String: [PrintWindow]] { selected }

    /// The clips of window `chunk` that starts at `startMs` of the recording: `turns` and `words` are on its clock.
    public func accept(_ chunk: PcmAudio, turns: [DiarizerTurn], words: [Word], startMs: Int64) throws {
        let candidates = Voiceprints.select(turns: turns, words: words, sampleRate: chunk.sampleRate,
                                            totalSamples: chunk.samples.count)
        for candidate in candidates {
            let speaker = candidate.speaker
            if selected[speaker] == nil, selected.count >= SpeakerBudget.maxSpeakers { continue }
            var remaining = Int(Voiceprints.maxSecondsPerSpeaker * Double(chunk.sampleRate)) - (used[speaker] ?? 0)
            for window in candidate.windows {
                let start = max(window.startSample, startMs > 0 ? chunk.sampleRate : 0)
                let end = min(window.endSample, start + remaining)
                if Int64(end - start) < Voiceprints.minSegmentMs * Int64(chunk.sampleRate) / 1000 { continue }
                let offset = audio.sampleCount
                try audio.append(chunk.samples[start..<end])
                if selected[speaker] == nil { order.append(speaker) }
                selected[speaker, default: []].append(PrintWindow(offset, audio.sampleCount))
                used[speaker, default: 0] += end - start
                remaining -= end - start
                if remaining <= 0 { break }
            }
        }
    }
}

/// The speaker members of a streaming job's checkpoint (Android's `diarizer`, `speakerPrefix`, `speakerFailure`,
/// `clipSamples` and `voiceClips`): the diarizer's state, the run's speaker id prefix, whether the speakers failed, how
/// many samples of `work/clips.pcm` the clips use, and the clips of each speaker.
public struct SpeakerCheckpoint: Codable, Hashable, Sendable {
    public var prefix: String
    public var failed: Bool
    public var diarizer: DiarizerState?
    public var clipSamples: Int
    public var voiceClips: [String: [PrintWindow]]

    public init(prefix: String, failed: Bool = false, diarizer: DiarizerState? = nil, clipSamples: Int = 0,
                voiceClips: [String: [PrintWindow]] = [:]) {
        self.prefix = prefix; self.failed = failed; self.diarizer = diarizer; self.clipSamples = clipSamples
        self.voiceClips = voiceClips
    }

    /// A checkpoint no run could have saved: a window past the clips, or more clips than the budget.
    public var valid: Bool {
        clipSamples >= 0 && voiceClips.count <= SpeakerBudget.maxSpeakers
            && voiceClips.values.allSatisfy { $0.allSatisfy { $0.startSample >= 0 && $0.endSample > $0.startSample
                && $0.endSample <= clipSamples } }
            && (diarizer?.cache.count ?? 0) <= SpeakerBudget.diarizerStateFloats
    }
}
