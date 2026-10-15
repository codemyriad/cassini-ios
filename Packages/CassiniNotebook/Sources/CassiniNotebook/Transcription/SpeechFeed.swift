import Foundation

/// The feed loop of the Silero speech detector over a 16 kHz copy of the recording, configured and fed as the desktop
/// pipeline does on a stock sherpa runtime (gocassini transcribe/stt.go). Speech spans reach the caller in order, at
/// the recording's own rate, as soon as the detector closes them. The native detector sits behind `Stream`.
public enum SpeechFeed {
    /// The detector's rate.
    public static let sampleRate = 16_000

    /// A detected segment: `samples` at 16 kHz from index `startSample`.
    public struct Segment: Sendable {
        public var startSample: Int
        public var samples: [Float]
        public init(_ startSample: Int, _ samples: [Float]) { self.startSample = startSample; self.samples = samples }
    }

    /// The calls the feed loop makes, so the loop can be checked on the host without the native library.
    public protocol Stream {
        func reset()
        func acceptWaveform(_ window: [Float])
        func empty() -> Bool
        func front() -> Segment
        func pop()
        func flush()
    }

    /// Below Silero's stock 0.5 so 420-500 ms acknowledgements are not missed.
    public static let threshold: Float = 0.18
    public static let minSilenceSeconds: Float = 0.5
    public static let minSpeechSeconds: Float = 0.10
    public static let maxSpeechSeconds: Float = 25
    /// Samples per detector call at 16 kHz. Sherpa's flush never evaluates a buffered partial window.
    public static let window = 512
    /// Drain completed segments every 5 s of fed audio so the detector's buffer stays small.
    public static let drainEvery = sampleRate * 5

    /// Resets `stream` once, feeds exact `window`-sample windows of 16 kHz `samples`, zero-pads the last
    /// partial window, drains completed segments every `drainEvery` real samples fed, then flushes and
    /// drains the rest. Empty segments are skipped. Cancellation is checked at every drain. Returns the
    /// zeros appended to the last window, 0 when it was full: the detector heard that much synthetic tail.
    @discardableResult
    public static func feed(_ stream: any Stream, _ samples: [Float], onSegment: (Segment) throws -> Void) throws -> Int {
        func drain() throws {
            try Task.checkCancellation()
            while !stream.empty() {
                let segment = stream.front()
                stream.pop()
                if !segment.samples.isEmpty { try onSegment(segment) }
            }
        }
        stream.reset()
        var sinceDrain = 0
        var padding = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + window, samples.count)
            // A short final window keeps the zeros it was allocated with.
            padding = window - (end - offset)
            var chunk = [Float](repeating: 0, count: window)
            chunk.replaceSubrange(0..<(end - offset), with: samples[offset..<end])
            stream.acceptWaveform(chunk)
            sinceDrain += end - offset
            if sinceDrain >= drainEvery {
                sinceDrain = 0
                try drain()
            }
            offset += window
        }
        stream.flush()
        try drain()
        return padding
    }

    /// Feeds the 16 kHz copy of `audio` to `stream`, passes each span mapped to the recording to `onSpan`,
    /// and returns the zero padding of the last window in milliseconds, rounded up. Spans stop at the
    /// recording's end, so a caller clamping decoded words to the timeline needs this value to keep a
    /// word stamped inside that padding as a zero-length word at the end, as the desktop does.
    ///
    /// Android resamples here with its own windowed-sinc resampler. iOS reads every recording at 16 kHz through
    /// `AVAudioConverter`, so `audio` at 16 kHz is its own copy and any other rate needs `copy16k`.
    @discardableResult
    public static func scan(_ stream: any Stream, _ audio: PcmAudio, copy16k: [Float]? = nil,
                            onSpan: (SampleSpan) throws -> Void) throws -> Int64 {
        precondition(copy16k != nil || audio.sampleRate == sampleRate, "A recording not at 16 kHz needs its 16 kHz copy")
        let padding = try feed(stream, copy16k ?? audio.samples) { segment in
            if let span = recordingSpan(start: segment.startSample, length: segment.samples.count, rate: audio.sampleRate,
                                        recordingLength: audio.samples.count) {
                try onSpan(span)
            }
        }
        return SpeechWindows.ceilMs(padding, sampleRate: sampleRate)
    }

    /// Maps a segment of `length` samples at 16 kHz index `start` to the recording: start rounded down, end
    /// rounded up so no speech is cut, end clamped to `recordingLength` to drop the detector's zero padding.
    /// Nil when nothing of it lies inside the recording.
    public static func recordingSpan(start: Int, length: Int, rate: Int, recordingLength: Int) -> SampleSpan? {
        let vad = Int64(sampleRate)
        let first = Int64(start) * Int64(rate) / vad
        let last = min(Int64(recordingLength), ((Int64(start) + Int64(length)) * Int64(rate) + vad - 1) / vad)
        return first < last ? SampleSpan(Int(first), Int(last)) : nil
    }
}
