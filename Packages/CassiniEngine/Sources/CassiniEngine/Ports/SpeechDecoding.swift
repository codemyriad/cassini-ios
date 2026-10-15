import CassiniCore
import Foundation
import CassiniNotebook

/// The files of an installed Parakeet TDT transducer: three ONNX graphs and the token table (Android's `ParakeetFiles`).
public struct ParakeetFiles: Hashable, Sendable {
    public let encoder: URL
    public let decoder: URL
    public let joiner: URL
    public let tokens: URL

    public init(encoder: URL, decoder: URL, joiner: URL, tokens: URL) {
        self.encoder = encoder; self.decoder = decoder; self.joiner = joiner; self.tokens = tokens
    }

    /// The INT8 export's file names inside `directory`.
    public init(directory: URL) {
        self.init(encoder: directory.appendingPathComponent("encoder.int8.onnx"),
                  decoder: directory.appendingPathComponent("decoder.int8.onnx"),
                  joiner: directory.appendingPathComponent("joiner.int8.onnx"),
                  tokens: directory.appendingPathComponent("tokens.txt"))
    }

    /// The installed Ultra under the models' `root` (`ModelCatalog.parakeet`).
    public init(root: URL) { self.init(directory: ModelCatalog.parakeet.directory(in: root)) }

    /// Whether every file exists. The native loader ends the process on a missing file instead of failing.
    public func present() -> Bool { [encoder, decoder, joiner, tokens].allSatisfy(ModelFiles.isFile) }
}

/// The recognizer configuration 0.1.0 used, unchanged (Android's `ParakeetDecoder.config`): decoding results depend on
/// every value. The native adapter copies it field by field into sherpa-onnx's C struct.
public struct ParakeetConfig: Hashable, Sendable {
    public var sampleRate: Int32 = 16_000
    public var featureDim: Int32 = 128
    /// sherpa-onnx's C API has no dither member; its feature extractor defaults to 0, as Android sets it.
    public var dither: Float = 0
    public var encoder: String
    public var decoder: String
    public var joiner: String
    public var tokens: String
    public var modelType = "nemo_transducer"
    public var provider = "cpu"
    public var numThreads: Int32 = 2
    public var decodingMethod = "greedy_search"

    public init(_ files: ParakeetFiles) {
        encoder = files.encoder.path; decoder = files.decoder.path; joiner = files.joiner.path; tokens = files.tokens.path
    }
}

/// The speech detector's configuration (Android's `SileroDetector.config`): the desktop's defaults, `SpeechFeed`'s
/// constants. Silero is a tiny stateful model run per 32 ms window: fastest on one CPU thread.
public struct SileroConfig: Hashable, Sendable {
    public var model: String
    public var threshold: Float = SpeechFeed.threshold
    public var minSilenceDuration: Float = SpeechFeed.minSilenceSeconds
    public var minSpeechDuration: Float = SpeechFeed.minSpeechSeconds
    public var windowSize = Int32(SpeechFeed.window)
    public var maxSpeechDuration: Float = SpeechFeed.maxSpeechSeconds
    public var sampleRate = Int32(SpeechFeed.sampleRate)
    public var numThreads: Int32 = 1
    public var provider = "cpu"
    public var debug = false
    /// The detector's sample buffer, as sherpa-onnx's own default.
    public var bufferSeconds: Float = 60

    public init(model: URL) { self.model = model.path }
}

/// What one native decode returns: the text and the per-token arrays (`tokens_arr`, `timestamps`, `durations`), in
/// seconds from the start of the samples passed in.
public struct RecognizedTokens: Hashable, Sendable {
    public var text: String
    public var tokens: [String]
    public var timestamps: [Float]
    public var durations: [Float]
    public init(text: String, tokens: [String], timestamps: [Float], durations: [Float]) {
        self.text = text; self.tokens = tokens; self.timestamps = timestamps; self.durations = durations
    }
}

/// One native Parakeet recognizer (CassiniSherpa's `ParakeetDecoder`). Not thread-safe: the thread that created it
/// decodes with it and releases it.
public protocol SpeechDecoding: AnyObject {
    /// Decodes 16 kHz mono samples in one call.
    func decode(_ samples: [Float]) throws -> RecognizedTokens
}

/// One native Silero detector (CassiniSherpa's `SileroDetector`), fed by `SpeechFeed`. Owned by one thread.
public protocol SpeechDetecting: AnyObject, SpeechFeed.Stream {}

/// Makes the native recognizer and detector. The app passes CassiniSherpa's; tests pass fakes. Both throw when the
/// runtime is not linked or the model cannot be loaded.
public struct SpeechRuntime: Sendable {
    public var makeDecoder: @Sendable (ParakeetConfig) throws -> any SpeechDecoding
    public var makeDetector: @Sendable (SileroConfig) throws -> any SpeechDetecting

    public init(makeDecoder: @escaping @Sendable (ParakeetConfig) throws -> any SpeechDecoding,
                makeDetector: @escaping @Sendable (SileroConfig) throws -> any SpeechDetecting) {
        self.makeDecoder = makeDecoder; self.makeDetector = makeDetector
    }
}

/// The decode rules' `WordDecoder` over a native recognizer (Android's `ParakeetDecoder.decode`): pads the samples,
/// decodes them and builds the words from the tokens. A result with text but no tokens cannot be timed: `TIMINGS`.
/// `cancelled` is asked before every decode; when it says so the decode throws `CancellationError`.
public final class SpeechWordDecoder: WordDecoder {
    private let recognizer: any SpeechDecoding
    private let cancelled: () -> Bool
    /// Time spent in the recognizer, in nanoseconds.
    public private(set) var decodeNanoseconds: UInt64 = 0

    public init(_ recognizer: any SpeechDecoding, cancelled: @escaping () -> Bool = { false }) {
        self.recognizer = recognizer; self.cancelled = cancelled
    }

    public func decode(_ audio: PcmAudio, start: Int, length: Int, headPad: Int, tailPad: Int) throws -> [DecodedWord] {
        if cancelled() { throw CancellationError() }
        let samples: [Float]
        if headPad == 0, tailPad == 0, start == 0, length == audio.samples.count {
            samples = audio.samples
        } else {
            var padded = [Float](repeating: 0, count: headPad + length + tailPad)
            padded.replaceSubrange(headPad..<(headPad + length), with: audio.samples[start..<(start + length)])
            samples = padded
        }
        let began = DispatchTime.now().uptimeNanoseconds
        let result = try recognizer.decode(samples)
        decodeNanoseconds += DispatchTime.now().uptimeNanoseconds - began
        try Self.requireTimings(result)
        return try TokenWords.timedWordsFromTokens(result.tokens, timestamps: result.timestamps, durations: result.durations)
    }

    /// Android's rule: `text.isBlank() || tokens.isNotEmpty()`, else `TIMINGS`.
    public static func requireTimings(_ result: RecognizedTokens) throws(JobFailure) {
        guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !result.tokens.isEmpty else {
            throw .timings
        }
    }
}
