import AVFoundation
import CassiniCore
import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import CassiniInference

/// `SpeakerAnalyzer` over a fake native runtime: the whole-file analysis of a speakers-only job or an Apple Speech
/// transcription (streaming Sortformer in the job's 28 s windows, then CAM++ from the clips), the engines a Parakeet
/// run streams with, and the models' status. The model files are sparse files of the pinned sizes in their revision
/// directories; the per-session check passes unless a test says otherwise.
@Suite(.serialized) struct SpeakerAnalyzerTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var root: URL { folder.appendingPathComponent("models", isDirectory: true) }

    private struct Consent: ModelConsentRecords {
        func consentAt() async -> Date? { nil }
        func recordConsent() async {}
        func recordDeclined() async {}
    }

    private struct Unused: ModelFetching {
        func fetch(_ model: ModelDescriptor, into directory: URL,
                   progress: @escaping @Sendable (Int64, Bool) -> Void) async throws { throw ModelError(.modelDownload) }
    }

    private struct Unlimited: StorageProbe {
        func availableBytes(at url: URL) -> Int64 { .max }
    }

    /// A verifier that has checked every model already, as after an install in this session.
    private func checked() -> ModelVerifier {
        let verifier = ModelVerifier { _, _, _ in "" }
        for model in ModelCatalog.all { verifier.markVerified(model, in: root) }
        return verifier
    }

    private func analyzer(_ engines: FakeSpeakerEngines, linked: Bool = true,
                          verifier: ModelVerifier? = nil) -> SpeakerAnalyzer {
        let repository = ModelRepository(root: root, consent: Consent(), fetcher: Unused(), verifier: verifier ?? checked())
        let installer = PinnedModelInstaller(models: repository, storage: Unlimited(), online: { true })
        let runtime = SpeakerRuntime(linked: linked, makeDiarizer: { _, restored in try engines.openDiarizer(restored: restored) },
                                     prints: { _, audio, windows, active in try engines.prints(audio, windows: windows, active: active) })
        return SpeakerAnalyzer(models: SpeakerModels(repository: repository, installer: installer), runtime: runtime,
                               availableMemory: { nil })
    }

    private func install(_ model: ModelDescriptor) throws {
        let directory = model.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for artifact in model.artifacts {
            let url = directory.appendingPathComponent(artifact.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(artifact.size))
            try handle.close()
        }
        try Data("notices".utf8).write(to: directory.appendingPathComponent(ModelDescriptor.noticeFile))
    }

    /// `seconds` of quiet 16 kHz audio.
    private func audio(seconds: Int) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("audio.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16_000)))
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = 0.01 }
        try file.write(from: buffer)
        return url
    }

    /// A until 35 s, B after it, on the window's clock.
    private static let twoSpeakers: FakeSpeakerEngines.Turns = { startMs, durationMs in
        let change = 35_000 - startMs
        return [DiarizerTurn(0, min(max(change, 0), durationMs), 0), DiarizerTurn(max(change, 0), durationMs, 1)]
            .filter { $0.endMs > $0.startMs }
    }

    private let words = (0..<70).map { Word("old", Int64($0) * 1000, Int64($0) * 1000 + 800, "w\($0)") }

    @Test func theWholeFileIsReadInTheJobsWindowsAndEachSpeakerGetsAPrint() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.diarization)
        try install(ModelCatalog.voiceprint)
        let engines = FakeSpeakerEngines(turns: Self.twoSpeakers)
        let speakers = analyzer(engines)
        #expect(await speakers.modelStatus() == .ready)
        let fractions = Mutex<[Double]>([])
        let analysis = try await speakers.analyze(url: try audio(seconds: 70), words: words, allowDownload: false) { event in
            if case .analyzing(let fraction) = event { fractions.withLock { $0.append(fraction) } }
        }
        // Windows at 0, 26 and 52 s; the turns on the recording clock, with ids of the analysis's own.
        #expect(engines.opened == [nil])
        #expect(analysis.turns.map(\.speakerID).uniqued() == ["1", "2"])
        #expect(analysis.turns.first?.start == 0 && analysis.turns.last?.end == 70)
        #expect(analysis.transcript == nil, "the note attributes its own words")
        #expect(analysis.streaming && analysis.printsReady)
        #expect(analysis.prints.map(\.speakerID) == ["1", "2"])
        #expect(analysis.prints.allSatisfy { $0.model == VoiceprintModel.sha256 && $0.vector.count == 512 })
        // The clips are the selection's: at most 45 s each, the words told apart by the window's turns.
        let requested = try #require(engines.printRequests.first)
        #expect(requested.values.allSatisfy { $0.reduce(0) { $0 + $1.endSample - $1.startSample } <= 45 * 16_000 })
        #expect(fractions.withLock { $0 }.last == 1)
        #expect(fractions.withLock { $0 } == fractions.withLock { $0 }.sorted())
    }

    @Test func withoutTheVoiceprintModelTheSpeakersAreToldApartWithoutPrints() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.diarization)
        let engines = FakeSpeakerEngines(turns: Self.twoSpeakers)
        let speakers = analyzer(engines)
        #expect(await speakers.modelStatus() == .notDownloaded, "the row needs both")
        #expect(await speakers.streamingEngines() != nil, "a Parakeet run still tells speakers apart")
        #expect(await speakers.printsReady() == false)
        let analysis = try await speakers.analyze(url: try audio(seconds: 30), words: words, allowDownload: false) { _ in }
        #expect(analysis.turns.map(\.speakerID).uniqued() == ["1"])
        #expect(analysis.prints.isEmpty && !analysis.printsReady)
        #expect(engines.printRequests.isEmpty)
        // Without the diarizer nothing can be told apart, and nothing is fetched without consent.
        try FileManager.default.removeItem(at: ModelCatalog.diarization.directory(in: root))
        await #expect(throws: SpeakerAnalysisError.needsConsent) {
            try await speakers.analyze(url: try audio(seconds: 30), words: words, allowDownload: false) { _ in }
        }
    }

    /// D16 §4 for the speaker models: hashed once a session, on the speech thread (never on the cooperative pool). A
    /// diarizer that fails its check is removed: the streaming run gets no engines (every word one voice, and the next
    /// run downloads it again), and a whole-file analysis fails with File check failed, whose Download again installs
    /// it. A CAM++ that fails is removed and the speakers are still told apart.
    @Test func aDiarizerThatFailsItsCheckGivesNoEngines() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.diarization)
        try install(ModelCatalog.voiceprint)
        let threads = Mutex<Set<String>>([])
        let bad = ModelVerifier { _, _, _ in
            threads.withLock { _ = $0.insert(Thread.current.name ?? "") }
            return "not the pin"
        }
        let speakers = analyzer(FakeSpeakerEngines(turns: Self.twoSpeakers), verifier: bad)
        #expect(await speakers.streamingEngines() == nil)
        #expect(threads.withLock { $0 } == ["Cassini speech"])
        #expect(!ModelCatalog.diarization.ready(in: root))
        #expect(!FileManager.default.fileExists(atPath: ModelCatalog.diarization.directory(in: root).path),
                "the revision is removed")
        #expect(ModelCatalog.voiceprint.ready(in: root), "CAM++ is checked only with a diarizer that passed")

        try install(ModelCatalog.diarization)
        await #expect(throws: SpeakerAnalysisError.download(.fileCheckFailed, requiredFreeBytes: 0)) {
            try await speakers.analyze(url: try audio(seconds: 30), words: words, allowDownload: false) { _ in }
        }
        #expect(!ModelCatalog.diarization.ready(in: root))
    }

    @Test func aVoiceprintModelThatFailsItsCheckIsRemovedAndTheSpeakersAreStillToldApart() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.diarization)
        try install(ModelCatalog.voiceprint)
        let pins = Dictionary(uniqueKeysWithValues: ModelCatalog.all.flatMap(\.artifacts).map { ($0.name, $0.sha256) })
        let hashed = Mutex(0)
        let verifier = ModelVerifier { file, _, _ in
            hashed.withLock { $0 += 1 }
            return file.lastPathComponent == ModelCatalog.voiceprintModel.name ? "" : pins[file.lastPathComponent] ?? ""
        }
        let speakers = analyzer(FakeSpeakerEngines(turns: Self.twoSpeakers), verifier: verifier)
        #expect(await speakers.streamingEngines() != nil)
        #expect(await speakers.printsReady() == false)
        #expect(!ModelCatalog.voiceprint.ready(in: root))
        #expect(hashed.withLock { $0 } == 2)
        // Checked once a session: the next run hashes nothing.
        #expect(await speakers.streamingEngines() != nil)
        #expect(hashed.withLock { $0 } == 2)
    }

    /// A file that cannot be read (EIO, EACCES) is never loaded unchecked and retires nothing: a diarizer gives no
    /// engines and fails the analysis with MODEL, not File check failed, whose Download again could not help (the
    /// files are still installed).
    @Test func aDiarizerThatCannotBeReadFailsWithModelAndStaysInstalled() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.diarization)
        try install(ModelCatalog.voiceprint)
        let unreadable = ModelVerifier { _, _, _ in throw POSIXError(.EIO) }
        let engines = FakeSpeakerEngines(turns: Self.twoSpeakers)
        let speakers = analyzer(engines, verifier: unreadable)
        #expect(await speakers.streamingEngines() == nil)
        await #expect(throws: JobFailure.model) {
            try await speakers.analyze(url: try audio(seconds: 30), words: words, allowDownload: true) { _ in }
        }
        #expect(engines.opened.isEmpty, "nothing loads")
        #expect(ModelCatalog.diarization.ready(in: root) && ModelCatalog.voiceprint.ready(in: root))
    }

    /// A CAM++ that cannot be read is left out until a check reads it: the speakers are told apart and nobody is named,
    /// and nothing is removed.
    @Test func aVoiceprintModelThatCannotBeReadIsLeftOutAndKept() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.diarization)
        try install(ModelCatalog.voiceprint)
        let pins = Dictionary(uniqueKeysWithValues: ModelCatalog.all.flatMap(\.artifacts).map { ($0.name, $0.sha256) })
        let unreadable = Mutex(true)
        let verifier = ModelVerifier { file, _, _ in
            if file.lastPathComponent == ModelCatalog.voiceprintModel.name, unreadable.withLock({ $0 }) {
                throw POSIXError(.EACCES)
            }
            return pins[file.lastPathComponent] ?? ""
        }
        let engines = FakeSpeakerEngines(turns: Self.twoSpeakers)
        let speakers = analyzer(engines, verifier: verifier)
        #expect(await speakers.streamingEngines() != nil)
        #expect(await speakers.printsReady() == false, "a Parakeet run collects no clips for it")
        let analysis = try await speakers.analyze(url: try audio(seconds: 70), words: words, allowDownload: false) { _ in }
        #expect(analysis.turns.map(\.speakerID).uniqued() == ["1", "2"])
        #expect(analysis.prints.isEmpty && !analysis.printsReady)
        #expect(engines.printRequests.isEmpty, "CAM++ never loads unchecked")
        #expect(ModelCatalog.voiceprint.ready(in: root), "nothing is removed")

        unreadable.withLock { $0 = false }
        #expect(await speakers.streamingEngines() != nil)
        #expect(await speakers.printsReady())
    }

    @Test func aDiarizerThatFailsAtTheFirstWindowFailsTheAnalysis() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.diarization)
        try install(ModelCatalog.voiceprint)
        let speakers = analyzer(FakeSpeakerEngines(failAt: 0, turns: Self.twoSpeakers))
        await #expect(throws: JobFailure.speakers) {
            try await speakers.analyze(url: try audio(seconds: 30), words: words, allowDownload: false) { _ in }
        }
    }

    @Test func aBuildWithoutTheRuntimeHasNoSpeakerModels() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.diarization)
        try install(ModelCatalog.voiceprint)
        let speakers = analyzer(FakeSpeakerEngines(turns: Self.twoSpeakers), linked: false)
        #expect(await speakers.modelStatus() == .unsupported)
        #expect(await speakers.streamingEngines() == nil)
        await #expect(throws: JobFailure.model) {
            try await speakers.analyze(url: try audio(seconds: 30), words: words, allowDownload: true) { _ in }
        }
    }

    @Test func theEnginesRunOnTheSpeechThread() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try install(ModelCatalog.diarization)
        let engines = try #require(await analyzer(FakeSpeakerEngines(turns: Self.twoSpeakers)).streamingEngines())
        #expect(try await engines.run { Thread.current.name } == "Cassini speech")
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
