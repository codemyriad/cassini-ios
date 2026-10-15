import Foundation
#if canImport(SherpaOnnxC)
import SherpaOnnxC
#endif

/// The files of an installed Parakeet TDT transducer: three ONNX graphs and the token table.
public struct ParakeetFiles: Sendable, Equatable {
    public let encoder: URL
    public let decoder: URL
    public let joiner: URL
    public let tokens: URL

    /// The INT8 export's file names inside `directory`.
    public init(directory: URL) {
        encoder = directory.appendingPathComponent("encoder.int8.onnx")
        decoder = directory.appendingPathComponent("decoder.int8.onnx")
        joiner = directory.appendingPathComponent("joiner.int8.onnx")
        tokens = directory.appendingPathComponent("tokens.txt")
    }

    /// Whether every file exists. The native loader ends the process on a missing file instead of failing.
    public func present() -> Bool {
        [encoder, decoder, joiner, tokens].allSatisfy { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
        }
    }
}

/// What one decode returns: the text and the per-token arrays (`tokens_arr`, `timestamps`, `durations`), in seconds
/// from the start of the samples passed in.
public struct DecodedTokens: Sendable, Equatable {
    public let text: String
    public let tokens: [String]
    public let timestamps: [Float]
    public let durations: [Float]
}

public enum SherpaError: Error, Equatable {
    /// This build does not link the native runtime (CASSINI_SHERPA_LOCAL was not set, or not an iOS build).
    case notLinked
    /// A model file is missing; the native loader would end the process.
    case missingFiles
    /// The native recognizer could not be created.
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
}

/// One native Parakeet recognizer over the sherpa-onnx C API, configured as Android's `ParakeetDecoder.config`: 16 kHz,
/// 128 features, `nemo_transducer`, CPU with 2 threads, greedy search. Not thread-safe: one thread owns it.
public final class ParakeetDecoder: @unchecked Sendable {
    #if canImport(SherpaOnnxC)
    private let recognizer: OpaquePointer
    #endif

    /// `debug` makes sherpa-onnx print the encoder's metadata to standard error while it loads.
    public init(files: ParakeetFiles, threads: Int32 = 2, debug: Bool = false) throws {
        #if canImport(SherpaOnnxC)
        guard files.present() else { throw SherpaError.missingFiles }
        // The C strings live until the create call returns.
        let strings = [files.encoder.path, files.decoder.path, files.joiner.path, files.tokens.path,
                       "cpu", "nemo_transducer", "greedy_search"].map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 128
        config.model_config.transducer.encoder = UnsafePointer(strings[0])
        config.model_config.transducer.decoder = UnsafePointer(strings[1])
        config.model_config.transducer.joiner = UnsafePointer(strings[2])
        config.model_config.tokens = UnsafePointer(strings[3])
        config.model_config.provider = UnsafePointer(strings[4])
        config.model_config.model_type = UnsafePointer(strings[5])
        config.model_config.num_threads = threads
        config.model_config.debug = debug ? 1 : 0
        config.decoding_method = UnsafePointer(strings[6])
        guard let created = SherpaOnnxCreateOfflineRecognizer(&config) else { throw SherpaError.createFailed }
        recognizer = created
        #else
        throw SherpaError.notLinked
        #endif
    }

    /// Decodes 16 kHz mono samples in one call.
    public func decode(_ samples: [Float], sampleRate: Int32 = 16000) -> DecodedTokens {
        #if canImport(SherpaOnnxC)
        let stream = SherpaOnnxCreateOfflineStream(recognizer)
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            return DecodedTokens(text: "", tokens: [], timestamps: [], durations: [])
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        let r = result.pointee
        let count = Int(max(0, r.count))
        let text = r.text.map { String(cString: $0) } ?? ""
        let tokens = (0..<count).map { i in r.tokens_arr.flatMap { $0[i] }.map { String(cString: $0) } ?? "" }
        let timestamps = r.timestamps.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
        let durations = r.durations.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
        return DecodedTokens(text: text, tokens: tokens, timestamps: timestamps, durations: durations)
        #else
        DecodedTokens(text: "", tokens: [], timestamps: [], durations: [])
        #endif
    }

    deinit {
        #if canImport(SherpaOnnxC)
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
        #endif
    }
}
