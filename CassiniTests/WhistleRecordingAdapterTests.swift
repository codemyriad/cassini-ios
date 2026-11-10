import XCTest
import AVFoundation
import Synchronization
import CassiniEngine
import CassiniEngineTesting
@testable import CassiniInference
import CassiniNotebook
import CassiniWhistle

final class WhistleRecordingAdapterTests: XCTestCase {
    func testAdmissionHeadroomCanRecoverWithoutRelaunchAndLoadChecksItAgain() async throws {
        let free = Mutex<Int64>(1)
        let transcriber = WhistleTranscriber(acceptance: .init(arm64: true, operatingSystemSupported: true,
            bundleVerified: true, pipelineAccepted: true, deviceAccepted: true), availableMemory: { free.withLock { $0 } })
        let first = await transcriber.unavailability(locale: .current)
        XCTAssertEqual(first, .memory)
        free.withLock { $0 = Int64(WhistleCapability.loadHeadroom) }
        let recovered = await transcriber.unavailability(locale: .current)
        XCTAssertNil(recovered)
        free.withLock { $0 = 1 }
        do {
            _ = try await transcriber.transcribe(.init(url: URL(fileURLWithPath: "/must-not-open.wav"), language: "", allowDownload: false)) { _ in }
            XCTFail("Low live headroom must refuse before opening the audio or loading a model")
        } catch { XCTAssertEqual(error as? TranscriptionError, .failed(.memory)) }
    }

    private func transcriber() -> WhistleTranscriber {
        WhistleTranscriber(acceptance: .init(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                            pipelineAccepted: false, deviceAccepted: false, internalExperiment: true),
                           availableMemory: { Int64.max }) // Simulator laboratory admission only.
    }
    func testBundledEnglishRecordingRunsThroughFIRVADAndNeedle() async throws {
        let url = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("WhistleTests/jfk.wav"))
        let languages = Mutex<[String]>([])
        let result = try await transcriber().transcribe(.init(url: url, language: "it-IT", allowDownload: false)) {
            if case .whistleBatch(let batch) = $0 { languages.withLock { $0 += batch.languages } }
        }
        XCTAssertFalse(result.segments.isEmpty)
        XCTAssertTrue(result.segments.flatMap(\.words).contains { $0.text.lowercased().contains("country") })
        XCTAssertEqual(Set(languages.withLock { $0 }), ["en"], "detected English, never the Italian UI preference")
        XCTAssertFalse(WhistleCapability.pending(bundleVerified: true).available)
    }
    /// Event-driven pauses before any speech has finalized, after a completed segment, and near EOF.
    /// The saved snapshot is serialized as it is by the real job. A new session restores the FIR and VAD
    /// and uses the actual embedded Needle decoder for the remaining segments.
    func testRepeatedResumeHasExactWordsAndTimingsAndSkipsFinalizedWindows() async throws {
        let source = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("WhistleTests/jfk.wav"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try repeatedSpeech(source: source, destination: url)

        let expected = Mutex<[WhistleBatch]>([])
        let reference = try await transcriber().transcribe(.init(url: url, language: "", allowDownload: false)) {
            if case .whistleBatch(let batch) = $0 { expected.withLock { $0.append(batch) } }
        }
        XCTAssertGreaterThan(reference.segments.count, 2)
        let referenceBatches = expected.withLock { $0 }
        let first = try XCTUnwrap(referenceBatches.first)
        XCTAssertTrue(first.segments.isEmpty)
        let afterFirstSegment = try XCTUnwrap(referenceBatches.first { !$0.segments.isEmpty })
        let nearEnd = try XCTUnwrap(referenceBatches.last { $0.checkpoint.sourceFrame < 36 * 48_000 })
        let pauses = [first, afterFirstSegment, nearEnd].map(\.checkpoint.sourceFrame)
        XCTAssertEqual(Set(pauses).count, 3)

        var resume: WhistleCheckpoint?
        var actual: [WhistleBatch] = []
        for pause in pauses {
            let batches = Mutex<[WhistleBatch]>([])
            let request = TranscriptionRequest(url: url, language: "", allowDownload: false, whistleResume: resume)
            let adapter = transcriber()
            let attempt = Task {
                try await adapter.transcribe(request) {
                    guard case .whistleBatch(let batch) = $0 else { return }
                    batches.withLock { $0.append(batch) }
                    if batch.checkpoint.sourceFrame == pause { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            do {
                _ = try await attempt.value
                XCTFail("The checkpoint event must interrupt this session")
            } catch is CancellationError {}
            let observed = batches.withLock { $0 }
            let last = try XCTUnwrap(observed.last)
            XCTAssertEqual(last.checkpoint.sourceFrame, pause)
            XCTAssertEqual(observed.first?.checkpoint.sourceFrame, (resume?.sourceFrame ?? 0) + 48_000)
            let encoded = try JSONEncoder().encode(last.checkpoint)
            resume = try JSONDecoder().decode(WhistleCheckpoint.self, from: encoded)
            actual += observed
        }
        let last = Mutex<[WhistleBatch]>([])
        _ = try await transcriber().transcribe(.init(url: url, language: "", allowDownload: false, whistleResume: resume)) {
            if case .whistleBatch(let batch) = $0 { last.withLock { $0.append(batch) } }
        }
        actual += last.withLock { $0 }
        XCTAssertEqual(actual.map(\.checkpoint.sourceFrame), referenceBatches.map(\.checkpoint.sourceFrame))
        XCTAssertEqual(actual.map(\.languages), referenceBatches.map(\.languages))
        XCTAssertEqual(actual.map(\.checkpoint.doneSamples), referenceBatches.map(\.checkpoint.doneSamples))

        struct WordTimes: Equatable {
            let text: String
            let start: Double
            let end: Double
            init(_ word: TimedWord) { text = word.text; start = word.start; end = word.end }
        }
        let segments = actual.flatMap(\.segments)
        XCTAssertEqual(segments.map(\.text), reference.segments.map(\.text))
        XCTAssertEqual(segments.map(\.start), reference.segments.map(\.start))
        XCTAssertEqual(segments.map(\.end), reference.segments.map(\.end))
        XCTAssertEqual(segments.flatMap(\.words).map(WordTimes.init), reference.segments.flatMap(\.words).map(WordTimes.init))
        for (before, batch) in zip(actual, actual.dropFirst()) {
            let oldest = Double(before.checkpoint.processedSamples - 240_128) / 16_000
            XCTAssertTrue(batch.segments.allSatisfy { $0.start >= oldest },
                          "Each new block decodes at most one retained window of earlier audio")
        }
    }

    func testNativeInterruptionResumesAFreshJobFromDiskWithinTheRedoBounds() async throws {
        let source = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("WhistleTests/jfk.wav"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whistle-interruption-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("input.wav")
        try repeatedSpeech(source: source, destination: audio)

        let referenceFolder = root.appendingPathComponent("whole")
        let referenceNote = try await makeNote(in: referenceFolder, audio: audio)
        let whole = WorkTrace()
        let referenceOutcome = try await runJob(in: referenceFolder, noteID: referenceNote, trace: whole.trace)
        XCTAssertEqual(referenceOutcome, .done)
        let expected = try await transcript(in: referenceFolder, noteID: referenceNote)
        let wholeSubmissions = whole.state.withLock { $0.submissions }
        XCTAssertGreaterThan(wholeSubmissions.count, 2)
        XCTAssertGreaterThan(expected.flatMap(\.words).count, 20)

        for graceful in [true, false] {
            let folder = root.appendingPathComponent(graceful ? "pause" : "process-loss")
            let noteID = try await makeNote(in: folder, audio: audio)
            let files = try CheckpointFiles(notes: NoteStore(root: folder))
            let stop = StopSignal()
            let (stops, stopped) = AsyncStream<Void>.makeStream()
            let interrupted = WorkTrace()
            let cut = Mutex<Cut?>(nil)
            let trace = WhistleTranscriber.Trace(read: interrupted.trace.read, submitted: { nativeRange in
                interrupted.trace.submitted(nativeRange)
                let observed = interrupted.state.withLock { ($0.reads.last?.upperBound ?? 0, $0.submissions.count) }
                guard observed.1 >= 2, let saved = try? files.load(noteID)?.whistle,
                      observed.0 - saved.sourceFrame >= 2 * 48_000 else { return }
                cut.withLock { $0 = Cut(periodic: saved, native: nativeRange, readThrough: observed.0) }
                // Needle is entering its synchronous C call. Let it actually run; its returned result
                // must never escape to the batch after the job has accepted the interruption.
                if graceful { stop.stop(.pause(.system)) }
                else { withUnsafeCurrentTask { $0?.cancel() } }
            }, resultReady: { nativeRange in
                await interrupted.trace.resultReady(nativeRange)
                if graceful && cut.withLock({ $0?.native == nativeRange }) {
                    for await _ in stops { break }
                }
            })
            let outcome = try await runJob(in: folder, noteID: noteID, trace: trace, stop: stop) { event in
                if case .stopping = event { stopped.yield(()) }
            }
            stopped.finish()
            XCTAssertEqual(outcome, graceful ? .paused(.system) : .cancelled)
            let interruption = try XCTUnwrap(cut.withLock { $0 })
            let attempted = interrupted.state.withLock { $0 }
            XCTAssertEqual(attempted.submissions.last, interruption.native)
            XCTAssertEqual(attempted.results, attempted.submissions, "the interrupted C call really returned")
            XCTAssertGreaterThan(interruption.readThrough - interruption.periodic.sourceFrame, 48_000)

            // No adapter state, TranscriptResume, or last batch is passed to the replacement job.
            let persisted = try XCTUnwrap(try files.load(noteID))
            let checkpoint = try XCTUnwrap(persisted.whistle)
            XCTAssertFalse(persisted.wordsComplete)
            XCTAssertFalse(persisted.segments.isEmpty, "exercise an already committed word prefix")
            if graceful {
                XCTAssertGreaterThan(checkpoint.sourceFrame, interruption.periodic.sourceFrame)
            } else {
                XCTAssertEqual(checkpoint, interruption.periodic, "no graceful write after simulated process loss")
            }
            let resumed = WorkTrace()
            let resumedOutcome = try await runJob(in: folder, noteID: noteID, trace: resumed.trace)
            XCTAssertEqual(resumedOutcome, .done)
            let actual = try await transcript(in: folder, noteID: noteID)
            XCTAssertEqual(actual, expected, "exact text, word timings, and segment bounds after \(graceful ? "pause" : "process loss")")

            let remaining = resumed.state.withLock { $0 }
            let sourceLimit: Int64 = graceful ? 48_000 : 6 * 48_000
            let priming: Int64 = 4_800
            let earliest = checkpoint.sourceFrame - priming
            XCTAssertEqual(remaining.reads.first?.lowerBound, earliest)
            XCTAssertTrue(remaining.reads.allSatisfy { $0.lowerBound >= earliest })
            let replayedSource = remaining.reads.reduce(0) { count, read in
                count + max(0, min(read.upperBound, interruption.readThrough) - read.lowerBound)
            }
            let redoFrames = interruption.readThrough - checkpoint.sourceFrame
            XCTAssertGreaterThan(redoFrames, 0)
            XCTAssertLessThanOrEqual(redoFrames, sourceLimit)
            XCTAssertGreaterThan(replayedSource, 0)
            XCTAssertLessThanOrEqual(replayedSource, Int(sourceLimit + (sourceLimit / 48_000 + 1) * priming))
            let replayedNative = remaining.submissions.filter { attempted.submissions.contains($0) }
            XCTAssertTrue(replayedNative.contains(interruption.native))
            XCTAssertTrue(remaining.submissions.allSatisfy { $0.upperBound > checkpoint.doneSamples })
            XCTAssertLessThanOrEqual(replayedNative.reduce(0) { $0 + $1.count },
                                     graceful ? 240_128 + 16_000 : 22 * 16_000 - 1)
            XCTAssertEqual(Array(wholeSubmissions.suffix(remaining.submissions.count)), remaining.submissions,
                           "native ranges include exactly the suffix of the uninterrupted run")
        }
    }

    private struct Cut: Sendable {
        let periodic: WhistleCheckpoint
        let native: Range<Int>
        let readThrough: Int64
    }

    private final class WorkTrace: Sendable {
        struct State {
            var reads: [Range<Int64>] = []
            var submissions: [Range<Int>] = []
            var results: [Range<Int>] = []
        }
        let state = Mutex(State())
        var trace: WhistleTranscriber.Trace {
            .init(read: { read in self.state.withLock { $0.reads.append(read) } },
                  submitted: { range in self.state.withLock { $0.submissions.append(range) } },
                  resultReady: { range in self.state.withLock { $0.results.append(range) } })
        }
    }

    private struct TimedText: Equatable {
        let text: String
        let start: Double
        let end: Double
    }

    private struct Passage: Equatable {
        let bounds: TimedText
        let words: [TimedText]
    }

    private func transcript(in folder: URL, noteID: UUID) async throws -> [Passage] {
        let store = try NoteStore(root: folder)
        let stored = await store.note(noteID)
        return try XCTUnwrap(stored).transcript.map { segment in
            Passage(bounds: .init(text: segment.text, start: segment.start, end: segment.end),
                    words: segment.words.map { .init(text: $0.text, start: $0.start, end: $0.end) })
        }
    }

    private func makeNote(in folder: URL, audio: URL) async throws -> UUID {
        let store = try NoteStore(root: folder)
        var note = Note(id: UUID(), title: "Whistle resume", audioFilename: "input.wav")
        let file = try AVAudioFile(forReading: audio)
        note.duration = Double(file.length) / file.processingFormat.sampleRate
        try await store.save(note)
        try FileManager.default.copyItem(at: audio, to: store.audioURL(for: note))
        return note.id
    }

    private func runJob(in folder: URL, noteID: UUID, trace: WhistleTranscriber.Trace, stop: StopSignal = StopSignal(),
                        events: @escaping @Sendable (JobEvent) -> Void = { _ in }) async throws -> JobOutcome {
        let store = try NoteStore(root: folder)
        let transcriber = WhistleTranscriber(acceptance: {
            .init(arm64: true, operatingSystemSupported: true, bundleVerified: true, pipelineAccepted: false,
                  deviceAccepted: false, internalExperiment: true)
        }, availableMemory: { Int64.max }, trace: trace)
        let runner = TranscriptionJob(notes: store, transcriber: transcriber, analyzer: FakeAnalyzer(),
                                      checkpoints: CheckpointFiles(notes: store), provenance: ProvenanceFiles(notes: store),
                                      host: Host(), clock: FakeClock(), budget: NativeBudget())
        return await runner.run(Job(noteID: noteID, seq: 1, kind: .transcribe, state: .running, enqueuedAt: Date()),
                                stop: stop, events: events)
    }

    private struct Host: TranscriptionJobHost {
        func jobSettings() async -> JobSettings {
            .init(allowSpeechDownload: false, identifySpeakers: false, allowSpeakerDownload: false)
        }
        func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws {}
    }

    private func repeatedSpeech(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: samples)
        let speech = try XCTUnwrap(samples.floatChannelData).pointee
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        let repeatBlock = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12 * 48_000))
        repeatBlock.frameLength = repeatBlock.frameCapacity
        let channel = try XCTUnwrap(repeatBlock.floatChannelData).pointee
        for index in 0..<Int(repeatBlock.frameLength) {
            channel[index] = index / 3 < Int(samples.frameLength) ? speech[index / 3] : 0
        }
        for _ in 0..<3 { try output.write(from: repeatBlock) }
    }

    func testSharedDCRecordingsKeepTheExactDesktopSixBoundaries() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CASSINI_WHISTLE_DC"] else {
            throw XCTSkip("separate mandatory Whistle DC gate supplies the shared vector folder")
        }
        let expected = [[105984,189440], [347648,367616], [371200,413184], [416256,458240], [504320,544256], [547328,589312]]
        for name in ["dc-quiet-jfk-v1.wav", "dc-quiet-jfk-v1-control.wav"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            let result = try await transcriber().transcribe(.init(url: url, language: "", allowDownload: false)) { _ in }
            let actual = result.segments.map { [Int(($0.start * 16000).rounded()), Int(($0.end * 16000).rounded())] }
            XCTAssertEqual(actual, expected, name)
            XCTAssertFalse(result.segments.flatMap(\.words).isEmpty)
            print("WHISTLE_DC \(name) \(actual) \(result.segments.map(\.text))")
        }
    }
}
