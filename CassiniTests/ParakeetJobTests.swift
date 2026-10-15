import XCTest
import AVFoundation
import CassiniEngine
import CassiniEngineTesting
import CassiniInference
import CassiniNotebook
import CassiniSherpa

/// A real Parakeet Ultra transcription job on the simulator, end to end: `TranscriptionJob` over `ParakeetTranscriber`
/// and CassiniSherpa's recognizer and detector, on FLEURS-it short, compared with the iOS golden. Opt-in and skipped
/// unless the build links the runtime (CASSINI_SHERPA_LOCAL=1) and the environment names the models and the clip;
/// scripts/sherpa-bench.sh runs it.
///
/// The golden is iOS's own (`Goldens/fleurs-it-short.ios.json`, arm64 simulator). Android's comes from the x86_64
/// emulator and the ONNX Runtime int8 kernels differ between the two (iOS runs the arm64 UDOT ones), so words and times
/// can differ slightly; the test reports the difference from Android's text and does not require it to be zero.
///
/// Environment (xcodebuild passes TEST_RUNNER_<name> through as <name>):
///   CASSINI_PARAKEET_MODEL_ROOT  a model root as scripts/fetch-ci-models.py writes it (parakeet-ultra/ and vad/ with
///                                their markers; read only, cloned into this app's caches)
///   CASSINI_PARAKEET_AUDIO       the FLEURS-it short clip
///   CASSINI_PARAKEET_GOLDEN      Android's fleurs-it-short.txt golden (optional, reported only)
///   CASSINI_PARAKEET_RECORD=1    write the iOS golden instead of comparing with it
final class ParakeetJobTests: XCTestCase {
    private static let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Goldens/fleurs-it-short.ios.json")

    func testAnUltraJobTranscribesFleursAsTheGoldenSays() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without CASSINI_SHERPA_LOCAL")
        let source = try XCTUnwrap(environment["CASSINI_PARAKEET_MODEL_ROOT"].map { URL(fileURLWithPath: $0) },
                                   "set CASSINI_PARAKEET_MODEL_ROOT")
        let clip = try XCTUnwrap(environment["CASSINI_PARAKEET_AUDIO"].map { URL(fileURLWithPath: $0) })
        let models = try cloneModels(from: source)
        XCTAssertTrue(ModelCatalog.parakeet.ready(in: models), "Ultra with its marker")
        XCTAssertTrue(ModelCatalog.vad.ready(in: models), "the speech detector with its marker")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-job-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = try NoteStore(root: root)
        var note = Note(id: UUID(), title: "FLEURS", audioFilename: "audio.wav")
        note.duration = try durationSeconds(clip)
        try await notes.save(note)
        try FileManager.default.copyItem(at: clip, to: notes.audioURL(for: note))

        let transcriber = ParakeetTranscriber(models: .init(root: models), runtime: SherpaRuntime.speech)
        let provenance = ProvenanceFiles(notes: notes)
        let job = TranscriptionJob(notes: notes, transcriber: transcriber, analyzer: FakeAnalyzer(),
                                   checkpoints: CheckpointFiles(notes: notes), provenance: provenance, host: Host(),
                                   clock: FakeClock())
        let started = Date()
        let outcome = await job.run(Job(noteID: note.id, seq: 1, kind: .transcribe, state: .running, enqueuedAt: Date()),
                                    stop: StopSignal()) { _ in }
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome, .done)

        let stored = await notes.note(note.id)
        let saved = try XCTUnwrap(stored)
        let words = saved.transcript.flatMap(\.draftWords)
        let text = words.map(\.text).joined(separator: " ")
        let record = try XCTUnwrap(provenance.provenance(for: saved))
        XCTAssertEqual(record.engine, "Parakeet TDT")
        XCTAssertEqual(record.model, "moondream/parakeet-ultra INT8")
        XCTAssertEqual(record.language, "")
        XCTAssertEqual(record.segmentation, DecodeCutting.incrementalProvenance(detectorReady: true))
        XCTAssertGreaterThan(record.inferenceMs, 0)

        let measured = Golden(text: text, words: words.map { .init(text: $0.text, startMs: $0.startMs, endMs: $0.endMs) })
        var report: [String: Any] = ["text": text, "words": words.count, "jobSeconds": seconds,
                                     "inferenceMs": record.inferenceMs]
        if let android = try environment["CASSINI_PARAKEET_GOLDEN"].map({ try androidParagraph(URL(fileURLWithPath: $0)) }) {
            report["android"] = android
            report["differencesFromAndroid"] = differences(text, android)
        }
        if environment["CASSINI_PARAKEET_RECORD"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: Self.golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(measured).write(to: Self.golden)
            report["recorded"] = Self.golden.path
        } else {
            let expected = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.golden))
            XCTAssertEqual(measured.text, expected.text)
            XCTAssertEqual(measured.words, expected.words)
        }
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("CASSINI_PARAKEET_JOB_BEGIN\n\(String(decoding: json, as: UTF8.self))\nCASSINI_PARAKEET_JOB_END")
    }

    // MARK: - helpers

    struct Golden: Codable, Equatable {
        struct Word: Codable, Equatable { var text: String; var startMs: Int64; var endMs: Int64 }
        var text: String
        var words: [Word]
    }

    private struct Host: TranscriptionJobHost {
        func jobSettings() async -> JobSettings {
            JobSettings(allowSpeechDownload: false, identifySpeakers: false, allowSpeakerDownload: false)
        }
        func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws {}
    }

    /// Clones the two model folders into this app's caches (APFS clones, so no second 650 MB).
    private func cloneModels(from source: URL) throws -> URL {
        let target = URL.cachesDirectory.appendingPathComponent("CassiniModels-job", isDirectory: true)
        let manager = FileManager.default
        for model in [ModelCatalog.parakeet, ModelCatalog.vad] where !model.ready(in: target) {
            let destination = model.directory(in: target)
            try? manager.removeItem(at: destination)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try manager.copyItem(at: model.directory(in: source), to: destination)
        }
        return target
    }

    private func durationSeconds(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// The transcript paragraph of an Android TXT export golden (the line after the "[mm:ss]" line).
    private func androidParagraph(_ url: URL) throws -> String {
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("[") && $0.hasSuffix("]") })
        return lines[index + 1].trimmingCharacters(in: .whitespaces)
    }

    private func differences(_ text: String, _ golden: String) -> [String] {
        let a = text.split(separator: " ").map(String.init), b = golden.split(separator: " ").map(String.init)
        return (0..<max(a.count, b.count)).compactMap { i in
            let mine = i < a.count ? a[i] : "∅", theirs = i < b.count ? b[i] : "∅"
            return mine == theirs ? nil : "\(i): \(mine) ≠ \(theirs)"
        }
    }
}
