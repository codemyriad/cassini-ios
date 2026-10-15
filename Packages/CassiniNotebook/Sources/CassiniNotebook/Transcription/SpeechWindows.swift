import Foundation

/// Samples [start, end) at the recording's own rate.
public struct SampleSpan: Hashable, Sendable, CustomStringConvertible {
    public var start: Int
    public var end: Int
    public init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
    public var length: Int { end - start }
    public func shift(by: Int) -> SampleSpan { SampleSpan(start + by, end + by) }
    public var description: String { "Span(\(start), \(end))" }
}

/// Boundary choices for one speech span, in milliseconds so they hold at any sample rate.
/// The defaults are the desktop pipeline's policy for a stock sherpa runtime: 10 s windows with
/// 0.5 s overlap, spans up to 10.5 s kept whole, a terminal window of at least 5 s, and 0.5 s of
/// synthetic silence after each decode. `parakeetV3Reference` needs a patched native frontend.
public struct DecodePolicy: Hashable, Sendable {
    public var windowMs: Int
    public var overlapMs: Int
    public var graceMs: Int
    public var minTerminalMs: Int
    public var tailPaddingMs: Int
    public var headPaddingMs: Int
    public var contextMs: Int
    public var preserveSpan: Bool
    public var syntheticPadding: Bool

    public init(windowMs: Int = 10_000, overlapMs: Int = 500, graceMs: Int = 500, minTerminalMs: Int = 5_000,
                tailPaddingMs: Int = 500, headPaddingMs: Int = 0, contextMs: Int = 0,
                preserveSpan: Bool = false, syntheticPadding: Bool = true) {
        self.windowMs = windowMs; self.overlapMs = overlapMs; self.graceMs = graceMs; self.minTerminalMs = minTerminalMs
        self.tailPaddingMs = tailPaddingMs; self.headPaddingMs = headPaddingMs; self.contextMs = contextMs
        self.preserveSpan = preserveSpan; self.syntheticPadding = syntheticPadding
    }

    /// Whole detected utterance plus 30 ms of recorded context, and no synthetic silence: the reference frontend
    /// normalises over the entire input.
    public static let parakeetV3Reference = DecodePolicy(tailPaddingMs: 0, contextMs: 30, preserveSpan: true, syntheticPadding: false)
    /// What this app uses: each detected span decoded whole with the stock 0.5 s synthetic tail, long spans
    /// first cut by `SpeechWindows.quietPieces`. On a Pixel 8 with the stock frontend, 10 s windows left
    /// duplicated words at their seams (Android's docs/pixel8-results.md).
    public static let wholeSpans = DecodePolicy(preserveSpan: true)
}

/// One decoder call: `span` of the source with `headPad` zero samples before it and `tailPad` after it.
public struct DecodeChunk: Hashable, Sendable {
    public var span: SampleSpan
    public var headPad: Int
    public var tailPad: Int
    public init(_ span: SampleSpan, _ headPad: Int, _ tailPad: Int) { self.span = span; self.headPad = headPad; self.tailPad = tailPad }
}

/// One decode window. Its first `overlap` samples were also decoded by the previous window, so words
/// there are de-duplicated against it (0 for the first window). `chunks` cover the window back to back.
public struct DecodeWindow: Hashable, Sendable {
    public var span: SampleSpan
    public var overlap: Int
    public var chunks: [DecodeChunk]
    public init(_ span: SampleSpan, _ overlap: Int, _ chunks: [DecodeChunk]) { self.span = span; self.overlap = overlap; self.chunks = chunks }
}

/// DecodeWindow arithmetic of the desktop decoder, ported from Android's `SpeechWindows`. Every duration is converted with
/// the recording's actual sample rate. The checkpoint cadence at the end is iOS's own; the Apple Speech fallback's
/// block reading lives in `AppleSpeechWindows`.
public enum SpeechWindows {
    /// Emergency split for silence-free speech: an ONNX-safe decode length of 55 s of audio.
    public static let maxSafeMs = 55_000
    /// Non-VAD decodes shorter than this get 0.5 s of synthetic tail silence.
    public static let tailPadMinSeconds = 10

    /// A span up to this long is decoded whole. The detector's 25 s limit is a hint: spans close a little after it.
    public static let wholeSpanMs = 28_000
    /// A longer span is cut where it is quietest in this stretch after the previous cut.
    public static let cutFromMs = 20_000
    public static let cutToMs = 25_000
    /// Recorded audio decoded on each side of a forced cut, so a word the cut runs through is heard whole by both decodes.
    public static let cutContextMs = 1_000
    static let quietFrameMs = 30
    static let quietStepMs = 10

    public static func samples(_ ms: Int, sampleRate: Int) -> Int { Int(Int64(ms) * Int64(sampleRate) / 1000) }

    /// Sherpa's detector does not close a span at its maximum duration; it only becomes stricter, and over
    /// noise one span can run for minutes. A `span` longer than `wholeSpanMs` is cut at the quietest
    /// 30 ms between `cutFromMs` and `cutToMs` after the previous cut, so each decode stays short,
    /// progress keeps moving, and a cut falls between words where the recording allows it. The quietest
    /// frame can still be a closure inside a word, so the caller decodes `cutContextMs` of the recording
    /// past each cut on both sides and reconciles the two readings. The pieces cover the span back to back.
    public static func quietPieces(_ samples: [Float], _ span: SampleSpan, sampleRate: Int) -> [SampleSpan] {
        precondition(sampleRate > 0)
        let whole = Self.samples(wholeSpanMs, sampleRate: sampleRate)
        var out: [SampleSpan] = []
        var start = span.start
        while span.end - start > whole {
            let cut = quietest(samples, from: start + Self.samples(cutFromMs, sampleRate: sampleRate),
                               to: start + Self.samples(cutToMs, sampleRate: sampleRate), sampleRate: sampleRate)
            out.append(SampleSpan(start, cut))
            start = cut
        }
        if span.end > start { out.append(SampleSpan(start, span.end)) }
        return out
    }

    /// Centre of the lowest-energy frame inside [from, to), the earliest on a tie.
    private static func quietest(_ samples: [Float], from: Int, to: Int, sampleRate: Int) -> Int {
        let frame = max(1, Self.samples(quietFrameMs, sampleRate: sampleRate))
        let step = max(1, Self.samples(quietStepMs, sampleRate: sampleRate))
        var best = from
        var least = Double.greatestFiniteMagnitude
        var at = from
        samples.withUnsafeBufferPointer { buffer in
            while at + frame <= to {
                var energy = 0.0
                for i in at..<(at + frame) { energy += Double(buffer[i]) * Double(buffer[i]) }
                if energy < least { least = energy; best = at + frame / 2 }
                at += step
            }
        }
        return best
    }

    public static func maxSafeSamples(_ sampleRate: Int) -> Int { samples(maxSafeMs, sampleRate: sampleRate) }
    /// Floor, as the decoder places source offsets on the timeline.
    public static func floorMs(_ samples: Int, sampleRate: Int) -> Int64 { Int64(samples) * 1000 / Int64(sampleRate) }
    /// Ceiling, so a timeline clamp tolerates every padded sample.
    public static func ceilMs(_ samples: Int, sampleRate: Int) -> Int64 {
        samples <= 0 || sampleRate <= 0 ? 0 : (Int64(samples) * 1000 + Int64(sampleRate) - 1) / Int64(sampleRate)
    }

    /// Samples `next` shares with `previous`; 0 for the first window or when they do not meet.
    public static func overlap(_ previous: SampleSpan?, _ next: SampleSpan) -> Int { previous.map { max(0, $0.end - next.start) } ?? 0 }

    /// A VAD span widened by `contextMs` of real recording on each side, clipped to the recording.
    public static func context(start: Int, end: Int, total: Int, sampleRate: Int, contextMs: Int) -> SampleSpan {
        let context = samples(contextMs, sampleRate: sampleRate)
        return SampleSpan(max(0, start - context), min(total, end + context))
    }

    /// Decode windows for a VAD span of `total` samples, relative to its start. Long merged spans make
    /// Parakeet emit only a prefix, so they are cut into overlapping windows; a span at most one window
    /// plus grace stays whole, and a short terminal window is moved back to `DecodePolicy.minTerminalMs`
    /// so it carries useful context, keeping the exact overlap and gap-free coverage.
    public static func split(_ total: Int, sampleRate: Int, policy: DecodePolicy = DecodePolicy()) -> [SampleSpan] {
        precondition(sampleRate > 0)
        if total <= 0 { return [] }
        if policy.preserveSpan { return [SampleSpan(0, total)] }
        let window = samples(policy.windowMs, sampleRate: sampleRate)
        let overlap = samples(policy.overlapMs, sampleRate: sampleRate)
        if total <= window + samples(policy.graceMs, sampleRate: sampleRate) { return [SampleSpan(0, total)] }
        var bounds = slide(total, window: window, overlap: overlap)
        let last = bounds.count - 1
        let minTerminal = samples(policy.minTerminalMs, sampleRate: sampleRate)
        if last > 0 && bounds[last].length < minTerminal {
            bounds[last] = SampleSpan(total - minTerminal, total)
            bounds[last - 1].end = bounds[last].start + overlap
        }
        return bounds
    }

    /// Fixed sliding windows for dense audio decoded without VAD; only the last may be shorter.
    public static func fixed(_ total: Int, sampleRate: Int, windowMs: Int = 15_000, overlapMs: Int = 500) -> [SampleSpan] {
        precondition(sampleRate > 0)
        return slide(total, window: samples(windowMs, sampleRate: sampleRate), overlap: samples(overlapMs, sampleRate: sampleRate))
    }

    /// Synthetic tail silence for a decode when the policy does not set it: every VAD span ends at a
    /// detected boundary with its closing silence removed, and a short non-VAD decode needs context.
    public static func tailPadSamples(_ chunkSamples: Int, sampleRate: Int, vadSegment: Bool) -> Int {
        if chunkSamples <= 0 || sampleRate <= 0 { return 0 }
        if vadSegment || Int64(chunkSamples) < Int64(tailPadMinSeconds) * Int64(sampleRate) { return sampleRate / 2 }
        return 0
    }

    /// The decoder calls for one source span of `total` samples, relative to its start. A VAD span is
    /// split into windows first; every window is then cut at `maxSafeSamples` without overlap and
    /// padded by the policy. Without synthetic padding a chunk under 20 ms is skipped, because the
    /// reference frontend needs two 10 ms frames and aborts in native code on none.
    public static func windows(_ total: Int, sampleRate: Int, vadSegment: Bool, policy: DecodePolicy = DecodePolicy()) -> [DecodeWindow] {
        precondition(sampleRate > 0)
        if total <= 0 { return [] }
        let spans = vadSegment ? split(total, sampleRate: sampleRate, policy: policy) : []
        if spans.count <= 1 {
            return [DecodeWindow(SampleSpan(0, total), 0, chunks(total, sampleRate: sampleRate, vadSegment: vadSegment, policy: policy))]
        }
        var out: [DecodeWindow] = []
        for span in spans {
            for child in windows(span.length, sampleRate: sampleRate, vadSegment: true, policy: policy) {
                let shifted = child.span.shift(by: span.start)
                out.append(DecodeWindow(shifted, overlap(out.last?.span, shifted),
                                  child.chunks.map { DecodeChunk($0.span.shift(by: span.start), $0.headPad, $0.tailPad) }))
            }
        }
        return out
    }

    private static func chunks(_ total: Int, sampleRate: Int, vadSegment: Bool, policy: DecodePolicy) -> [DecodeChunk] {
        let limit = maxSafeSamples(sampleRate)
        var out: [DecodeChunk] = []
        var start = 0
        while start < total {
            let end = min(total, start + limit)
            let length = end - start
            if policy.syntheticPadding || Int64(length) * 1000 >= Int64(sampleRate) * 20 {
                let explicit = vadSegment || !policy.syntheticPadding
                out.append(DecodeChunk(SampleSpan(start, end),
                                 explicit ? samples(policy.headPaddingMs, sampleRate: sampleRate) : 0,
                                 explicit ? samples(policy.tailPaddingMs, sampleRate: sampleRate)
                                          : tailPadSamples(length, sampleRate: sampleRate, vadSegment: false)))
            }
            start = end
        }
        return out
    }

    /// Windows of `window` samples starting `overlap` before the previous end; a degenerate window covers everything.
    private static func slide(_ total: Int, window: Int, overlap: Int) -> [SampleSpan] {
        if total <= 0 { return [] }
        if window <= 0 || window >= total { return [SampleSpan(0, total)] }
        let stride = window - overlap > 0 ? window - overlap : window
        var out: [SampleSpan] = []
        var start = 0
        while start < total {
            if start + window >= total { out.append(SampleSpan(start, total)); break }
            out.append(SampleSpan(start, start + window))
            start += stride
        }
        return out
    }

    // MARK: - Checkpoint cadence (iOS)

    /// A checkpoint is saved once this much more audio is final than the last one covered.
    public static let checkpointMs: Int64 = 30_000
    /// And at most this often in time, so a fast decode of a long file does not rewrite a large checkpoint all the time.
    public static let checkpointMinIntervalMs: Int64 = 10_000

    /// Whether a checkpoint is due: enough more audio is final than `savedMs` covered, and the last one was saved at
    /// least `checkpointMinIntervalMs` ago (`savedAt` nil when this run saved none yet).
    public static func checkpointDue(doneMs: Int64, savedMs: Int64, nowMs: Int64, savedAt: Int64?) -> Bool {
        guard doneMs - savedMs >= checkpointMs else { return false }
        return savedAt.map { nowMs - $0 >= checkpointMinIntervalMs } ?? true
    }
}
