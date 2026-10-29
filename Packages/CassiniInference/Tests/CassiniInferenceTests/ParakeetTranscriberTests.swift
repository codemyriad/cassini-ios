import AVFoundation
import CassiniCore
import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniNotebook
import CassiniEngineTesting
@testable import CassiniInference

/// `ParakeetTranscriber` over a fake native runtime and generated audio: a 16 kHz float WAV with word `wN` as a burst of
/// value (N + 1) / 100 a quarter second into second N. The fake recognizer turns each burst into a timed token; the fake
/// detector finds each burst. The model files are sparse files of the pinned sizes with their markers.
@Suite(.serialized) struct ParakeetTranscriberTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var root: URL { folder.appendingPathComponent("models", isDirectory: true) }

    // MARK: - Fixtures

    private func audio(seconds: Int, name: String = "audio.wav") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let rate = Double(Limits.asrRate)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * Limits.asrRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { samples[i] = 0 }
        for n in 0..<seconds {
            let start = n * Limits.asrRate + Limits.asrRate / 4
            for i in start..<(start + Limits.asrRate * 3 / 10) { samples[i] = Float(n + 1) / 100 }
        }
        try file.write(from: buffer)
        return url
    }

    /// Installs `model` as sparse files of its pinned sizes, with its marker.
    private func install(_ model: ModelDescriptor, marker: Bool = true) throws {
        let directory = model.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for artifact in model.artifacts {
            let url = directory.appendingPathComponent(artifact.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(artifact.size))
            try handle.close()
        }
        if marker { try Data(model.markerValue.utf8).write(to: directory.appendingPathComponent(model.markerFile)) }
    }

    /// What the fake runtime saw.
    final class Native: @unchecked Sendable {
        let lock = NSLock()
        var loads = 0, detectors = 0, decodes = 0
        var threads: Set<String> = []
        var failsLoading = false
        /// Each decode waits this long first.
        var decodeDelay: TimeInterval = 0

        func record(_ body: (Native) -> Void) { lock.withLock { body(self) } }
        var counts: (loads: Int, detectors: Int, decodes: Int) { lock.withLock { (loads, detectors, decodes) } }

        var runtime: SpeechRuntime {
            SpeechRuntime(makeDecoder: { [self] _ in
                record { $0.loads += 1; $0.threads.insert(Thread.current.name ?? "") }
                if lock.withLock({ failsLoading }) { throw CocoaError(.fileReadCorruptFile) }
                return Recognizer(self)
            }, makeDetector: { [self] _ in
                record { $0.detectors += 1 }
                return Detector()
            })
        }
    }

    final class Recognizer: SpeechDecoding {
        let native: Native
        init(_ native: Native) { self.native = native }
        func decode(_ samples: [Float]) throws -> RecognizedTokens {
            native.record { $0.decodes += 1; $0.threads.insert(Thread.current.name ?? "") }
            let delay = native.lock.withLock { native.decodeDelay }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            var tokens: [String] = [], timestamps: [Float] = [], durations: [Float] = []
            var p = 0
            while p < samples.count {
                let value = samples[p]
                if value == 0 { p += 1; continue }
                let first = p
                while p < samples.count && samples[p] == value { p += 1 }
                tokens.append("▁w\(Int((value * 100).rounded()) - 1)")
                timestamps.append(Float(first) / Float(Limits.asrRate))
                durations.append(Float(p - first) / Float(Limits.asrRate))
            }
            return RecognizedTokens(text: tokens.joined(), tokens: tokens, timestamps: timestamps, durations: durations)
        }
    }

    final class Detector: SpeechDetecting {
        private var fed: [Float] = []
        private var segments: [SpeechFeed.Segment] = []
        private var open: Int?
        func reset() { fed = []; segments = []; open = nil }
        func acceptWaveform(_ window: [Float]) {
            let start = fed.count
            fed += window
            let speech = window.contains { $0 != 0 }
            if speech, open == nil { open = start }
            if !speech, let first = open { segments.append(.init(first, Array(fed[first..<start]))); open = nil }
        }
        func empty() -> Bool { segments.isEmpty }
        func front() -> SpeechFeed.Segment { segments[0] }
        func pop() { segments.removeFirst() }
        func flush() { if let first = open { segments.append(.init(first, Array(fed[first...]))); open = nil } }
    }

    /// The installer's calls.
    final class Installs: @unchecked Sendable {
        let lock = NSLock()
        var calls: [Set<ModelPart>] = []
        var outcome: InstallOutcome = .installed()
        var onInstall: @Sendable () throws -> Void = {}
        var list: [Set<ModelPart>] { lock.withLock { calls } }

        var install: ParakeetTranscriber.Models.Install {
            { [self] parts, progress in
                lock.withLock { calls.append(parts) }
                progress(DownloadProgress(part: .speech, doneBytes: 1, totalBytes: 2, verifying: false))
                try lock.withLock { onInstall }()
                return lock.withLock { outcome }
            }
        }
    }

    final class Events: Sendable {
        private let list = Mutex<[TranscriptionEvent]>([])
        var all: [TranscriptionEvent] { list.withLock { $0 } }
        var windows: [TranscriptWindow] { all.compactMap { if case .window(let w) = $0 { w } else { nil } } }
        var preparing: Int { all.filter { if case .preparingModel = $0 { true } else { false } }.count }
        func add(_ event: TranscriptionEvent) { list.withLock { $0.append(event) } }
    }

    private func transcriber(_ native: Native, online: Bool = false, installs: Installs? = nil,
                             memory: Int64? = nil) -> ParakeetTranscriber {
        ParakeetTranscriber(models: .init(root: root, online: { online }, install: installs?.install),
                            runtime: native.runtime, availableMemory: { memory })
    }

    private func run(_ transcriber: ParakeetTranscriber, _ url: URL, resume: TranscriptResume? = nil,
                     allowDownload: Bool = true) async throws -> (TranscriptionResult, Events) {
        let events = Events()
        let result = try await transcriber.transcribe(TranscriptionRequest(url: url, language: "it-IT", resume: resume,
                                                                           allowDownload: allowDownload)) { events.add($0) }
        return (result, events)
    }

    private func words(_ result: TranscriptionResult) -> [String] { result.segments.flatMap(\.draftWords).map(\.text) }

    // MARK: - Tests

    @Test func decodesIn28SecondWindowsWithTheSpeechDetectorOnItsOwnThread() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        try install(ModelCatalog.vad)
        let url = try audio(seconds: 70)
        let native = Native()
        let parakeet = transcriber(native)
        #expect(parakeet.recognizer == .parakeet)
        #expect(await parakeet.assetStatus(locale: Locale(identifier: "en-US")) == .ready)
        let (result, events) = try await run(parakeet, url)
        #expect(words(result) == (0..<70).map { "w\($0)" })
        #expect(result.segmentation == DecodeCutting.incrementalProvenance(detectorReady: true))
        #expect(result.segments.allSatisfy { $0.speakerID == nil }, "one voice until the speaker step")
        #expect(events.windows.map(\.recognition.doneMs) == [28_000, 54_000])
        #expect(events.windows.first?.words.map(\.text) == (0..<28).map { "w\($0)" })
        #expect(events.windows.allSatisfy { $0.words.allSatisfy(\.speaker.isEmpty) })
        #expect(events.preparing == 0, "nothing is downloaded")
        #expect(native.counts.loads == 1 && native.counts.detectors == 1, "one recognizer for every window")
        #expect(native.threads == ["Cassini speech"])
        guard case .progress(let done, let total) = try #require(events.all.last) else { Issue.record("no progress"); return }
        #expect(done == 70 && total == 70)
    }

    @Test func withoutTheSpeechDetectorItCutsAtQuietPoints() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        let url = try audio(seconds: 30)
        let native = Native()
        let parakeet = transcriber(native)
        let (result, _) = try await run(parakeet, url)
        #expect(words(result) == (0..<30).map { "w\($0)" })
        #expect(result.segmentation == DecodeCutting.incrementalProvenance(detectorReady: false))
        #expect(await parakeet.segmentation() == DecodeCutting.incrementalProvenance(detectorReady: false))
        #expect(native.counts.detectors == 0)
    }

    /// Android's `IncrementalRecognizer.inferenceMs`: the time of each window's decode, summed over the run.
    @Test func theInferenceTimeIsEachWindowsDecode() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        try install(ModelCatalog.vad)
        let url = try audio(seconds: 30)
        let native = Native()
        native.decodeDelay = 0.02
        let (result, events) = try await run(transcriber(native), url)
        let windowMs = try #require(events.windows.first?.inferenceMs)
        let inferenceMs = try #require(result.inferenceMs)
        #expect(windowMs >= 20)
        #expect(inferenceMs >= windowMs + 20, "the last window adds its own")
        #expect(inferenceMs >= Int64(native.counts.decodes) * 20)
    }

    // ports: TranscriptionJobTest#aMissingSpeechDetectorIsFetchedAgainOnlyOnline
    @Test func aMissingSpeechDetectorIsFetchedAgainOnlyOnline() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        let url = try audio(seconds: 3)
        let online = Installs()
        let (_, onlineEvents) = try await run(transcriber(Native(), online: true, installs: online), url)
        #expect(online.list == [[.speech]])
        #expect(onlineEvents.preparing > 0)

        let offline = Installs()
        let (result, offlineEvents) = try await run(transcriber(Native(), online: false, installs: offline), url)
        #expect(offline.list.isEmpty)
        #expect(offlineEvents.preparing == 0)
        #expect(words(result) == ["w0", "w1", "w2"])

        // The detector's install is best effort: a failure still transcribes.
        let failing = Installs()
        failing.outcome = .failed(part: .speech, error: .noConnection, requiredFreeBytes: 0)
        let (fallback, _) = try await run(transcriber(Native(), online: true, installs: failing), url)
        #expect(words(fallback) == ["w0", "w1", "w2"])
    }

    @Test func aMissingModelNeedsConsentOrIsInstalled() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try audio(seconds: 3)
        let native = Native()
        let installs = Installs()
        let parakeet = transcriber(native, online: true, installs: installs)
        #expect(await parakeet.assetStatus(locale: Locale(identifier: "it-IT")) == .notDownloaded)
        await #expect(throws: TranscriptionError.needsConsent) { try await run(parakeet, url, allowDownload: false) }
        #expect(installs.list.isEmpty)

        installs.outcome = .failed(part: .speech, error: .notEnoughStorage, requiredFreeBytes: 1)
        await #expect(throws: TranscriptionError.failed(.download(.notEnoughStorage))) { try await run(parakeet, url) }

        let models = ModelCatalog.parakeet
        installs.outcome = .installed()
        installs.onInstall = { [self] in try install(models) }
        let (result, events) = try await run(parakeet, url)
        #expect(words(result) == ["w0", "w1", "w2"])
        #expect(events.preparing >= 2, "nil first, then the fraction")
        #expect(native.counts.loads == 1)

        // A build that installs nothing itself cannot transcribe without the model.
        try FileManager.default.removeItem(at: root)
        await #expect(throws: TranscriptionError.failed(.model)) { try await run(transcriber(Native()), url) }
    }

    @Test func noNativeObjectIsMadeWithoutTheMarkerOrWithAFileMissing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet, marker: false)
        let url = try audio(seconds: 3)
        let native = Native()
        // Without its marker the model is not installed: no download allowed, nothing loads.
        await #expect(throws: TranscriptionError.needsConsent) { try await run(transcriber(native), url, allowDownload: false) }
        await #expect(throws: TranscriptionError.failed(.model)) { try await run(transcriber(native), url) }
        // A file of the wrong size is not the pinned model either.
        try install(ModelCatalog.parakeet)
        let encoder = try FileHandle(forWritingTo: ParakeetFiles(root: root).encoder)
        try encoder.truncate(atOffset: 1)
        try encoder.close()
        await #expect(throws: TranscriptionError.needsConsent) { try await run(transcriber(native), url, allowDownload: false) }
        #expect(native.counts.loads == 0)
    }

    @Test func aRecognizerThatCannotLoadFailsWithModel() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        let native = Native()
        native.failsLoading = true
        await #expect(throws: JobFailure.model) { try await run(transcriber(native), try audio(seconds: 3)) }
    }

    @Test func tooLittleMemoryFailsBeforeTheLoad() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        let native = Native()
        await #expect(throws: JobFailure.memory) {
            try await run(transcriber(native, memory: 500 << 20), try audio(seconds: 3))
        }
        #expect(native.counts.loads == 0)
        let (result, _) = try await run(transcriber(Native(), memory: 2 << 30), try audio(seconds: 3, name: "b.wav"))
        #expect(words(result) == ["w0", "w1", "w2"])
    }

    // ports: TranscriptionJobTest#stopAtAWindowThenResumeEqualsAnUninterruptedRun (the transcriber's part)
    @Test func aResumedRunDecodesWhatAnUninterruptedOneDoes() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        try install(ModelCatalog.vad)
        let url = try audio(seconds: 70)
        let (whole, events) = try await run(transcriber(Native()), url)
        let first = try #require(events.windows.first)

        let native = Native()
        let (resumed, resumedEvents) = try await run(transcriber(native), url,
                                                     resume: TranscriptResume(recognition: first.recognition, words: first.words))
        #expect(words(resumed) == words(whole))
        #expect(resumed.segments.flatMap(\.draftWords) == whole.segments.flatMap(\.draftWords))
        #expect(resumedEvents.windows.map(\.recognition) == Array(events.windows.dropFirst()).map(\.recognition))
        guard case .progress(let done, _) = try #require(resumedEvents.all.first) else { Issue.record("no progress"); return }
        #expect(done == 28, "a resumed run starts from its checkpoint")
    }

    @Test func aCheckpointPastTheEndOfTheAudioIsNotResumed() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        let url = try audio(seconds: 3)
        let beyond = RecognitionCheckpoint(start: 416_000, end: 448_000, position: 448_000)
        await #expect(throws: TranscriptionError.failed(.open)) {
            try await run(transcriber(Native()), url, resume: TranscriptResume(recognition: beyond, words: []))
        }
        let invalid = RecognitionCheckpoint(start: 10, end: 5, position: 20)
        await #expect(throws: TranscriptionError.failed(.checkpointMismatch)) {
            try await run(transcriber(Native()), url, resume: TranscriptResume(recognition: invalid, words: []))
        }
    }

    @Test func anUnreadableFileFailsWithOpen() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("broken.wav")
        try Data("not audio".utf8).write(to: url)
        await #expect(throws: TranscriptionError.failed(.open)) { try await run(transcriber(Native()), url) }
    }

    // ports: TranscriptionJobTest#cancelInsideASlowNativeCallKeepsThePreviousCheckpointAndReleasesHandles
    @Test func aCancelStopsBeforeTheNextNativeCall() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        let url = try audio(seconds: 70)
        let native = Native()
        native.decodeDelay = 0.3
        let parakeet = transcriber(native)
        let task = Task { try await run(parakeet, url) }
        while native.counts.decodes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let decodes = native.counts.decodes
        try await Task.sleep(for: .milliseconds(500))
        #expect(native.counts.decodes == decodes, "nothing decodes after the cancel")
        #expect(decodes < 3)
    }

    /// The streaming speakers of a run: each window's words go to them after the decode, on the speech thread with the
    /// recognizer; each window reports their state with its words, the result the last state, and the diarizer goes
    /// when the run ends (Android's `onChunk`).
    @Test func eachWindowsWordsGetTheirSpeakersOnTheSpeechThread() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        let url = try audio(seconds: 70)
        let threads = Mutex<Set<String>>([])
        let engines = FakeSpeakerEngines { startMs, durationMs in
            threads.withLock { $0.insert(Thread.current.name ?? "") }
            // Slot 2 until 35 s, slot 5 after it.
            let change = 35_000 - startMs
            return [DiarizerTurn(0, min(max(change, 0), durationMs), 2), DiarizerTurn(max(change, 0), durationMs, 5)]
                .filter { $0.endMs > $0.startMs }
        }
        let speakers = try WindowSpeakers(engines: engines, clips: MemoryClips(), prefix: "P_")
        let events = Events()
        let result = try await transcriber(Native()).transcribe(
            TranscriptionRequest(url: url, language: "", allowDownload: true, speakers: speakers)) { events.add($0) }
        let words = result.segments.flatMap(\.draftWords)
        #expect(words.map(\.text) == (0..<70).map { "w\($0)" })
        #expect(words.prefix(35).allSatisfy { $0.speaker == "P_3" } && words.suffix(35).allSatisfy { $0.speaker == "P_6" })
        #expect(events.windows.first?.words.allSatisfy { $0.speaker == "P_3" } == true, "the first window's words")
        #expect(events.windows.compactMap(\.speakers?.diarizer?.cache) == [[1], [2]])
        #expect(result.speakers?.diarizer?.cache == [3], "the last window too")
        #expect((result.speakers?.clipSamples ?? 0) > 0)
        #expect(threads.withLock { $0 } == ["Cassini speech"])
        #expect(engines.opened.count == 1)
        #expect(speakers.turns.map(\.speaker).uniqued() == [2, 5], "the turns stay once the diarizer is released")
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
