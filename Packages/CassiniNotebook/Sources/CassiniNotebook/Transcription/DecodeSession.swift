import CassiniCore
import Foundation

/// One recognizer call over `length` samples of `audio` from `start`, between `headPad` and `tailPad` zero samples.
/// Its times are relative to the decoded input, head padding included.
public protocol WordDecoder {
    func decode(_ audio: PcmAudio, start: Int, length: Int, headPad: Int, tailPad: Int) throws -> [DecodedWord]
}

/// The decodes of one recording on one recognizer. Fed span by span to report batch progress. Android's
/// `DecodeSession`; a decoder error (`TIMINGS`, a native failure) ends the session.
public final class DecodeSession {
    /// Recorded context for retrying a span that decoded to nothing: the detector's silence decision interval.
    public static let retryContextMs = 500

    private let decoder: any WordDecoder
    private let audio: PcmAudio
    private let policy: DecodePolicy
    private let rate: Int
    private let total: Int
    private var previousEnd = 0
    private var settled: [DecodedWord] = []
    /// The span being decoded: its windows so far, shown before the span is settled.
    private var pending: [DecodedWord] = []
    public var words: [DecodedWord] { settled + pending }

    public init(decoder: any WordDecoder, audio: PcmAudio, policy: DecodePolicy) {
        self.decoder = decoder; self.audio = audio; self.policy = policy
        rate = audio.sampleRate
        total = audio.samples.count
    }

    private func ms(_ samples: Int) -> Int64 { SpeechWindows.floorMs(samples, sampleRate: rate) }

    /// One decoder call over `length` recording samples from `start`, between `headPad` and `tailPad` zeros.
    private func decode(_ start: Int, _ length: Int, _ headPad: Int = 0, _ tailPad: Int = 0) throws -> [DecodedWord] {
        try decoder.decode(audio, start: start, length: length, headPad: headPad, tailPad: tailPad)
    }

    public func whole() throws -> [Word] { try decode(0, total).map(\.word) }

    /// The windows of one source span, each decoded, placed on the recording clock and reconciled at its seam.
    private func segment(_ span: SampleSpan, detected: Bool, onDecoded: (Int) throws -> Void = { _ in }) throws -> [DecodedWord] {
        var merged: [DecodedWord] = []
        for (index, window) in SpeechWindows.windows(span.length, sampleRate: rate, vadSegment: detected, policy: policy).enumerated() {
            let windowOffsetMs = ms(span.start) + ms(window.span.start)
            var decoded: [DecodedWord] = []
            for chunk in window.chunks {
                let placed = WordGate.offsetDecoderWords(try decode(span.start + chunk.span.start, chunk.span.length, chunk.headPad, chunk.tailPad),
                                                         offsetMs: windowOffsetMs + ms(chunk.span.start - window.span.start),
                                                         headPaddingMs: ms(chunk.headPad))
                // A final token can be stamped inside the synthetic tail: keep it at the real boundary for the gate to judge.
                decoded += WordGate.clampWordsToTimelineEnd(placed, endMs: windowOffsetMs + ms(chunk.span.end - window.span.start),
                                                            paddedTailMs: SpeechWindows.ceilMs(chunk.tailPad, sampleRate: rate))
                pending = SeamMerge.merge(merged, decoded, firstWindow: index == 0, windowStartMs: windowOffsetMs,
                                          overlapMs: ms(window.overlap)) { $0.word }
                try onDecoded(span.start + chunk.span.end)
            }
            merged = SeamMerge.merge(merged, decoded, firstWindow: index == 0, windowStartMs: windowOffsetMs,
                                     overlapMs: ms(window.overlap)) { $0.word }
            pending = merged
            try onDecoded(span.start + window.span.end)
        }
        return merged
    }

    /// A span of speech. When the policy keeps spans whole, a long one is first cut at quiet points so no
    /// decode runs long. Neighbouring pieces are decoded with recorded context past the cut and reconciled there.
    public func speech(_ span: SampleSpan, onDecoded: (Int) throws -> Void) throws {
        let pieces = policy.preserveSpan ? SpeechWindows.quietPieces(audio.samples, span, sampleRate: rate) : [span]
        if pieces.count == 1 { return try piece(span, onDecoded: onDecoded) }
        let context = SpeechWindows.samples(SpeechWindows.cutContextMs, sampleRate: rate)
        var previous: SampleSpan?
        for (index, cut) in pieces.enumerated() {
            let source = SampleSpan(index == 0 ? cut.start : cut.start - context, index == pieces.count - 1 ? cut.end : cut.end + context)
            let found = try segment(source, detected: true, onDecoded: onDecoded)
            pending = []
            if let previous {
                settled = SeamMerge.splice(settled, found, overlapStartMs: ms(source.start), overlapMs: ms(previous.end - source.start)) { $0.word }
            } else {
                settled += found
            }
            previous = source
            // Shows the joined words at once; until here the piece was listed after the words it overlaps.
            try onDecoded(source.end)
        }
        previousEnd = span.end
        try onDecoded(span.end)
    }

    /// One piece of speech, with recorded context when the policy asks for it.
    private func piece(_ span: SampleSpan, onDecoded: (Int) throws -> Void) throws {
        var source = policy.contextMs > 0
            ? SpeechWindows.context(start: span.start, end: span.end, total: total, sampleRate: rate, contextMs: policy.contextMs) : span
        var found = try segment(source, detected: true, onDecoded: onDecoded)
        // A tight crop can make an utterance-normalised decode emit only blanks. Retry once with real context,
        // keeping only words that overlap the detected speech.
        if found.isEmpty && policy.preserveSpan {
            let retry = SpeechWindows.context(start: span.start, end: span.end, total: total, sampleRate: rate, contextMs: Self.retryContextMs)
            if retry.start < source.start || retry.end > source.end {
                found = WordGate.wordsOverlappingSpeech(try segment(retry, detected: true), startMs: ms(span.start), endMs: ms(min(total, span.end)))
                source = retry
            }
        }
        pending = []
        if policy.contextMs > 0 && previousEnd > source.start {
            settled = SeamMerge.merge(settled, found, firstWindow: false, windowStartMs: ms(source.start),
                                      overlapMs: ms(previousEnd - source.start)) { $0.word }
        } else {
            settled += found
        }
        previousEnd = source.end
        try onDecoded(span.end)
    }

    /// Dense audio without a detector: when two overlapping windows disagree entirely, each instant keeps one owner.
    public func fixed(onDecoded: (Int) throws -> Void) throws {
        var previous: SampleSpan?
        for span in SpeechWindows.fixed(total, sampleRate: rate) {
            let found = try segment(span, detected: false, onDecoded: onDecoded)
            pending = []
            settled = SeamMerge.merge(settled, found, firstWindow: previous == nil, windowStartMs: ms(span.start),
                                      overlapMs: ms(SpeechWindows.overlap(previous, span)), midpointOnDisagreement: true) { $0.word }
            previous = span
            try onDecoded(span.end)
        }
    }
}
