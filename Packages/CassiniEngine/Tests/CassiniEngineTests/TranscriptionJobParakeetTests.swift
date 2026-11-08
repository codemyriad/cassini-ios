import CassiniCore
import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The job with a Parakeet transcriber over 70 s of audio: the real `IncrementalTranscript` cuts 28 s windows with 2 s
/// of overlap, and a scripted recognizer hears one word a second ("w0" at 0–0.8 s). Android's `TranscriptionJobTest`
/// with its fake recognizer.
@Suite struct TranscriptionJobParakeetTests {
    typealias Harness = TranscriptionJobTests.Harness

    private func harness(_ transcriber: WindowedTranscriber = WindowedTranscriber(),
                         limits: TranscriptionJob.Limits = .init()) async throws -> (Harness, WindowedTranscriber) {
        (try await Harness(limits: limits, engine: transcriber), transcriber)
    }

    // ports: TranscriptionJobTest#decodesIn28SecondWindowsAndSavesOneCheckpointPerWindow
    @Test func decodesIn28SecondWindowsAndSavesOneCheckpointPerWindow() async throws {
        let (h, transcriber) = try await harness()
        let (outcome, events) = await h.run()
        #expect(outcome == .done)
        // Windows end at 28 s and 54 s; the rest is decoded at the end.
        #expect(h.checkpoints.saved.map(\.doneMs) == [28_000, 54_000, 70_000])
        #expect(events.compactMap(\.checkpointed) == [28_000, 54_000, 70_000])
        #expect(h.checkpoints.saved.map(\.wordsComplete) == [false, false, true])
        let first = try #require(h.checkpoints.saved.first)
        #expect(first.model == ModelCatalog.parakeetRevision)
        #expect(first.recognition == RecognitionCheckpoint(start: 416_000, end: 448_000, position: 448_000))
        #expect(first.draftWords.map(\.text) == (0..<28).map { "w\($0)" })
        #expect(h.checkpoints.saved.last?.recognition == nil)
        // Parakeet takes no language.
        #expect(transcriber.requests.map(\.language) == [""])
        let note = try #require(await h.note())
        #expect(note.transcript.flatMap(\.draftWords).map(\.text) == (0..<70).map { "w\($0)" })
        #expect(!h.files.exists(h.noteID), "the work is removed once the note is saved")
    }

    // ports: TranscriptionJobTest#provenanceWithoutTheDiarizerEqualsThe010Record (the recognition record)
    @Test func theProvenanceIsTheParakeetRecordWithTheDecodeTimeAlone() async throws {
        let (h, _) = try await harness()
        #expect(await h.run().outcome == .done)
        let record = try #require(h.provenance(of: await h.note()))
        #expect(record.backend == "sherpa-onnx")
        #expect(record.engine == "Parakeet TDT")
        // D16 §5: the model host's pin (Android still writes "moondream/parakeet-ultra INT8").
        #expect(record.model == "parakeet-ultra-0.6b-int8@18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9")
        #expect(record.version == "sherpa-onnx 1.13.7; model revision \(ModelCatalog.parakeetRevision)")
        #expect(record.source == "recording")
        #expect(record.language == "und", "Parakeet does not say which language it heard (D53.2)")
        #expect(record.segmentation == WindowedTranscriber.segmentation)
        #expect(record.resumedFromMs == 0)
        // Three decodes of 100 ms each; the job's own clock (10 s a read) is not the inference time.
        #expect(record.inferenceMs == 300)
    }

    // ports: TranscriptionJobTest#stopAtAWindowThenResumeEqualsAnUninterruptedRun
    @Test func stopAtAWindowThenResumeEqualsAnUninterruptedRun() async throws {
        let (whole, _) = try await harness()
        #expect(await whole.run().outcome == .done)

        let (stopped, transcriber) = try await harness()
        let stop = StopSignal()
        transcriber.afterWindow = WindowedTranscriber.pause(stop, afterWindows: 2)
        let (outcome, events) = await stopped.run(stop: stop)
        #expect(outcome == .paused(.user))
        #expect(events.contains(.stopping))
        // The checkpoint holds the windows decoded before the stop.
        let checkpoint = try #require(stopped.checkpoints.saved.last)
        #expect(checkpoint.doneMs == 54_000)
        #expect(checkpoint.recognition == RecognitionCheckpoint(start: 832_000, end: 864_000, position: 864_000))
        #expect(await stopped.note()?.transcript.isEmpty == true)

        transcriber.afterWindow = { _ in }
        let (resumedOutcome, resumedEvents) = await stopped.run()
        #expect(resumedOutcome == .done)
        let restored = try #require(resumedEvents.compactMap(\.started).first?.restored)
        #expect(restored.words == checkpoint.draftWords)
        #expect(restored.doneMs == 54_000)
        #expect(transcriber.requests.map(\.resume?.recognition) == [nil, checkpoint.recognition])
        #expect(transcriber.requests.last?.resume?.words.map(\.text) == (0..<54).map { "w\($0)" })

        let expected = try #require(await whole.note()), actual = try #require(await stopped.note())
        // The same words; each run's one voice is its own (D59).
        let words = { (note: Note) in note.transcript.flatMap(\.draftWords).map { "\($0.startMs) \($0.endMs) \($0.text)" } }
        #expect(words(actual) == words(expected))
        #expect(actual.transcript.map(\.start) == expected.transcript.map(\.start))
        #expect(Set(actual.transcript.map(\.speakerID)).count == 1)
        let resumed = stopped.provenance(of: actual)
        #expect(resumed?.resumedFromMs == 54_000)
        #expect(resumed?.inferenceMs == 300, "two windows before the stop, the last part after it")
    }

    // ports: TranscriptionJobTest#aStopBeforeTheFirstWindowIsDoneLeavesNoCheckpoint
    @Test func aStopBeforeTheFirstWindowIsDoneLeavesNoCheckpoint() async throws {
        let (h, transcriber) = try await harness()
        let stop = StopSignal()
        transcriber.beforeBlock = { index in if index == 3 { stop.stop(.pause(.user)) } }
        transcriber.blockDelay = .milliseconds(20)
        #expect(await h.run(stop: stop).outcome == .paused(.user))
        #expect(h.checkpoints.saved.isEmpty)
        #expect(!h.files.exists(h.noteID))
    }

    // ports: CheckpointGoldenTest#aCheckpointOfParakeetV3IsNotResumedWithUltra (the job)
    @Test func aParakeetV3OrAppleFallbackCheckpointIsNotResumedWithUltra() async throws {
        let (h, transcriber) = try await harness()
        // Parakeet TDT 0.6B v3's revision, Android's model before Ultra.
        try h.files.save(CheckpointState(source: "audio.m4a", signature: CheckpointState.signature(of: h.audioURL),
                                         model: "2bda32ec70b097a55adaa07d9a7173915b43cc78", segments: [], doneMs: 0,
                                         totalMs: 70_000, elapsedMs: 0), for: h.noteID)
        #expect(await h.run().outcome == .failed(.checkpointMismatch))
        #expect(transcriber.requests.isEmpty)

        let (fallback, fallbackTranscriber) = try await harness()
        try fallback.files.save(CheckpointState(source: "audio.m4a", signature: CheckpointState.signature(of: fallback.audioURL),
                                                model: CheckpointState.appleModel(language: "it-IT"), segments: [],
                                                doneMs: 0, totalMs: 70_000, elapsedMs: 0), for: fallback.noteID)
        #expect(await fallback.run().outcome == .failed(.checkpointMismatch))
        #expect(fallbackTranscriber.requests.isEmpty)
    }

    // ports: TranscriptionJobTest#wordsThatOutgrowTheWordBodyFailAtTheWindowThatPassesTheLimit
    @Test func wordsThatOutgrowTheWordBodyFailAtTheWindowThatPassesTheLimit() async throws {
        let firstWindow = TranscriptSegment.segments(of: (0..<28).map { Word("", Int64($0) * 1000, Int64($0) * 1000 + 800, "w\($0)") })
        // The body is counted with the language it is written with: `und` for Parakeet (D53.2).
        let limit = TranscriptBudget.bytes(firstWindow, language: TranscriptLanguage.undetermined) + 10
        let (h, _) = try await harness(limits: .init(maxBodyBytes: limit))
        #expect(await h.run().outcome == .failed(.long))
        #expect(h.checkpoints.saved.map(\.doneMs) == [28_000], "the window before the limit stays")
    }

    /// The word body is counted with `und`, the language it is written with: a limit one byte under the first window's
    /// `und` body fails at that window, which counting with `""` (17 bytes fewer) would let through.
    @Test func aParakeetBodyIsCountedWithTheUndItIsWrittenWith() async throws {
        let firstWindow = TranscriptSegment.segments(of: (0..<28).map { Word("", Int64($0) * 1000, Int64($0) * 1000 + 800, "w\($0)") })
        let limit = TranscriptBudget.bytes(firstWindow, language: TranscriptLanguage.undetermined) - 1
        #expect(TranscriptBudget.bytes(firstWindow) <= limit, "without the language the window would fit")
        let (h, _) = try await harness(limits: .init(maxBodyBytes: limit))
        #expect(await h.run().outcome == .failed(.long))
        #expect(h.checkpoints.saved.isEmpty, "the first window already passes the limit")
    }

    // ports: TranscriptionJobTest#theRecognizersLanguageIsWrittenAlikeInBodyDescriptorAndProvenance
    @Test func theRecognizersLanguageIsWrittenAlikeInBodyDescriptorAndProvenance() async throws {
        // D53.2: a Parakeet run writes "und" in all three places, never "" or a missing key.
        let (h, _) = try await harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        #expect(await h.run(language: "it-IT").outcome == .done)
        let note = try #require(await h.note())
        #expect(note.language == "und")
        let folder = h.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = try await PortableExportService(audio: FakeAudioProcessing(duration: 70, opensAnyFile: true),
                                                     provenance: h.provenanceFiles, unassignedLabel: "Unknown speaker")
            .export(note, original: h.audioURL, playable: h.audioURL, into: folder, filename: "export")
        let document = CassiniDocument.read(output)
        let id = try #require(document.defaultId)
        let variant = try #require(document.variants.first { $0.id == id })
        let body = try #require(variant.body)
        #expect(try JSON.parseObject(body)["language"]?.string == "und")
        #expect(try Transcript.fromJSON(body).language == "und")
        #expect(variant.descriptor["language"]?.string == "und")
        #expect(document.manifest?["provenance"]?.object?["speechToText"]?.object?[id]?.object?["language"]?.string == "und")
    }

    // ports: JobFailureTest (the recognizer's failures) and TranscriptionJobTest#javaOutOfMemoryPausesWithMemoryAndKeepsTheCheckpoint
    @Test func theRecognizersFailuresMapAsOnAndroid() async throws {
        for (thrown, outcome) in [(JobFailure.memory as any Error, JobOutcome.failed(.memory)),
                                  (JobFailure.timings, .failed(.timings)), (JobFailure.model, .failed(.model)),
                                  (CancellationError(), .cancelled), (JobFailure.cancelled, .cancelled),
                                  (TranscriptionError.failed(.cancelled), .cancelled)] {
            let (h, transcriber) = try await harness()
            transcriber.failure = (window: 1, error: thrown)
            #expect(await h.run().outcome == outcome, "\(thrown)")
            #expect(try h.files.load(h.noteID)?.doneMs == 28_000, "the checkpoint before it stays")
        }
    }

    /// Parakeet whenever the runtime is linked and the device can hold Ultra, installed or not: the job downloads it.
    @Test func theRecognizerIsChosenByLinkAndMemory() {
        let gib: UInt64 = 1 << 30
        #expect(!SpeechCapability.parakeetCapable(physicalMemory: 4 * gib))
        #expect(SpeechCapability.parakeetCapable(physicalMemory: 5_900_000_000))
        #expect(SpeechCapability.choose(linked: true, capable: true, apple: .init(hardwareAvailable: true, localeSupported: true, assets: .ready)) == .parakeet)
        #expect(SpeechCapability.choose(linked: false, capable: true, apple: .init(hardwareAvailable: true, localeSupported: true, assets: .ready)) == .appleSpeech)
        #expect(SpeechCapability.choose(linked: true, capable: false, apple: .init(hardwareAvailable: true, localeSupported: true, assets: .ready)) == .appleSpeech)
        #expect(SpeechRecognizer.parakeet.checkpointModel(language: "it-IT") == ModelCatalog.parakeetRevision)
        #expect(SpeechRecognizer.appleSpeech.checkpointModel(language: "it-IT") == "apple-speechtranscriber it-IT")
    }

    @Test func theMemoryCheckStopsBeforeTheLoadAndBeforeEachWindow() {
        #expect(ParakeetMemory.allows(availableBytes: nil, loaded: false), "the system does not tell")
        #expect(ParakeetMemory.allows(availableBytes: 0, loaded: false), "the simulator reports 0")
        #expect(!ParakeetMemory.allows(availableBytes: 1_100 << 20, loaded: false))
        #expect(ParakeetMemory.allows(availableBytes: 1_200 << 20, loaded: false))
        #expect(!ParakeetMemory.allows(availableBytes: 600 << 20, loaded: true))
        #expect(ParakeetMemory.allows(availableBytes: 640 << 20, loaded: true))
    }

    // ports: TranscriptionJobTest#aMissingSpeechDetectorIsFetchedAgainOnlyOnline (the rule; ParakeetTranscriberTests runs it)
    @Test func aMissingSpeechDetectorIsAskedForOnlyOnline() {
        #expect(ParakeetModels.request(speechReady: true, detectorReady: true, online: true).isEmpty)
        #expect(ParakeetModels.request(speechReady: true, detectorReady: false, online: true) == [.speech])
        #expect(ParakeetModels.request(speechReady: true, detectorReady: false, online: false).isEmpty)
        #expect(ParakeetModels.request(speechReady: false, detectorReady: true, online: false) == [.speech])
    }
}

/// A Parakeet transcriber over 70 s of silent 16 kHz samples, fed in 1 s blocks to the real `IncrementalTranscript`.
/// Its recognizer hears word `wN` at N to N + 0.8 s in every window that holds it whole, and takes 100 ms of decoder
/// time per window. A resumed run starts from the checkpoint's position.
final class WindowedTranscriber: Transcribing, @unchecked Sendable {
    static let segmentation = DecodeCutting.incrementalProvenance(detectorReady: true)
    private let lock = NSLock()
    private var _requests: [TranscriptionRequest] = []
    var requests: [TranscriptionRequest] { lock.withLock { _requests } }
    var beforeWindow: @Sendable (Int) -> Void = { _ in }
    /// Awaited once a window's words have gone to the job, with the number of windows decoded; the decode waits for it.
    var afterWindow: @Sendable (Int) async throws -> Void = { _ in }

    /// An `afterWindow` that pauses `stop` once `count` windows are in, and holds the decode until the job cancels it.
    /// A stop from `beforeWindow` raced the job's stop watch: when the watch saw it while the window was decoding, the
    /// job kept only the windows before (on a loaded host); here the windows are in first.
    static func pause(_ stop: StopSignal, afterWindows count: Int) -> @Sendable (Int) async throws -> Void {
        { windows in
            guard windows == count else { return }
            stop.stop(.pause(.user))
            // An upper bound: the job cancels the decode once its stop watch sees the stop.
            try await Task.sleep(for: .seconds(30))
        }
    }
    var beforeBlock: @Sendable (Int) -> Void = { _ in }
    var blockDelay: Duration?
    /// Thrown in place of the window at this index.
    var failure: (window: Int, error: any Error)?
    /// What the words start with: `w` hears "w0", "w1", …
    var word = "w"
    let totalSamples = 70 * Limits.asrRate

    var recognizer: SpeechRecognizer { .parakeet }
    func segmentation() async -> String? { Self.segmentation }
    func assetStatus(locale: Locale) async -> ModelPartStatus { .ready }
    func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {}
    func speechLanguages() async -> [SpeechLanguage] { [] }

    func transcribe(_ request: TranscriptionRequest,
                    events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        lock.withLock { _requests.append(request) }
        var windows = 0
        // As `ParakeetTranscriber`: each window's words go to the streaming speakers after the decode, and the
        // diarizer goes when the run ends.
        let speakers = request.speakers
        defer { speakers?.close() }
        let recognize = { [self] (audio: PcmAudio, offsetMs: Int64) throws -> Transcript in
            beforeWindow(windows)
            if let failure, failure.window == windows { throw failure.error }
            windows += 1
            let endMs = offsetMs + audio.durationMs
            let words = Transcript((0..<70).compactMap { n -> Word? in
                let start = Int64(n) * 1000
                guard start >= offsetMs, start + 800 <= endMs else { return nil }
                return Word("", start - offsetMs, start + 800 - offsetMs, "\(word)\(n)")
            })
            return try speakers?.window(audio, startMs: offsetMs, words: words) ?? words
        }
        let transcript: IncrementalTranscript
        var position = 0
        if let resume = request.resume {
            let window = [Float](repeating: 0, count: Int(resume.recognition.position - resume.recognition.start))
            transcript = try IncrementalTranscript(restored: resume.recognition.state(window: window, words: resume.words),
                                                   recognize: recognize)
            position = Int(resume.recognition.position)
        } else {
            transcript = try IncrementalTranscript(recognize: recognize)
        }
        let total = TimeInterval(totalSamples) / TimeInterval(Limits.asrRate)
        events(.progress(done: TimeInterval(transcript.doneMs) / 1000, total: total))
        var reported = transcript.doneMs
        var block = 0
        let silence = [Float](repeating: 0, count: Limits.asrRate)
        while position < totalSamples {
            beforeBlock(block)
            block += 1
            if let blockDelay { try await Task.sleep(for: blockDelay) }
            let count = min(Limits.asrRate, totalSamples - position)
            try transcript.accept(silence, count: count)
            position += count
            if transcript.doneMs > reported {
                reported = transcript.doneMs
                let state = transcript.checkpoint()
                events(.window(TranscriptWindow(words: state.words, recognition: RecognitionCheckpoint(state),
                                                inferenceMs: Int64(windows) * 100, speakers: speakers?.checkpoint())))
                events(.progress(done: TimeInterval(reported) / 1000, total: total))
                try await afterWindow(windows)
            }
        }
        let words = try transcript.finish().words
        events(.progress(done: total, total: total))
        return TranscriptionResult(segments: TranscriptSegment.segments(of: words), segmentation: Self.segmentation,
                                   inferenceMs: Int64(windows) * 100, speakers: speakers?.checkpoint())
    }
}
