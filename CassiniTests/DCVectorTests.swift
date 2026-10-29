import XCTest
import AVFoundation
import CryptoKit
import CassiniEngine
import CassiniInference
import CassiniNotebook
import CassiniSherpa

/// D26.1 through the real Silero detector and Parakeet Ultra. Opt-in and skipped unless the build links the runtime
/// (CASSINI_SHERPA_LOCAL=1) and the environment names the vectors and the models; scripts/sherpa-bench.sh runs it.
///
/// The shared vector `dc-quiet-jfk-v1` is the D11 JFK input made quiet (about 34 LSB AC RMS) over the failing
/// microphone's -2060 offset, with a control without the offset. iOS resamples with `AVAudioConverter` and its detector
/// threshold is 0.18, so the desktop's exact segments do not apply, and neither does its "no segment without the
/// filter": at 0.18 the offset makes Silero find spans the control does not have, where at 0.5 it found none. What
/// holds on iOS is that the offset makes no difference once filtered. Parakeet hears no words at that level even
/// without an offset, so the words are checked at the failing microphone's own level instead: JFK at 1/8 (about 540
/// LSB) over the same offset, against the same audio without it.
///
/// Environment (xcodebuild passes TEST_RUNNER_<name> through as <name>):
///   CASSINI_DC_VECTOR            coordination `ux-draft/dc`, with `../whistle/pipeline-input-48k.wav` beside it
///   CASSINI_PARAKEET_MODEL_ROOT  a model root with parakeet-ultra/ and vad/ and their markers (read only)
final class DCVectorTests: XCTestCase {
    private static let offset: Float = -2060.0 / 32768
    private static let files = [
        "dc/dc-quiet-jfk-v1.wav": "071f051241d394587c85463272e9414f133ee18c4bb835d1382b662e4154efda",
        "dc/dc-quiet-jfk-v1-control.wav": "e31ed958621a39baf1d33dab6d10798695b8319e78fcaa1cb672cdb43c5f7830",
        "whistle/pipeline-input-48k.wav": "b7062e41f452236812aa3417a68eb50372a99851ab4a18d1c4f4f99e2e2e3963",
    ]

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// `ux-draft/`, with the committed files checked.
    private func drafts() throws -> URL {
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without CASSINI_SHERPA_LOCAL")
        let folder = try XCTUnwrap(environment["CASSINI_DC_VECTOR"].map { URL(fileURLWithPath: $0) }, "set CASSINI_DC_VECTOR")
        let drafts = folder.deletingLastPathComponent()
        for (path, sha) in Self.files {
            XCTAssertEqual(try sha256(drafts.appendingPathComponent(path)), sha, "\(path) is the committed file")
        }
        return drafts
    }

    private func modelRoot() throws -> URL {
        try XCTUnwrap(environment["CASSINI_PARAKEET_MODEL_ROOT"].map { URL(fileURLWithPath: $0) }, "set CASSINI_PARAKEET_MODEL_ROOT")
    }

    func testOnceFilteredTheSharedVectorsOffsetMakesNoDifferenceToTheDetector() throws {
        let drafts = try drafts()
        let detector = try detector(in: try modelRoot())
        let vector = try read16k(drafts.appendingPathComponent("dc/dc-quiet-jfk-v1.wav"))
        let control = try read16k(drafts.appendingPathComponent("dc/dc-quiet-jfk-v1-control.wav"))
        let vectorRaw = try spans(detector, vector), controlRaw = try spans(detector, control)
        let vectorFiltered = try spans(detector, vector, filtered: true)
        let controlFiltered = try spans(detector, control, filtered: true)
        print("DC_VECTOR quiet raw \(vectorRaw), control raw \(controlRaw), filtered \(vectorFiltered), control filtered \(controlFiltered)")
        XCTAssertNotEqual(vectorRaw, controlRaw, "unfiltered, the offset changes what the detector finds")
        XCTAssertFalse(vectorFiltered.isEmpty)
        XCTAssertEqual(vectorFiltered, controlFiltered, "filtered, the offset makes no difference (assertion c)")
    }

    func testAtTheFailingMicrophonesLevelAnOffsetChangesNeitherSpansNorWords() async throws {
        let drafts = try drafts()
        let models = try modelRoot()
        let detector = try detector(in: models)
        let level = try read16k(drafts.appendingPathComponent("whistle/pipeline-input-48k.wav")).map { $0 / 8 }
        let offset = level.map { $0 + Self.offset }
        let clean = try spans(detector, level, filtered: true)
        let offsetRaw = try spans(detector, offset), offsetFiltered = try spans(detector, offset, filtered: true)
        print("DC_VECTOR mic level filtered \(clean), with offset raw \(offsetRaw), filtered \(offsetFiltered)")
        XCTAssertNotEqual(offsetRaw, clean, "unfiltered, the offset changes what the detector finds")
        XCTAssertEqual(offsetFiltered, clean, "filtered, it makes no difference")

        let transcriber = ParakeetTranscriber(models: .init(root: models), runtime: SherpaRuntime.speech)
        var words: [[String]] = []
        for samples in [level, offset] {
            let url = try write16k(samples)
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try await transcriber.transcribe(TranscriptionRequest(url: url, language: "en-US", resume: nil,
                                                                               allowDownload: false)) { _ in }
            words.append(result.segments.flatMap(\.draftWords).map(\.text))
        }
        print("DC_VECTOR mic level words \(words[0].joined(separator: " "))")
        XCTAssertTrue(words[0].joined(separator: " ").contains("ask not what your country can do for you"))
        XCTAssertEqual(words[1], words[0], "the same words over the offset")
    }

    private func detector(in models: URL) throws -> SileroDetector {
        try SileroDetector(config: SileroConfig(model: URL(fileURLWithPath: ModelCatalog.vad.path(in: models, ModelCatalog.sileroVad.name))))
    }

    /// The detector's spans over `samples` (through `SpeechInputFilter` when `filtered`), as [start, end) at 16 kHz.
    private func spans(_ detector: SileroDetector, _ samples: [Float], filtered: Bool = false) throws -> [[Int]] {
        var filter = SpeechInputFilter()
        var found: [[Int]] = []
        try SpeechFeed.feed(detector, filtered ? filter(samples) : samples) {
            found.append([$0.startSample, $0.startSample + $0.samples.count])
        }
        return found
    }

    /// `url` as 16 kHz mono floats through `AVAudioConverter`, as the app reads every recording.
    private func read16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: try format()))
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: try format(), frameCapacity: capacity))
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if given { state.pointee = .endOfStream; return nil }
            given = true
            state.pointee = .haveData
            return input
        }
        XCTAssertNotEqual(status, .error, "\(String(describing: error))")
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// `samples` as a 16 kHz float CAF in the temporary directory.
    private func write16k(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: try format().settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: try format(), frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample }
        try file.write(from: buffer)
        return url
    }

    private func format() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
