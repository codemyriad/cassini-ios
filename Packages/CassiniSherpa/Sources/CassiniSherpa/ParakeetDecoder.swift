import Foundation
import CassiniEngine
import CassiniNotebook
#if canImport(SherpaOnnxC)
import SherpaOnnxC
#endif

public enum SherpaError: Error, Equatable {
    /// This build does not link the native runtime (CASSINI_SHERPA_LOCAL was not set, or not an iOS build).
    case notLinked
    /// A model file is missing; the native loader would end the process.
    case missingFiles
    /// The native recognizer or detector could not be created.
    case createFailed
}

/// Whether this build links the sherpa-onnx C API.
public enum SherpaRuntime {
    public static var isLinked: Bool {
        #if canImport(SherpaOnnxC)
        true
        #else
        false
        #endif
    }

    /// The native recognizer and detector for `ParakeetTranscriber`; both throw `notLinked` without the runtime.
    public static let speech = SpeechRuntime(makeDecoder: { try ParakeetDecoder(config: $0) },
                                             makeDetector: { try SileroDetector(config: $0) })
}

/// Duplicates C strings that live until `body` returns: the create calls copy what they keep.
func withCStrings<Result>(_ strings: [String], _ body: ([UnsafePointer<CChar>]) throws -> Result) rethrows -> Result {
    let copies = strings.map { strdup($0)! }
    defer { copies.forEach { free($0) } }
    return try body(copies.map { UnsafePointer($0) })
}

/// Whether a file is there (and not a directory): the native loaders end the process on a missing file.
func isFile(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
}

/// One native Parakeet recognizer over the sherpa-onnx C API, configured by `ParakeetConfig` (Android's
/// `ParakeetDecoder.config`). Not thread-safe: the thread that creates it decodes with it and releases it.
public final class ParakeetDecoder: SpeechDecoding, @unchecked Sendable {
    #if canImport(SherpaOnnxC)
    private let recognizer: OpaquePointer
    #endif

    /// `debug` makes sherpa-onnx print the encoder's metadata to standard error while it loads.
    public init(config: ParakeetConfig, debug: Bool = false) throws {
        #if canImport(SherpaOnnxC)
        guard [config.encoder, config.decoder, config.joiner, config.tokens].allSatisfy(isFile) else {
            throw SherpaError.missingFiles
        }
        let created = withCStrings([config.encoder, config.decoder, config.joiner, config.tokens, config.provider,
                                    config.modelType, config.decodingMethod]) { strings -> OpaquePointer? in
            var native = SherpaOnnxOfflineRecognizerConfig()
            native.feat_config.sample_rate = config.sampleRate
            native.feat_config.feature_dim = config.featureDim
            native.model_config.transducer.encoder = strings[0]
            native.model_config.transducer.decoder = strings[1]
            native.model_config.transducer.joiner = strings[2]
            native.model_config.tokens = strings[3]
            native.model_config.provider = strings[4]
            native.model_config.model_type = strings[5]
            native.model_config.num_threads = config.numThreads
            native.model_config.debug = debug ? 1 : 0
            native.decoding_method = strings[6]
            return SherpaOnnxCreateOfflineRecognizer(&native)
        }
        guard let created else { throw SherpaError.createFailed }
        recognizer = created
        #else
        throw SherpaError.notLinked
        #endif
    }

    /// The installed files with the 0.1.0 configuration.
    public convenience init(files: ParakeetFiles, debug: Bool = false) throws {
        try self.init(config: ParakeetConfig(files), debug: debug)
    }

    /// Decodes 16 kHz mono samples in one call.
    public func decode(_ samples: [Float]) -> RecognizedTokens {
        #if canImport(SherpaOnnxC)
        let stream = SherpaOnnxCreateOfflineStream(recognizer)
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, 16_000, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            return RecognizedTokens(text: "", tokens: [], timestamps: [], durations: [])
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        let r = result.pointee
        let count = Int(max(0, r.count))
        let text = r.text.map { String(cString: $0) } ?? ""
        let tokens = (0..<count).map { i in r.tokens_arr.flatMap { $0[i] }.map { String(cString: $0) } ?? "" }
        let timestamps = r.timestamps.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
        let durations = r.durations.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
        return RecognizedTokens(text: text, tokens: tokens, timestamps: timestamps, durations: durations)
        #else
        RecognizedTokens(text: "", tokens: [], timestamps: [], durations: [])
        #endif
    }

    deinit {
        #if canImport(SherpaOnnxC)
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
        #endif
    }
}

/// One native Silero detector over the sherpa-onnx C API, configured by `SileroConfig` (Android's `SileroDetector`)
/// and fed by `SpeechFeed`. Not thread-safe: one thread owns it.
public final class SileroDetector: SpeechDetecting, @unchecked Sendable {
    #if canImport(SherpaOnnxC)
    private let vad: OpaquePointer
    #endif

    public init(config: SileroConfig) throws {
        #if canImport(SherpaOnnxC)
        guard isFile(config.model) else { throw SherpaError.missingFiles }
        let created = withCStrings([config.model, config.provider]) { strings -> OpaquePointer? in
            var native = SherpaOnnxVadModelConfig()
            native.silero_vad.model = strings[0]
            native.silero_vad.threshold = config.threshold
            native.silero_vad.min_silence_duration = config.minSilenceDuration
            native.silero_vad.min_speech_duration = config.minSpeechDuration
            native.silero_vad.window_size = config.windowSize
            native.silero_vad.max_speech_duration = config.maxSpeechDuration
            native.sample_rate = config.sampleRate
            native.num_threads = config.numThreads
            native.provider = strings[1]
            native.debug = config.debug ? 1 : 0
            return SherpaOnnxCreateVoiceActivityDetector(&native, config.bufferSeconds)
        }
        guard let created else { throw SherpaError.createFailed }
        vad = created
        #else
        throw SherpaError.notLinked
        #endif
    }

    public func reset() {
        #if canImport(SherpaOnnxC)
        SherpaOnnxVoiceActivityDetectorReset(vad)
        #endif
    }

    public func acceptWaveform(_ window: [Float]) {
        #if canImport(SherpaOnnxC)
        window.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count)) }
        #endif
    }

    public func empty() -> Bool {
        #if canImport(SherpaOnnxC)
        SherpaOnnxVoiceActivityDetectorEmpty(vad) != 0
        #else
        true
        #endif
    }

    public func front() -> SpeechFeed.Segment {
        #if canImport(SherpaOnnxC)
        guard let segment = SherpaOnnxVoiceActivityDetectorFront(vad) else { return SpeechFeed.Segment(0, []) }
        defer { SherpaOnnxDestroySpeechSegment(segment) }
        let s = segment.pointee
        let samples = s.samples.map { Array(UnsafeBufferPointer(start: $0, count: Int(max(0, s.n)))) } ?? []
        return SpeechFeed.Segment(Int(s.start), samples)
        #else
        SpeechFeed.Segment(0, [])
        #endif
    }

    public func pop() {
        #if canImport(SherpaOnnxC)
        SherpaOnnxVoiceActivityDetectorPop(vad)
        #endif
    }

    public func flush() {
        #if canImport(SherpaOnnxC)
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        #endif
    }

    deinit {
        #if canImport(SherpaOnnxC)
        SherpaOnnxDestroyVoiceActivityDetector(vad)
        #endif
    }
}
