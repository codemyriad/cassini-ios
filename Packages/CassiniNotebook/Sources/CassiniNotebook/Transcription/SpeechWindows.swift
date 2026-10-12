import Foundation

/// Samples `start..<end` at the recording's own rate.
public struct Span: Hashable, Sendable {
    public var start: Int
    public var end: Int
    public init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
    public var length: Int { end - start }
    public func shifted(by offset: Int) -> Span { Span(start + offset, end + offset) }
}

/// Window arithmetic for the windowed decode, from Android's `SpeechWindows`. Apple's analyzer finds its own speech
/// segments, so iOS keeps only the parts that do not depend on a voice detector: reading the file in fixed blocks,
/// where a resumed run starts, and how far apart checkpoints are.
public enum SpeechWindows {
    /// Audio is read from the file in blocks this long.
    public static let blockMs = 1_000
    /// A resumed run starts this long before the checkpoint, so the analyzer hears the word that ends there whole.
    public static let resumeOverlapMs: Int64 = 1_000
    /// A checkpoint is saved once this much more audio is final than the last one covered.
    public static let checkpointMs: Int64 = 30_000
    /// And at most this often in time, so a fast decode of a long file does not rewrite a large checkpoint all the time.
    public static let checkpointMinIntervalMs: Int64 = 10_000

    public static func samples(_ ms: Int, sampleRate: Int) -> Int { Int(Int64(ms) * Int64(sampleRate) / 1000) }
    /// The first frame at or after `ms` in a file of any rate.
    public static func frame(atMs ms: Int64, sampleRate: Double) -> Int64 { Int64((Double(ms) * sampleRate / 1000).rounded(.up)) }

    /// Floor, as source offsets are placed on the timeline.
    public static func floorMs(_ samples: Int, sampleRate: Int) -> Int64 { Int64(samples) * 1000 / Int64(sampleRate) }

    /// Ceiling, so a timeline clamp tolerates every sample.
    public static func ceilMs(_ samples: Int, sampleRate: Int) -> Int64 {
        guard samples > 0, sampleRate > 0 else { return 0 }
        return (Int64(samples) * 1000 + Int64(sampleRate) - 1) / Int64(sampleRate)
    }

    /// Samples `next` shares with `previous`; 0 for the first window or when they do not meet.
    public static func overlap(_ previous: Span?, _ next: Span) -> Int {
        previous.map { max(0, $0.end - next.start) } ?? 0
    }

    /// A span widened by `contextMs` of recording on each side, clipped to the recording.
    public static func context(start: Int, end: Int, total: Int, sampleRate: Int, contextMs: Int) -> Span {
        let context = samples(contextMs, sampleRate: sampleRate)
        return Span(max(0, start - context), min(total, end + context))
    }

    /// Fixed sliding windows over `total` samples; only the last may be shorter.
    public static func fixed(total: Int, sampleRate: Int, windowMs: Int = 15_000, overlapMs: Int = 500) -> [Span] {
        precondition(sampleRate > 0)
        return slide(total: total, window: samples(windowMs, sampleRate: sampleRate),
                     overlap: samples(overlapMs, sampleRate: sampleRate))
    }

    /// The blocks a run reads from `startSample` to the end of a file of `total` samples, back to back.
    public static func blocks(from startSample: Int, total: Int, sampleRate: Int, blockMs: Int = blockMs) -> [Span] {
        let start = min(max(0, startSample), total)
        return fixed(total: total - start, sampleRate: sampleRate, windowMs: blockMs, overlapMs: 0).map { $0.shifted(by: start) }
    }

    /// Where a run that resumes from `doneMs` starts reading.
    public static func resumeStartMs(doneMs: Int64) -> Int64 { max(0, doneMs - resumeOverlapMs) }

    /// Whether a checkpoint is due: enough more audio is final than `savedMs` covered, and the last one was saved at
    /// least `checkpointMinIntervalMs` ago (`savedAt` nil when this run saved none yet).
    public static func checkpointDue(doneMs: Int64, savedMs: Int64, nowMs: Int64, savedAt: Int64?) -> Bool {
        guard doneMs - savedMs >= checkpointMs else { return false }
        return savedAt.map { nowMs - $0 >= checkpointMinIntervalMs } ?? true
    }

    /// Windows of `window` samples starting `overlap` before the previous end; a degenerate window covers everything.
    private static func slide(total: Int, window: Int, overlap: Int) -> [Span] {
        guard total > 0 else { return [] }
        guard window > 0, window < total else { return [Span(0, total)] }
        let stride = window - overlap > 0 ? window - overlap : window
        var out: [Span] = []
        var start = 0
        while start < total {
            if start + window >= total { out.append(Span(start, total)); break }
            out.append(Span(start, start + window))
            start += stride
        }
        return out
    }
}
