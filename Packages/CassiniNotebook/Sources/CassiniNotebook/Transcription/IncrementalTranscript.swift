import CassiniCore
import Foundation

/// What an `IncrementalTranscript` restores from: checkpoint.json `recognition.chunks`. `window` holds the samples
/// from `start`; `end` is the last decoded sample; `words` are the words so far.
public struct IncrementalState: Hashable, Sendable {
    public var start: Int64
    public var end: Int64
    public var window: [Float]
    public var words: [Word]
    public init(start: Int64, end: Int64, window: [Float], words: [Word]) {
        self.start = start; self.end = end; self.window = window; self.words = words
    }

    /// A restored state that no run could have saved.
    public struct Invalid: Error, Hashable, Sendable {}

    /// Android's restore checks: the window fits, and `start <= end <= start + window` within the longest recording.
    public func validate() throws(Invalid) {
        let limit = Int64(Limits.maxSamples)
        guard window.count <= IncrementalTranscript.windowSamples, start >= 0, (0...limit).contains(end),
              start + Int64(window.count) <= limit, end <= start + Int64(window.count), end >= start else { throw Invalid() }
    }
}

/// Consumes the reader's borrowed buffers synchronously. Recognition starts after 28 s of audio,
/// before the file has been read to its end. Two seconds of recorded overlap protect words at
/// boundaries; the seam reconciliation keeps each word once on the recording clock.
/// Only a window is copied here.
public final class IncrementalTranscript {
    /// The longest window a checkpoint can hold: 28 s at the recognition rate.
    public static let windowSamples = 28 * Limits.asrRate
    /// Recorded audio carried into the next window.
    public static let overlapSamples = 2 * Limits.asrRate

    private let rate = Limits.asrRate
    private let recognize: (PcmAudio, Int64) throws -> Transcript
    private var window = [Float](repeating: 0, count: IncrementalTranscript.windowSamples)
    private let overlap = IncrementalTranscript.overlapSamples
    private var size = 0
    private var start: Int64 = 0
    private var decodedEnd: Int64 = 0
    private var finished = false
    private var words: [Word] = []
    public var positionSamples: Int64 { start + Int64(size) }
    public var doneMs: Int64 { decodedEnd * 1000 / Int64(rate) }

    /// `recognize` gets each window and its start on the recording clock, and returns its words on the window's clock.
    public init(restored: IncrementalState? = nil, recognize: @escaping (PcmAudio, Int64) throws -> Transcript) throws(IncrementalState.Invalid) {
        self.recognize = recognize
        if let restored {
            try restored.validate()
            start = restored.start
            decodedEnd = restored.end
            window.replaceSubrange(0..<restored.window.count, with: restored.window)
            size = restored.window.count
            words = restored.words
        }
    }

    public func checkpoint() -> IncrementalState {
        IncrementalState(start: start, end: decodedEnd, window: Array(window[0..<size]), words: words)
    }

    /// Takes the first `count` of `samples`; decodes each full window before returning. A cancelled task stops
    /// before the next window is decoded.
    public func accept(_ samples: [Float], count: Int, onProgress: (Int64, [Word]) throws -> Void = { _, _ in }) throws {
        precondition(!finished)
        precondition((0...samples.count).contains(count))
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let n = min(window.count - size, count - offset)
            window.replaceSubrange(size..<(size + n), with: samples[offset..<(offset + n)])
            size += n
            offset += n
            if size == window.count {
                try decode()
                try onProgress(decodedEnd * 1000 / Int64(rate), words)
                window.replaceSubrange(0..<overlap, with: window[(size - overlap)..<size])
                start += Int64(size - overlap)
                size = overlap
            }
        }
    }

    private func decode() throws {
        let offsetMs = start * 1000 / Int64(rate)
        let recognized = try recognize(PcmAudio(Array(window[0..<size]), sampleRate: rate), offsetMs)
        let found = recognized.words.map { $0.with(startMs: $0.startMs + offsetMs, endMs: $0.endMs + offsetMs) }
        words = start == 0 ? found : SeamMerge.splice(words, found, overlapStartMs: offsetMs, overlapMs: Int64(overlap) * 1000 / Int64(rate))
        decodedEnd = start + Int64(size)
    }

    public func finish() throws -> Transcript {
        precondition(!finished)
        finished = true
        // An exact window end leaves just its already-recognized overlap; do not decode it twice.
        if start + Int64(size) > decodedEnd { try decode() }
        return Transcript(words)
    }
}
