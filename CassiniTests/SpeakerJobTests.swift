import XCTest
import AVFoundation
import CassiniEngine
import CassiniEngineTesting
import CassiniInference
import CassiniNotebook
import CassiniSherpa

/// A real transcription job with Android's whole pipeline on the simulator: `TranscriptionJob` over Parakeet Ultra,
/// streaming Sortformer and CAM++ (CassiniSherpa through `ParakeetTranscriber` and `SpeakerAnalyzer`), on the
/// two-speaker FLEURS mix (A, B, A again; scripts/fetch-speaker-fixture.py). The first run tells the speakers apart
/// window by window and gives each a CAM++ print; A is then saved as a voice from that print, and Transcribe again
/// names A from it with Android's thresholds. Opt-in and skipped unless the build links the runtime
/// (CASSINI_SHERPA_LOCAL=1) and the environment names the models and the mix; scripts/speaker-smoke.sh runs it.
///
/// Environment (xcodebuild passes TEST_RUNNER_<name> through as <name>):
///   CASSINI_PARAKEET_MODEL_ROOT  a model root as scripts/fetch-ci-models.py writes it (parakeet-ultra/, vad/ and
///                                speaker-models/ with their markers; read only, cloned into this app's caches)
///   CASSINI_SPEAKER_AUDIO        fleurs-two-speakers.wav; its .json beside it lists the three spans
///   CASSINI_SPEAKER_JOB_OUT      a file to write the measurements to as JSON
final class SpeakerJobTests: XCTestCase {
    private struct Span: Decodable { let speaker: String; let startMs: Int64; let endMs: Int64 }
    private struct Fixture: Decodable { let durationMs: Int64; let spans: [Span] }

    func testAnUltraJobTellsTheTwoSpeakersApartAndTranscribeAgainNamesTheSavedOne() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without CASSINI_SHERPA_LOCAL")
        let source = try XCTUnwrap(environment["CASSINI_PARAKEET_MODEL_ROOT"].map { URL(fileURLWithPath: $0) },
                                   "set CASSINI_PARAKEET_MODEL_ROOT")
        let clip = try XCTUnwrap(environment["CASSINI_SPEAKER_AUDIO"].map { URL(fileURLWithPath: $0) },
                                 "set CASSINI_SPEAKER_AUDIO")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: clip.deletingPathExtension()
            .appendingPathExtension("json")))
        let models = try cloneModels(from: source)
        for model in [ModelCatalog.parakeet, ModelCatalog.vad, ModelCatalog.diarization, ModelCatalog.voiceprint] {
            XCTAssertTrue(model.ready(in: models), "\(model.directory)/\(model.markerFile)")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-job-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = try NoteStore(root: root)
        var note = Note(id: UUID(), title: "Two speakers", audioFilename: "audio.wav")
        note.duration = Double(fixture.durationMs) / 1000
        try await notes.save(note)
        try FileManager.default.copyItem(at: clip, to: notes.audioURL(for: note))

        let repository = ModelRepository(root: models, consent: NoConsent(), fetcher: NoFetcher())
        let speakerModels = SpeakerModels(repository: repository,
                                          installer: PinnedModelInstaller(models: repository, storage: Unlimited(), online: { false }))
        let analyzer = SpeakerAnalyzer(models: speakerModels, runtime: SherpaRuntime.speakers)
        let host = Host(notes: notes)
        let provenance = ProvenanceFiles(notes: notes)
        let job = TranscriptionJob(notes: notes, transcriber: ParakeetTranscriber(models: .init(root: models), runtime: SherpaRuntime.speech),
                                   analyzer: analyzer, checkpoints: CheckpointFiles(notes: notes), provenance: provenance,
                                   host: host, clock: FakeClock())
        var report: [String: Any] = ["platform": "iOS Simulator (not a device measurement)"]

        // The first run: the speakers are told apart while Parakeet decodes.
        let drafts = Drafts()
        let started = Date()
        let first = await job.run(Job(noteID: note.id, seq: 1, kind: .transcribe, state: .running, enqueuedAt: Date()),
                                  stop: StopSignal()) { drafts.add($0) }
        report["firstJobSeconds"] = Date().timeIntervalSince(started)
        XCTAssertEqual(first, .done)
        XCTAssertTrue(drafts.started?.speakers == true && drafts.started?.prints == true)
        XCTAssertFalse(drafts.unavailable, "the speakers did not fail")
        let draftSpeakers = Set(drafts.lastDraft.map(\.speaker))
        report["draftSpeakers"] = draftSpeakers.count
        XCTAssertFalse(draftSpeakers.contains(""), "every draft word has a speaker while the job runs")
        XCTAssertGreaterThanOrEqual(draftSpeakers.count, 2, "the draft tells the speakers apart before the job ends")

        let stored = await notes.note(note.id)
        let saved = try XCTUnwrap(stored)
        let bySpan = speakers(of: saved, fixture.spans)
        report["speakersBySpan"] = bySpan.map { $0 ?? "none" }
        XCTAssertEqual(Set(saved.transcript.compactMap(\.speakerID)).count, 2, "two speakers in the note")
        XCTAssertEqual(bySpan[0], bySpan[2], "A keeps one speaker across the windows")
        XCTAssertNotEqual(bySpan[0], bySpan[1], "B is someone else")
        XCTAssertEqual(saved.speakers?.count, 2)
        let analysis = try XCTUnwrap(host.analyses.first)
        XCTAssertEqual(analysis.prints.count, 2)
        XCTAssertTrue(analysis.prints.allSatisfy { $0.model == VoiceprintModel.sha256 && $0.vector.count == 512 })
        let printA = try XCTUnwrap(analysis.prints.first { $0.speakerID == bySpan[0] })
        let printB = try XCTUnwrap(analysis.prints.first { $0.speakerID == bySpan[1] })
        let cosine = try XCTUnwrap(VoiceMatcher.cosine(printA.vector, printB.vector))
        report["cosineAB"] = cosine
        report["printSeconds"] = analysis.prints.map(\.speechSeconds)
        XCTAssertLessThan(cosine, VoiceprintModel.thresholds.automatic, "A and B are not named as each other")
        let record = try XCTUnwrap(provenance.provenance(for: saved))
        XCTAssertEqual(record.speakerDiarization?.backend, TranscriptProvenance.SpeakerDiarization.sortformerBackend)
        XCTAssertEqual(record.speakerDiarization?.incremental, TranscriptProvenance.SpeakerDiarization.incrementalWindows)
        XCTAssertEqual(record.speakerDiarization?.speakerCount, 2)
        XCTAssertEqual(record.speakerIdentification?.speakersWithPrints, 2)
        report["diarizationMs"] = record.speakerDiarization?.elapsedMs ?? 0

        // A is saved as a voice from its print; Transcribe again names A from it.
        let anna = SavedVoice(name: "Anna", samples: [VoiceSample(noteID: UUID(), print: printA)])
        host.voices = [anna]
        let again = await job.run(Job(noteID: note.id, seq: 2, kind: .transcribeAgain, state: .running, enqueuedAt: Date()),
                                  stop: StopSignal()) { _ in }
        XCTAssertEqual(again, .done)
        let renamed = await notes.note(note.id)
        let named = try XCTUnwrap(renamed)
        let againBySpan = speakers(of: named, fixture.spans)
        let speakerA = try XCTUnwrap(named.speakers?.first { $0.id == againBySpan[0] })
        let speakerB = try XCTUnwrap(named.speakers?.first { $0.id == againBySpan[1] })
        report["againMatchA"] = String(describing: speakerA.match)
        report["againMatchB"] = String(describing: speakerB.match)
        guard case .auto(let voice, let score) = speakerA.match else {
            return XCTFail("A is named from the saved voice automatically: \(speakerA.match)")
        }
        XCTAssertEqual(voice, anna.id)
        XCTAssertGreaterThanOrEqual(score, VoiceprintModel.thresholds.automatic)
        XCTAssertEqual(speakerA.name, "Anna")
        XCTAssertNil(speakerB.match.voiceID, "B is not Anna")
        XCTAssertEqual(provenance.provenance(for: named)?.speakerIdentification?.autoApplied, 1)

        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("CASSINI_SPEAKER_JOB_BEGIN\n\(String(decoding: json, as: UTF8.self))\nCASSINI_SPEAKER_JOB_END")
        if let out = environment["CASSINI_SPEAKER_JOB_OUT"] { try json.write(to: URL(fileURLWithPath: out)) }
    }

    // MARK: - helpers

    /// For each span, the speaker id of the most words in it.
    private func speakers(of note: Note, _ spans: [Span]) -> [String?] {
        let words = note.transcript.flatMap { segment in segment.draftWords.map { (segment.speakerID, $0) } }
        return spans.map { span in
            var counts: [String: Int] = [:]
            for (speaker, word) in words where word.startMs >= span.startMs && word.endMs <= span.endMs {
                if let speaker { counts[speaker, default: 0] += 1 }
            }
            return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }
    }

    /// What the job shows while it runs.
    private final class Drafts: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [JobEvent] = []
        func add(_ event: JobEvent) { lock.withLock { events.append(event) } }
        var started: JobStart? { lock.withLock { events.compactMap { if case .started(let start) = $0 { start } else { nil } }.first } }
        var unavailable: Bool { lock.withLock { events.contains(.speakersUnavailable) } }
        var lastDraft: [DraftWord] {
            lock.withLock {
                events.compactMap { if case .windowDone(_, _, let words) = $0, !words.isEmpty { words } else { nil } }.last ?? []
            }
        }
    }

    /// The app's host without its stores: the analysis goes into the note with the saved voices of `voices`, as
    /// `VoicesStore.applySpeakerAnalysis` does (no namespace for streamed ids, the streamed words when they are the note's).
    private final class Host: TranscriptionJobHost, @unchecked Sendable {
        let notes: NoteStore
        private let lock = NSLock()
        private var _voices: [SavedVoice] = []
        private var _analyses: [SpeakerAnalysis] = []
        init(notes: NoteStore) { self.notes = notes }
        var voices: [SavedVoice] {
            get { lock.withLock { _voices } }
            set { lock.withLock { _voices = newValue } }
        }
        var analyses: [SpeakerAnalysis] { lock.withLock { _analyses } }

        func jobSettings() async -> JobSettings {
            JobSettings(allowSpeechDownload: false, identifySpeakers: true, allowSpeakerDownload: false)
        }

        func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws {
            lock.withLock { _analyses.append(analysis) }
            guard let note = await notes.note(noteID) else { return }
            let matches = AnalysisMatches.of(note, turns: analysis.turns, prints: analysis.prints, savedVoices: voices,
                                             earlierPrints: [], trashed: [])
            let attributed = analysis.transcript.flatMap {
                ProvenanceRecord.fingerprint(of: $0) == ProvenanceRecord.fingerprint(of: note.transcript) ? $0 : nil
            }
            _ = try await notes.mutate(noteID) { note in
                matches.apply(to: &note, turns: analysis.turns, autoName: true, stamp: VersionStamp(date: Date()),
                              attributed: attributed)
            }
        }
    }

    private struct NoConsent: ModelConsentRecords {
        func consentAt() async -> Date? { nil }
        func recordConsent() async {}
        func recordDeclined() async {}
    }

    private struct NoFetcher: ModelFetching {
        func fetch(_ model: ModelDescriptor, into directory: URL,
                   progress: @escaping @Sendable (Int64, Bool) -> Void) async throws { throw ModelError(.modelDownload) }
    }

    private struct Unlimited: StorageProbe {
        func availableBytes(at url: URL) -> Int64 { .max }
    }

    /// Clones the model folders into this app's caches (APFS clones, so no second 650 MB).
    private func cloneModels(from source: URL) throws -> URL {
        let target = URL.cachesDirectory.appendingPathComponent("CassiniModels-speakers", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        for folder in ["parakeet-ultra", "vad", "speaker-models"] {
            let destination = target.appendingPathComponent(folder, isDirectory: true)
            if manager.fileExists(atPath: destination.path) { continue }
            try manager.copyItem(at: source.appendingPathComponent(folder, isDirectory: true), to: destination)
        }
        return target
    }
}
