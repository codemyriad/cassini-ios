import XCTest
import AVFoundation
import CassiniEngine
import CassiniNotebook
import CassiniSherpa

/// The speaker package's native smoke test: streaming Sortformer and CAM++ through the sherpa-onnx C API, on a
/// two-speaker mix of FLEURS clips (A, B, A again; scripts/fetch-speaker-fixture.py). Opt-in and skipped unless the
/// build links the runtime (CASSINI_SHERPA_LOCAL=1) and the environment names the models; scripts/speaker-smoke.sh
/// runs it on a simulator.
///
/// Environment (xcodebuild passes TEST_RUNNER_<name> through as <name>):
///   CASSINI_SPEAKER_MODELS   a model root with the revision directories of the diarizer and CAM++
///                            (models/<id>/<source_sha256>/, as scripts/fetch-ci-models.py writes them)
///   CASSINI_SPEAKER_AUDIO    fleurs-two-speakers.wav; its .json beside it lists the three spans
///   CASSINI_SPEAKER_OUT      a file to write the measurements to as JSON
final class SpeakerSmokeTests: XCTestCase {
    private static let rate = 16_000
    /// IncrementalTranscript's window and the step between windows (28 s with a 2 s carry), as the job feeds them.
    private static let windowSamples = 448_000
    private static let stepSamples = 416_000

    private struct Span: Decodable { let speaker: String; let startMs: Int64; let endMs: Int64 }
    private struct Fixture: Decodable { let durationMs: Int64; let spans: [Span] }

    func testSortformerStreamsTwoSpeakersAndCamPlusTellsThemApart() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without CASSINI_SHERPA_LOCAL")
        let models = try XCTUnwrap(environment["CASSINI_SPEAKER_MODELS"].map { URL(fileURLWithPath: $0) },
                                   "set CASSINI_SPEAKER_MODELS")
        let audioURL = try XCTUnwrap(environment["CASSINI_SPEAKER_AUDIO"].map { URL(fileURLWithPath: $0) })
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: audioURL.deletingPathExtension()
            .appendingPathExtension("json")))
        let sortformer = URL(fileURLWithPath: ModelCatalog.diarization.path(in: models, ModelCatalog.diarizationModel.name))
        let campplus = URL(fileURLWithPath: ModelCatalog.voiceprint.path(in: models, ModelCatalog.voiceprintModel.name))
        let samples = try readMono16k(audioURL)
        XCTAssertEqual(Int64(samples.count) * 1000 / Int64(Self.rate), fixture.durationMs)
        var report: [String: Any] = ["platform": "iOS Simulator (not a device measurement)",
                                     "audioSeconds": Double(samples.count) / Double(Self.rate)]

        // Streaming over the job's windows. After the first window the state is saved and a second diarizer resumes
        // from it; both then take the same windows and must agree.
        var chunks: [(startMs: Int64, audio: PcmAudio)] = []
        var start = 0
        while true {
            let end = min(samples.count, start + Self.windowSamples)
            chunks.append((Int64(start) * 1000 / Int64(Self.rate), PcmAudio(Array(samples[start..<end]), sampleRate: Self.rate)))
            if end == samples.count { break }
            start += Self.stepSamples
        }
        XCTAssertGreaterThanOrEqual(chunks.count, 2, "the fixture spans more than one window")
        let started = Date()
        let first = try SortformerStream(model: sortformer)
        let firstChunk = try first.process(chunks[0].audio, startMs: 0)
        XCTAssertFalse(firstChunk.isEmpty, "turns in the first window")
        let saved = first.state
        XCTAssertFalse(saved.cache.isEmpty, "a cache after one chunk")
        XCTAssertLessThanOrEqual(saved.cache.count, SpeakerBudget.diarizerStateFloats)
        let resumed = try SortformerStream(model: sortformer, restored: saved)
        XCTAssertEqual(resumed.saveState(), saved.cache, "the restored cache saves the same floats")
        XCTAssertEqual(resumed.turns, first.turns)
        XCTAssertEqual(resumed.elapsedMs, saved.elapsedMs)
        for chunk in chunks.dropFirst() {
            let a = try first.process(chunk.audio, startMs: chunk.startMs)
            let b = try resumed.process(chunk.audio, startMs: chunk.startMs)
            XCTAssertEqual(a, b, "window at \(chunk.startMs) ms")
        }
        XCTAssertEqual(first.turns, resumed.turns, "the resumed diarizer ends where the original does")
        report["streamSeconds"] = Date().timeIntervalSince(started)
        report["stateFloats"] = saved.cache.count
        report["streamTurns"] = first.turns.map { [$0.startMs, $0.endMs, Int64($0.speaker)] }

        // A cache over the cap, or one the model does not take, is refused.
        XCTAssertThrowsError(try SortformerStream(model: sortformer, restored: SortformerState(
            cache: [Float](repeating: 0, count: SpeakerBudget.diarizerStateFloats + 1), elapsedMs: 0, turns: []))) {
            XCTAssertEqual($0 as? SherpaError, .restoreFailed)
        }
        XCTAssertThrowsError(try SortformerStream(model: sortformer, restored: SortformerState(cache: [1, 2, 3], elapsedMs: 0, turns: []))) {
            XCTAssertEqual($0 as? SherpaError, .restoreFailed)
        }
        // A chunk longer than 28 000 ms (Android's integer durationMs, so 16 samples more) or not at 16 kHz is refused
        // before the native call.
        let before = first.turns
        XCTAssertThrowsError(try first.process(PcmAudio([Float](repeating: 0, count: Self.windowSamples + 16), sampleRate: Self.rate), startMs: 0))
        XCTAssertThrowsError(try first.process(PcmAudio([Float](repeating: 0, count: 480), sampleRate: 48_000), startMs: 0))
        XCTAssertEqual(first.turns, before)

        // Two speakers, A's slot in both of A's spans and another slot in B's; turns in time order.
        let streamed = slotsBySpan(first.turns, fixture.spans)
        report["streamSlots"] = streamed.map { $0.map(String.init) ?? "none" }
        XCTAssertEqual(Set(first.turns.map(\.speaker)).count, 2, "speakers: \(first.turns)")
        XCTAssertEqual(streamed[0], streamed[2], "A keeps its slot across windows")
        XCTAssertNotEqual(streamed[0], streamed[1], "B is someone else")
        XCTAssertNotNil(streamed[1])
        XCTAssertGreaterThanOrEqual(first.turns.count, 3)
        XCTAssertEqual(first.turns.map(\.startMs), first.turns.map(\.startMs).sorted())

        // The whole recording in one call.
        let wholeStart = Date()
        let whole = try SortformerStream.turns(PcmAudio(samples, sampleRate: Self.rate), model: sortformer)
        report["wholeSeconds"] = Date().timeIntervalSince(wholeStart)
        report["wholeTurns"] = whole.map { [$0.startMs, $0.endMs, Int64($0.speaker)] }
        XCTAssertEqual(Set(whole.map(\.speaker)).count, 2, "whole-file speakers: \(whole)")
        let wholeSlots = slotsBySpan(whole, fixture.spans)
        XCTAssertEqual(wholeSlots[0], wholeSlots[2])
        XCTAssertNotEqual(wholeSlots[0], wholeSlots[1])

        // CAM++ prints of each span, edges trimmed by 200 ms as Android's selection does.
        let ms = { (value: Int64) in Int(value) * Self.rate / 1000 }
        let printWindows = Dictionary(uniqueKeysWithValues: fixture.spans.enumerated().map { index, span in
            ("\(span.speaker)\(index)", [PrintWindow(ms(span.startMs + 200), ms(span.endMs - 200))])
        })
        let printStart = Date()
        let prints = try VoiceprintExtractor.compute(model: campplus, audio: PcmAudio(samples, sampleRate: Self.rate),
                                                     windows: printWindows) {}
        report["voiceprintSeconds"] = Date().timeIntervalSince(printStart)
        let a0 = try XCTUnwrap(prints["A0"]), b1 = try XCTUnwrap(prints["B1"]), a2 = try XCTUnwrap(prints["A2"])
        XCTAssertEqual(a0.vector.count, 512, "CAM++ dimension (ModelCatalog.voiceprintDim)")
        for print in [a0, b1, a2] {
            XCTAssertEqual(print.vector.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-4, "L2-normalised")
        }
        XCTAssertEqual(b1.seconds, Double(fixture.spans[1].endMs - fixture.spans[1].startMs - 400) / 1000, accuracy: 0.001)
        let same = cosine(a0.vector, a2.vector), different = cosine(a0.vector, b1.vector)
        report["cosineSameSpeaker"] = same
        report["cosineDifferentSpeakers"] = different
        XCTAssertGreaterThan(same, 0.99, "the same clip twice")
        XCTAssertLessThan(different, 0.72, "below Android's automatic-naming threshold")
        let empty = try VoiceprintExtractor.compute(model: campplus, audio: PcmAudio(samples, sampleRate: Self.rate),
                                                    windows: ["none": [PrintWindow(10, 10)]]) {}
        XCTAssertTrue(empty.isEmpty, "a speaker without samples gets no print")
        struct Stop: Error {}
        XCTAssertThrowsError(try VoiceprintExtractor.compute(model: campplus, audio: PcmAudio(samples, sampleRate: Self.rate),
                                                             windows: printWindows) { throw Stop() })

        let memory = MemorySample.now()
        report["footprintMiB"] = Double(memory.footprintBytes) / 1_048_576
        report["peakMiB"] = Double(memory.peakFootprintBytes) / 1_048_576
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let text = String(decoding: json, as: UTF8.self)
        print("CASSINI_SPEAKERS_BEGIN\n\(text)\nCASSINI_SPEAKERS_END")
        if let out = environment["CASSINI_SPEAKER_OUT"] { try json.write(to: URL(fileURLWithPath: out)) }
    }

    // MARK: - helpers

    /// For each span, the slot with the most overlap, or nil.
    private func slotsBySpan(_ turns: [DiarizerTurn], _ spans: [Span]) -> [Int?] {
        spans.map { span in
            var overlap: [Int: Int64] = [:]
            for turn in turns {
                let shared = min(span.endMs, turn.endMs) - max(span.startMs, turn.startMs)
                if shared > 0 { overlap[turn.speaker, default: 0] += shared }
            }
            return overlap.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
        }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    private func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, Double(Self.rate))
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.rate), channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
