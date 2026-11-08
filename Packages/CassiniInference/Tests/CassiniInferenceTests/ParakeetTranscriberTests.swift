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
/// magnitude (N + 1) / 100, alternating in sign, a quarter second into second N. The fake recognizer turns each burst
/// into a timed token; the fake detector finds each burst in what it hears, the high-passed track (D26.1), which keeps
/// such a burst and would take a steady one away. The model files are sparse files of the pinned sizes in their
/// revision directories; the per-session check passes unless a test says otherwise.
@Suite(.serialized) struct ParakeetTranscriberTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var root: URL { folder.appendingPathComponent("models", isDirectory: true) }

    // MARK: - Fixtures

    /// The samples of `audio(seconds:offset:)`.
    static func samples(seconds: Int, offset: Float = 0) -> [Float] {
        var samples = [Float](repeating: offset, count: seconds * Limits.asrRate)
        for n in 0..<seconds {
            let start = n * Limits.asrRate + Limits.asrRate / 4
            for i in start..<(start + Limits.asrRate * 3 / 10) { samples[i] = offset + (i % 2 == 0 ? 1 : -1) * Float(n + 1) / 100 }
        }
        return samples
    }

    /// With an `offset`, every sample carries that DC, as from a microphone with an ADC offset.
    private func audio(seconds: Int, offset: Float = 0, name: String = "audio.wav") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let rate = Double(Limits.asrRate)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * Limits.asrRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for (i, sample) in Self.samples(seconds: seconds, offset: offset).enumerated() { samples[i] = sample }
        try file.write(from: buffer)
        return url
    }

    /// Installs `model` as sparse files of its pinned sizes in its revision directory, with the host's notices.
    private func install(_ model: ModelDescriptor, notice: Bool = true) throws {
        let directory = model.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for artifact in model.artifacts {
            let url = directory.appendingPathComponent(artifact.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(artifact.size))
            try handle.close()
        }
        if notice { try Data("notices".utf8).write(to: directory.appendingPathComponent(ModelDescriptor.noticeFile)) }
    }

    /// What the fake runtime saw.
    final class Native: @unchecked Sendable {
        let lock = NSLock()
        var loads = 0, detectors = 0, decodes = 0
        /// Recognizers released: a run's go when it ends.
        var releases = 0
        /// What the detectors heard, one entry for each reset: a window's input.
        var heard: [[Float]] = []
        var threads: Set<String> = []
        var failsLoading = false
        /// Each decode waits this long first.
        var decodeDelay: TimeInterval = 0
        /// Off, the recognizer hears no words: for audio whose bursts it cannot read, such as audio with an offset.
        var hearsWords = true

        func record(_ body: (Native) -> Void) { lock.withLock { body(self) } }
        var counts: (loads: Int, detectors: Int, decodes: Int) { lock.withLock { (loads, detectors, decodes) } }

        var runtime: SpeechRuntime {
            SpeechRuntime(makeDecoder: { [self] _ in
                record { $0.loads += 1; $0.threads.insert(Thread.current.name ?? "") }
                if lock.withLock({ failsLoading }) { throw CocoaError(.fileReadCorruptFile) }
                return Recognizer(self)
            }, makeDetector: { [self] _ in
                record { $0.detectors += 1 }
                return Detector(self)
            })
        }
    }

    final class Recognizer: SpeechDecoding {
        let native: Native
        init(_ native: Native) { self.native = native }
        deinit { native.record { $0.releases += 1 } }
        func decode(_ samples: [Float]) throws -> RecognizedTokens {
            native.record { $0.decodes += 1; $0.threads.insert(Thread.current.name ?? "") }
            let delay = native.lock.withLock { native.decodeDelay }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard native.lock.withLock({ native.hearsWords }) else {
                return RecognizedTokens(text: "", tokens: [], timestamps: [], durations: [])
            }
            var tokens: [String] = [], timestamps: [Float] = [], durations: [Float] = []
            var p = 0
            while p < samples.count {
                let value = abs(samples[p])
                if value == 0 { p += 1; continue }
                let first = p
                while p < samples.count && abs(samples[p]) == value { p += 1 }
                tokens.append("▁w\(Int((value * 100).rounded()) - 1)")
                timestamps.append(Float(first) / Float(Limits.asrRate))
                durations.append(Float(p - first) / Float(Limits.asrRate))
            }
            return RecognizedTokens(text: tokens.joined(), tokens: tokens, timestamps: timestamps, durations: durations)
        }
    }

    final class Detector: SpeechDetecting {
        let native: Native
        private var fed: [Float] = []
        private var segments: [SpeechFeed.Segment] = []
        private var open: Int?
        init(_ native: Native) { self.native = native }
        func reset() {
            fed = []; segments = []; open = nil
            native.record { $0.heard.append([]) }
        }
        func acceptWaveform(_ window: [Float]) {
            let start = fed.count
            fed += window
            native.record { $0.heard[$0.heard.count - 1] += window }
            let speech = window.contains { abs($0) >= 0.001 }
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
        /// What the install reports before it ends.
        var reports = [DownloadProgress(part: .speech, doneBytes: 1, totalBytes: 2, verifying: false)]
        var list: [Set<ModelPart>] { lock.withLock { calls } }

        var install: ParakeetTranscriber.Models.Install {
            { [self] parts, progress in
                lock.withLock { calls.append(parts) }
                for report in lock.withLock({ reports }) { progress(report) }
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

    /// A verifier that has checked every model already, as after an install in this session.
    private func checked() -> ModelVerifier {
        let verifier = ModelVerifier { _, _, _ in "" }
        for model in ModelCatalog.all { verifier.markVerified(model, in: root) }
        return verifier
    }

    /// The pinned SHA-256 of each file by name: a digest that finds every file as pinned.
    private static let pins = Dictionary(uniqueKeysWithValues: ModelCatalog.all.flatMap(\.artifacts).map { ($0.name, $0.sha256) })

    private func transcriber(_ native: Native, online: Bool = false, installs: Installs? = nil,
                             memory: Int64? = nil, verifier: ModelVerifier? = nil) -> ParakeetTranscriber {
        ParakeetTranscriber(models: .init(root: root, online: { online }, install: installs?.install,
                                          verifier: verifier ?? checked()),
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

    @Test func noNativeObjectIsMadeWithoutTheRevisionOrWithAFileMissing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet, notice: false)
        let url = try audio(seconds: 3)
        let native = Native()
        // Without its notices the revision is not complete: no download allowed, nothing loads.
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

    // MARK: - The check before the first load of a session (D16 §4)

    @Test func theFirstRunOfASessionChecksEveryFileOnTheSpeechThreadAndTheNextDoesNot() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        try install(ModelCatalog.vad)
        let url = try audio(seconds: 3)
        let hashed = Mutex<[String]>([]), threads = Mutex<Set<String>>([])
        let verifier = ModelVerifier { file, _, _ in
            hashed.withLock { $0.append(file.lastPathComponent) }
            threads.withLock { _ = $0.insert(Thread.current.name ?? "") }
            return Self.pins[file.lastPathComponent] ?? ""
        }
        let native = Native()
        let (first, events) = try await run(transcriber(native, verifier: verifier), url)
        #expect(words(first) == ["w0", "w1", "w2"])
        #expect(hashed.withLock { $0 } == ModelCatalog.parakeet.artifacts.map(\.name) + ["silero_vad.onnx"])
        #expect(threads.withLock { $0 } == ["Cassini speech"], "never on the cooperative pool")
        #expect(events.preparing == 1, "the Preparing stage while the files are checked")
        if case .preparingModel(nil) = events.all.first {} else { Issue.record("Preparing comes first: \(events.all)") }

        let (_, again) = try await run(transcriber(native, verifier: verifier), url)
        #expect(hashed.withLock { $0 }.count == 5, "checked once a session")
        #expect(again.preparing == 0)
    }

    /// A Parakeet file that fails its check: the revision is removed and the run fails with VERIFY ("Model
    /// verification failed. Please download it again."). Without an installer the next run fails with MODEL, or asks
    /// for consent; `aModelThatFailedItsCheckIsDownloadedAgainByTheNextRun` has the app's case.
    @Test func aFileThatFailsItsCheckFailsTheRunWithVerifyAndRemovesTheModel() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        try install(ModelCatalog.vad)
        let url = try audio(seconds: 3)
        let native = Native()
        let verifier = ModelVerifier { file, _, _ in
            file.lastPathComponent == "decoder.int8.onnx" ? "not the pin" : Self.pins[file.lastPathComponent] ?? ""
        }
        let parakeet = transcriber(native, verifier: verifier)
        let events = Events()
        await #expect(throws: TranscriptionError.failed(.modelVerify)) {
            _ = try await parakeet.transcribe(TranscriptionRequest(url: url, language: "it-IT", allowDownload: false)) {
                events.add($0)
            }
        }
        #expect(events.preparing == 1)
        #expect(native.counts.loads == 0 && native.counts.detectors == 0, "nothing loads")
        #expect(!ModelCatalog.parakeet.ready(in: root))
        #expect(!FileManager.default.fileExists(atPath: ModelCatalog.parakeet.directory(in: root).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: ModelCatalog.parakeet.directory(in: root)
            .deletingLastPathComponent().path).isEmpty, "retired by rename, then deleted")
        #expect(await parakeet.assetStatus(locale: Locale(identifier: "it-IT")) == .notDownloaded)
        await #expect(throws: TranscriptionError.failed(.model)) { try await run(parakeet, url) }
        await #expect(throws: TranscriptionError.needsConsent) { try await run(parakeet, url, allowDownload: false) }
        #expect(SpeechCapability.choose(linked: true, capable: true, apple: .init(hardwareAvailable: true, localeSupported: true, assets: .ready)) == .parakeet, "the device keeps Parakeet")
    }

    /// After a failed check the next run downloads Ultra again through the shared installer, as for a model that was
    /// never installed, and the files it installed count as checked.
    @Test func aModelThatFailedItsCheckIsDownloadedAgainByTheNextRun() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        let url = try audio(seconds: 3)
        let native = Native()
        let hashed = Mutex(0)
        let verifier = ModelVerifier { file, _, _ in
            hashed.withLock { $0 += 1 }
            return file.lastPathComponent == "encoder.int8.onnx" ? "not the pin" : Self.pins[file.lastPathComponent] ?? ""
        }
        let installs = Installs()
        let parakeet = transcriber(native, installs: installs, verifier: verifier)
        await #expect(throws: TranscriptionError.failed(.modelVerify)) { try await run(parakeet, url) }
        #expect(!ModelCatalog.parakeet.ready(in: root))
        #expect(installs.list.isEmpty, "the failed run downloads nothing")
        let checks = hashed.withLock { $0 }

        let model = ModelCatalog.parakeet, root = root
        installs.onInstall = { [self] in
            try install(model)
            verifier.markVerified(model, in: root)
        }
        let (result, events) = try await run(parakeet, url)
        #expect(installs.list == [[.speech]])
        #expect(events.preparing >= 2, "the download shows as Preparing")
        #expect(words(result) == ["w0", "w1", "w2"])
        #expect(native.counts.loads == 1)
        #expect(hashed.withLock { $0 } == checks, "an install counts as this session's check")
    }

    /// The standalone download (Settings, the model download screen): the fraction of the download, then Checking
    /// files, through the shared installer. The space it asks for is the speech part's `ModelPlan` figure.
    @Test func theStandaloneDownloadReportsTheDownloadThenCheckingFiles() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let installs = Installs()
        installs.reports = [DownloadProgress(part: .speech, doneBytes: 1, totalBytes: 4, verifying: false),
                            DownloadProgress(part: .speech, doneBytes: 4, totalBytes: 4, verifying: true)]
        let model = ModelCatalog.parakeet
        installs.onInstall = { [self] in try install(model) }
        let parakeet = transcriber(Native(), online: true, installs: installs)
        let fresh = ModelPlan([ModelPlan.Item(.speech, [ModelCatalog.parakeet, ModelCatalog.vad])]).requiredFreeBytes
        #expect(parakeet.assetInstallBytes == fresh)
        let reports = Mutex<[InstallProgress]>([])
        try await parakeet.installAssets(locale: Locale(identifier: "it-IT")) { report in reports.withLock { $0.append(report) } }
        #expect(reports.withLock { $0 } == [.downloading(0.25), .checking])
        #expect(installs.list == [[.speech]])
        #expect(await parakeet.assetStatus(locale: Locale(identifier: "it-IT")) == .ready)
        #expect(parakeet.assetInstallBytes == fresh, "an installed Ultra asks for a fresh install's figure")

        try await parakeet.installAssets(locale: Locale(identifier: "it-IT")) { _ in }
        #expect(installs.list.count == 1, "nothing to install")
    }

    @Test func aDetectorThatFailsItsCheckIsRemovedAndTheRunGoesOn() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        try install(ModelCatalog.vad)
        let url = try audio(seconds: 30)
        let native = Native()
        let verifier = ModelVerifier { file, _, _ in
            file.lastPathComponent == ModelCatalog.sileroVad.name ? "" : Self.pins[file.lastPathComponent] ?? ""
        }
        let (result, _) = try await run(transcriber(native, verifier: verifier), url)
        #expect(words(result) == (0..<30).map { "w\($0)" })
        #expect(result.segmentation == DecodeCutting.incrementalProvenance(detectorReady: false))
        #expect(native.counts.detectors == 0)
        #expect(!ModelCatalog.vad.ready(in: root))
        #expect(ModelCatalog.parakeet.ready(in: root))
    }

    /// The check stops at the run's cancel flag; a stopped check is not recorded, so the next run checks again.
    @Test func aCancelledCheckStopsTheRunAndIsDoneAgainNextTime() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        let url = try audio(seconds: 3)
        let started = Mutex(false), stopping = Mutex(true), neverCancelled = Mutex(false)
        let verifier = ModelVerifier { file, cancelled, _ in
            started.withLock { $0 = true }
            // A hash in progress, block by block, until the run's cancel flag is set; bounded, so a cancel that never
            // reaches the check fails the test instead of hanging it.
            let deadline = ContinuousClock.now + .seconds(30)
            while stopping.withLock({ $0 }) {
                if cancelled() { throw CancellationError() }
                if ContinuousClock.now > deadline {
                    neverCancelled.withLock { $0 = true }
                    throw POSIXError(.ETIMEDOUT)
                }
            }
            return Self.pins[file.lastPathComponent] ?? ""
        }
        let native = Native()
        let parakeet = transcriber(native, verifier: verifier)
        let task = Task { try await run(parakeet, url) }
        let deadline = ContinuousClock.now + .seconds(20)
        while !started.withLock({ $0 }) {
            guard ContinuousClock.now < deadline else { Issue.record("The check never started"); return }
            await Task.yield()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!neverCancelled.withLock { $0 }, "the cancel flag never reached the check")
        #expect(!verifier.isChecked(ModelCatalog.parakeet, in: root))
        #expect(ModelCatalog.parakeet.ready(in: root), "a stopped check removes nothing")
        #expect(native.counts.loads == 0)

        stopping.withLock { $0 = false }
        let (result, events) = try await run(parakeet, url)
        #expect(words(result) == ["w0", "w1", "w2"])
        #expect(events.preparing == 1, "checked again")
        #expect(verifier.isChecked(ModelCatalog.parakeet, in: root))
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

    /// D26.1: the detector hears the track through one `SpeechInputFilter` run in reading order, so each window's
    /// input, the 2 s it shares with the window before included, is a stretch of that one filtered track. A resumed
    /// run's filter starts from zero at its restored window and runs on the same way from there. The recording
    /// carries the failing microphone's offset, so a filter started afresh at a window would differ.
    /// A run resumed in a session whose detector fails its check goes on at quiet points, and its segmentation names
    /// quiet points for the whole transcript. The checkpoint does not record how its earlier windows were cut (nor does
    /// Android's), and the detector is best effort: one installed, missing or unmakeable between two runs mixes the same
    /// way. The words are the recognizer's; only the provenance's cut mode covers both.
    @Test func aResumedRunWhoseDetectorFailsItsCheckGoesOnAtQuietPoints() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        try install(ModelCatalog.vad)
        let url = try audio(seconds: 70)
        let (whole, events) = try await run(transcriber(Native()), url)
        #expect(whole.segmentation == DecodeCutting.incrementalProvenance(detectorReady: true))
        let first = try #require(events.windows.first)

        let verifier = ModelVerifier { file, _, _ in
            file.lastPathComponent == ModelCatalog.sileroVad.name ? "" : Self.pins[file.lastPathComponent] ?? ""
        }
        let native = Native()
        let (resumed, _) = try await run(transcriber(native, verifier: verifier), url,
                                         resume: TranscriptResume(recognition: first.recognition, words: first.words))
        #expect(words(resumed) == (0..<70).map { "w\($0)" })
        #expect(resumed.segmentation == DecodeCutting.incrementalProvenance(detectorReady: false))
        #expect(native.counts.detectors == 0)
        #expect(!ModelCatalog.vad.ready(in: root), "the detector's revision is retired")
    }

    @Test func theDetectorHearsTheTrackHighPassedOnceAcrossWindows() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.parakeet)
        try install(ModelCatalog.vad)
        let offset: Float = -2060.0 / 32768
        let url = try audio(seconds: 70, offset: offset)
        let raw = Self.samples(seconds: 70, offset: offset)
        let window = IncrementalTranscript.windowSamples, step = window - IncrementalTranscript.overlapSamples
        func expected(from start: Int, _ heard: [[Float]]) -> [[Float]] {
            var filter = SpeechInputFilter()
            let track = [Float](repeating: 0, count: start) + filter(raw[start...])
            return heard.indices.map { n in
                let first = start + n * step, last = min(first + window, raw.count)
                // SpeechFeed zero-pads the last 512-sample frame.
                return Array(track[first..<last]) + [Float](repeating: 0, count: heard[n].count - (last - first))
            }
        }
        let native = Native()
        native.hearsWords = false
        let (_, events) = try await run(transcriber(native), url)
        let heard = native.lock.withLock { native.heard }
        #expect(heard.count == 3)
        #expect(heard == expected(from: 0, heard))
        var fresh = SpeechInputFilter()
        #expect(Array(heard[1].prefix(512)) != fresh(raw[step..<(step + 512)]), "a window's filter carries the state of the one before")

        let first = try #require(events.windows.first)
        let resumedNative = Native()
        resumedNative.hearsWords = false
        _ = try await run(transcriber(resumedNative), url, resume: TranscriptResume(recognition: first.recognition, words: first.words))
        let resumedHeard = resumedNative.lock.withLock { resumedNative.heard }
        #expect(resumedHeard.count == 2, "the resumed run's two windows")
        #expect(resumedHeard == expected(from: Int(first.recognition.start), resumedHeard))
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
        try await waitUntil("The first decode never started") { native.counts.decodes > 0 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let decodes = native.counts.decodes
        // The run's end releases its recognizer: no decode can come after it.
        try await waitUntil("The recognizer was never released") { native.lock.withLock { native.releases } == 1 }
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

/// Polls `condition` until it holds, for at most twenty seconds; then records `message` and throws.
private func waitUntil(_ message: Comment, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record(message)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
