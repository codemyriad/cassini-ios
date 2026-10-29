import CassiniCore
import Foundation

/// Parakeet decoding of one stretch of audio cut into pieces, as the desktop pipeline does on a stock sherpa runtime
/// (gocassini transcribe/stt.go): Android's `Parakeet.transcribeWithDecoder`, over a `WordDecoder` and the speech
/// detector's feed, so it runs on the host against fakes.
public enum ParakeetDecode {
    /// State after a decode: `doneMs` of `totalMs` of the audio, `elapsedMs` since decoding began, and the provisional
    /// words.
    public struct Progress: Hashable, Sendable {
        public var doneMs: Int64
        public var totalMs: Int64
        public var elapsedMs: Int64
        public var words: [Word]
    }

    static let progressIntervalNs: UInt64 = 1_000_000_000

    /// Cuts by speech when `cutting` is SPEECH (then `detector` is required), at quiet points for QUIET, in fixed
    /// windows for FIXED, or not at all for WHOLE (audio up to `DecodeCutting.wholeMaxMs`, else `LONG`). `onProgress`
    /// runs on the calling thread after each decode, at most once a second; its words are provisional, because seams
    /// can still drop a duplicate and the energy gate runs once at the end. A decoder error ends the decode.
    /// `detectorInput` is what the detector hears instead of `audio`'s samples: the same stretch at 16 kHz through
    /// `SpeechInputFilter` (D26.1); the decoder and the gate always get `audio` raw.
    public static func transcribe(_ audio: PcmAudio, decoder: any WordDecoder, detector: (any SpeechFeed.Stream)?,
                                  detectorInput: [Float]? = nil,
                                  policy: DecodePolicy = .wholeSpans, cutting: DecodeCutting,
                                  nanoTime: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                                  onProgress: (Progress) throws -> Void = { _ in }) throws -> Transcript {
        if cutting == .whole {
            guard audio.durationMs <= DecodeCutting.wholeMaxMs else { throw JobFailure.long }
            let began = nanoTime()
            let transcript = Transcript(try DecodeSession(decoder: decoder, audio: audio, policy: policy).whole())
            try onProgress(Progress(doneMs: audio.durationMs, totalMs: audio.durationMs,
                                    elapsedMs: Int64((nanoTime() - began) / 1_000_000), words: transcript.words))
            return transcript
        }
        // The clock starts once the model is loaded, so speed and remaining time describe decoding alone.
        let began = nanoTime()
        let session = DecodeSession(decoder: decoder, audio: audio, policy: policy)
        // Recorded context makes a decode end past its speech span, so the position only ever moves forward.
        var reached = 0
        var reported: UInt64?
        func report(_ done: Int) throws {
            reached = max(reached, min(done, audio.samples.count))
            let now = nanoTime()
            // Each report copies every word so far: at most one a second keeps a long recording linear.
            guard reported.map({ now - $0 >= progressIntervalNs }) ?? true else { return }
            reported = now
            try onProgress(Progress(doneMs: SpeechWindows.floorMs(reached, sampleRate: audio.sampleRate),
                                    totalMs: audio.durationMs, elapsedMs: Int64((now - began) / 1_000_000),
                                    words: session.words.map(\.word)))
        }
        try report(0)
        var paddedTailMs: Int64 = 0
        switch cutting {
        case .speech:
            guard let detector else { preconditionFailure("SPEECH cutting needs the speech detector") }
            paddedTailMs = try SpeechFeed.scan(detector, audio, copy16k: detectorInput) { span in try session.speech(span, onDecoded: report) }
        case .quiet:
            try session.speech(SampleSpan(0, audio.samples.count), onDecoded: report)
        case .fixed, .whole:
            try session.fixed(onDecoded: report)
        }
        let transcript = Transcript(WordGate.finalizeTranscriptWords(audio, words: session.words, paddedTailMs: paddedTailMs))
        try onProgress(Progress(doneMs: audio.durationMs, totalMs: audio.durationMs,
                                elapsedMs: Int64((nanoTime() - began) / 1_000_000), words: transcript.words))
        return transcript
    }
}
