import Foundation
import Testing
import CassiniEngine
import CassiniNotebook
import CassiniSherpa

/// The host side of CassiniSherpa: `swift test` on macOS links no native runtime, so neither native object can be made.
/// The configurations they copy are tested in CassiniEngine (`ParakeetDecoderConfigTests`, `SileroDetectorConfigTests`).
@Test func theMacBuildLinksNoNativeRuntime() {
    #if os(macOS)
    #expect(!SherpaRuntime.isLinked)
    #expect(throws: SherpaError.notLinked) { try ParakeetDecoder(files: ParakeetFiles(directory: URL(fileURLWithPath: "/nonexistent"))) }
    #expect(throws: SherpaError.notLinked) { try SileroDetector(config: SileroConfig(model: URL(fileURLWithPath: "/nonexistent"))) }
    #expect(throws: SherpaError.notLinked) { try SherpaRuntime.speech.makeDecoder(ParakeetConfig(ParakeetFiles(directory: URL(fileURLWithPath: "/m")))) }
    #endif
}

@Test func presentNeedsEveryFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = ParakeetFiles(directory: directory)
    #expect([files.encoder, files.decoder, files.joiner, files.tokens].map(\.lastPathComponent)
        == ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"])
    for url in [files.encoder, files.decoder, files.joiner] {
        #expect(!files.present())
        try Data().write(to: url)
    }
    #expect(!files.present())
    try FileManager.default.createDirectory(at: files.tokens, withIntermediateDirectories: false)
    #expect(!files.present(), "a directory is not a file")
    try FileManager.default.removeItem(at: files.tokens)
    try Data().write(to: files.tokens)
    #expect(files.present())
}

/// Android's `SortformerStream.config` and `VoiceprintExtractor` settings, checked on the host.
@Test func theSpeakerConfigsAreAndroids() {
    let model = URL(fileURLWithPath: "/models/speaker-models/nemotron-3-diarization.int8.onnx")
    let sortformer = SortformerConfig(model: model)
    #expect(sortformer.model == model)
    #expect(sortformer.threads == 2)
    #expect(sortformer.provider == "cpu")
    #expect((sortformer.threshold, sortformer.minDurationOn, sortformer.minDurationOff) == (0.5, 0.3, 0.5))
    #expect((sortformer.clusters, sortformer.clusteringThreshold) == (-1, 0.5))
    let voiceprint = VoiceprintConfig(model: URL(fileURLWithPath: "/models/speaker-models/voiceprint-campplus.onnx"))
    #expect((voiceprint.threads, voiceprint.provider) == (2, "cpu"))
    #expect(SortformerStream.maxChunkMs == 28_000)
}

/// Without the runtime nothing native is reached, and an empty selection needs no model.
@Test func theSpeakerModelsNeedTheRuntime() throws {
    #if os(macOS)
    let model = URL(fileURLWithPath: "/nonexistent.onnx")
    #expect(throws: SherpaError.notLinked) { try SortformerStream(model: model) }
    #expect(throws: SherpaError.notLinked) { try SortformerStream.turns(PcmAudio([0], sampleRate: 16_000), model: model) }
    #expect(throws: SherpaError.invalidAudio) { try SortformerStream.turns(PcmAudio([0], sampleRate: 48_000), model: model) }
    #expect(throws: SherpaError.notLinked) {
        try VoiceprintExtractor.compute(model: model, audio: PcmAudio([0], sampleRate: 16_000), windows: ["a": [PrintWindow(0, 1)]]) {}
    }
    #endif
    #expect(try VoiceprintExtractor.compute(model: URL(fileURLWithPath: "/nonexistent.onnx"),
                                            audio: PcmAudio([], sampleRate: 16_000), windows: [:]) {}.isEmpty)
}

// ports: SortformerStreamTest#invalidNativeConfigurationIsRejectedBeforeLoadingModels
@Test func invalidNativeConfigurationIsRejectedBeforeLoadingModels() {
    for threads: Int32 in [0, -1] {
        #expect(throws: SherpaError.invalidAudio) {
            try SortformerStream.turns(PcmAudio([0], sampleRate: 16_000), model: URL(fileURLWithPath: ""), threads: threads)
        }
    }
}

/// The speaker runtime the app's `SpeakerAnalyzer` uses says whether it is linked, and throws without it.
@Test func theSpeakerRuntimeSaysWhetherItIsLinked() {
    #expect(SherpaRuntime.speakers.linked == SherpaRuntime.isLinked)
    #if os(macOS)
    #expect(throws: SherpaError.notLinked) { try SherpaRuntime.speakers.makeDiarizer(URL(fileURLWithPath: "/m"), nil) }
    #endif
}
