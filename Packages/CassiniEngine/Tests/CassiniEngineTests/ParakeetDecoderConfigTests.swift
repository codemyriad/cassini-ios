import CassiniCore
import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

/// The recognizer configuration 0.1.0 used, unchanged: decoding results depend on every value (Android's
/// `ParakeetDecoderConfigTest`). CassiniSherpa copies `ParakeetConfig` into the C struct field by field.
@Suite struct ParakeetDecoderConfigTests {
    private let files = ParakeetFiles(encoder: URL(fileURLWithPath: "/m/encoder.int8.onnx"),
                                      decoder: URL(fileURLWithPath: "/m/decoder.int8.onnx"),
                                      joiner: URL(fileURLWithPath: "/m/joiner.int8.onnx"),
                                      tokens: URL(fileURLWithPath: "/m/tokens.txt"))

    // ports: ParakeetDecoderConfigTest#configMatchesTheZeroOneRecognizer
    @Test func configMatchesTheZeroOneRecognizer() {
        let config = ParakeetConfig(files)
        #expect(config.sampleRate == 16_000)
        #expect(config.featureDim == 128)
        #expect(config.dither == 0)
        #expect(config.encoder == "/m/encoder.int8.onnx")
        #expect(config.decoder == "/m/decoder.int8.onnx")
        #expect(config.joiner == "/m/joiner.int8.onnx")
        #expect(config.tokens == "/m/tokens.txt")
        #expect(config.modelType == "nemo_transducer")
        #expect(config.provider == "cpu")
        #expect(config.numThreads == 2)
        #expect(config.decodingMethod == "greedy_search")
        #expect(ParakeetFiles(directory: URL(fileURLWithPath: "/m")) == files)
        // The manifest's paths in Ultra's revision directory (D4).
        #expect(ParakeetFiles(root: URL(fileURLWithPath: "/r")).encoder.path
                == "/r/models/parakeet-ultra-0.6b-int8/18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9/encoder.int8.onnx")
    }

    // ports: ParakeetDecoderConfigTest#presentNeedsEveryFile
    @Test func presentNeedsEveryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let install = ParakeetFiles(directory: directory)
        #expect(!install.present())
        for url in [install.encoder, install.decoder, install.joiner] { try Data().write(to: url) }
        #expect(!install.present())
        try FileManager.default.createDirectory(at: install.tokens, withIntermediateDirectories: false)
        #expect(!install.present(), "a directory is not a file")
        try FileManager.default.removeItem(at: install.tokens)
        try Data().write(to: install.tokens)
        #expect(install.present())
    }

    // ports: SileroDetectorConfigTest#configMatchesTheDesktopDefaults
    @Test func sileroConfigMatchesTheDesktopDefaults() {
        let config = SileroConfig(model: URL(fileURLWithPath: "/models/silero_vad.onnx"))
        #expect(config.model == "/models/silero_vad.onnx")
        #expect(config.threshold == 0.18)
        #expect(config.minSilenceDuration == 0.5)
        #expect(config.minSpeechDuration == 0.10)
        #expect(config.windowSize == 512)
        #expect(config.maxSpeechDuration == 25)
        #expect(config.sampleRate == 16_000)
        #expect(config.numThreads == 1)
        #expect(config.provider == "cpu")
        #expect(!config.debug)
    }

    /// A recognizer that returns what it is told and remembers what it heard.
    final class Recognizer: SpeechDecoding {
        var heard: [[Float]] = []
        var result: RecognizedTokens
        init(_ result: RecognizedTokens) { self.result = result }
        func decode(_ samples: [Float]) throws -> RecognizedTokens { heard.append(samples); return result }
    }

    @Test func theWordDecoderPadsTheSamplesAndTimesTheWords() throws {
        let recognizer = Recognizer(RecognizedTokens(text: " Ciao mondo", tokens: ["▁Ci", "ao", "▁mondo"],
                                                     timestamps: [0.5, 0.6, 0.9], durations: [0.1, 0.2, 0.3]))
        let decoder = SpeechWordDecoder(recognizer)
        let audio = PcmAudio([1, 2, 3, 4, 5], sampleRate: 16_000)
        let words = try decoder.decode(audio, start: 1, length: 3, headPad: 2, tailPad: 1)
        #expect(recognizer.heard == [[0, 0, 2, 3, 4, 0]])
        #expect(words.map(\.word) == [Word("spk_1", 500, 800, "Ciao"), Word("spk_1", 900, 1_200, "mondo")])
        _ = try decoder.decode(audio, start: 0, length: 5, headPad: 0, tailPad: 0)
        #expect(recognizer.heard.last == [1, 2, 3, 4, 5], "the whole input as it is")
    }

    // ports: ParakeetDecoder.decode's rule `result.text.isBlank() || result.tokens.isNotEmpty()`
    @Test func textWithoutTokensCannotBeTimed() throws {
        let audio = PcmAudio([0, 0], sampleRate: 16_000)
        let blank = SpeechWordDecoder(Recognizer(RecognizedTokens(text: "  ", tokens: [], timestamps: [], durations: [])))
        #expect(try blank.decode(audio, start: 0, length: 2, headPad: 0, tailPad: 0).isEmpty)
        let untimed = SpeechWordDecoder(Recognizer(RecognizedTokens(text: "ciao", tokens: [], timestamps: [], durations: [])))
        #expect(throws: JobFailure.timings) { try untimed.decode(audio, start: 0, length: 2, headPad: 0, tailPad: 0) }
        let mismatched = SpeechWordDecoder(Recognizer(RecognizedTokens(text: "ciao", tokens: ["▁ciao"], timestamps: [0, 1], durations: [0])))
        #expect(throws: JobFailure.timings) { try mismatched.decode(audio, start: 0, length: 2, headPad: 0, tailPad: 0) }
    }

    @Test func aCancelledDecoderStopsBeforeTheNativeCall() {
        let recognizer = Recognizer(RecognizedTokens(text: "", tokens: [], timestamps: [], durations: []))
        let decoder = SpeechWordDecoder(recognizer, cancelled: { true })
        #expect(throws: CancellationError.self) {
            try decoder.decode(PcmAudio([0], sampleRate: 16_000), start: 0, length: 1, headPad: 0, tailPad: 0)
        }
        #expect(recognizer.heard.isEmpty)
    }
}
