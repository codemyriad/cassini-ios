import AVFoundation
import CassiniCore
import CassiniEngine
import CassiniNotebook

/// Android's speaker pipeline over the native runtime (`SpeakerRuntime`, CassiniSherpa's in the app): streaming
/// Sortformer and CAM++ from the catalog's pinned files (`SpeakerModels`).
///
/// - **During a Parakeet decode** the job asks for `streamingEngines()` and tells each window's speakers apart on the
///   transcriber's inference thread (`WindowSpeakers`).
/// - **After the words** (a speakers-only job, an Apple Speech transcription) `analyze` reads the whole file as 16 kHz
///   mono floats in the job's 28 s windows with 2 s overlap, gives each window to the same `WindowSpeakers` with the
///   transcript's words that fall in it, and makes a CAM++ print per speaker from the voice clips (kept in memory: at
///   most 45 s per speaker). It runs on the speech inference thread, one native body at a time.
/// - **Models.** Installed through the shared `PinnedModelInstaller` (Range resume, pinned SHA-256, the redirect
///   policy); the diarizer comes as seekable Zstandard. A build without the native runtime reports them unsupported.
public struct SpeakerAnalyzer: SpeakerAnalyzing {
    public let models: SpeakerModels
    private let runtime: SpeakerRuntime
    private let thread: InferenceThread
    private let availableMemory: @Sendable () -> Int64?

    public init(models: SpeakerModels, runtime: SpeakerRuntime,
                availableMemory: @escaping @Sendable () -> Int64? = TranscriptionJob.availableMemory) {
        self.init(models: models, runtime: runtime, availableMemory: availableMemory, thread: .speech)
    }

    init(models: SpeakerModels, runtime: SpeakerRuntime, availableMemory: @escaping @Sendable () -> Int64?,
         thread: InferenceThread) {
        self.models = models; self.runtime = runtime; self.availableMemory = availableMemory; self.thread = thread
    }

    public var modelInstallBytes: Int64 { models.installBytes }

    public func modelStatus() async -> ModelPartStatus { models.status(linked: runtime.linked) }

    public func refreshModelStatus() async -> ModelPartStatus { await models.refresh(linked: runtime.linked) }

    public func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        guard runtime.linked else { return }
        try await models.install(progress: progress)
    }

    public func cancelModelInstall() async { models.cancel() }

    public func printsReady() async -> Bool { runtime.linked && models.printsReady }

    public func streamingEngines() async -> (any SpeakerEngines)? {
        guard runtime.linked, models.diarizerReady else { return nil }
        return Engines(runtime: runtime, diarizer: models.diarizer, voiceprint: models.voiceprint, thread: thread)
    }

    public func analyze(url: URL, words: [Word], allowDownload: Bool,
                        progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        guard runtime.linked else { throw JobFailure.model }
        if !models.diarizerReady || !models.printsReady {
            // Without CAM++ the speakers are still told apart; without the diarizer nothing can be.
            if allowDownload {
                progress(.preparingModels(.downloading(nil)))
                try await models.install { progress(.preparingModels($0)) }
            } else if !models.diarizerReady {
                throw SpeakerAnalysisError.needsConsent
            }
        }
        guard let engines = await streamingEngines() else { throw JobFailure.model }
        let printsReady = models.printsReady, memory = availableMemory
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await thread.run {
                try Self.wholeFile(url, words: words, engines: engines, printsReady: printsReady, memory: memory,
                                   cancel: cancel, progress: progress)
            }
        } onCancel: {
            cancel.set()
        }
    }

    // MARK: - The whole file

    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(CassiniNotebook.Limits.asrRate),
                                      channels: 1, interleaved: false)!

    /// The whole-file analysis, on the inference thread: windows as `IncrementalTranscript` cuts them (28 s, the last
    /// 2 s carried into the next), each with the words that overlap it on its own clock.
    static func wholeFile(_ url: URL, words: [Word], engines: any SpeakerEngines, printsReady: Bool,
                          memory: @escaping @Sendable () -> Int64?, cancel: CancelFlag,
                          progress: (SpeakerAnalysisEvent) -> Void) throws -> SpeakerAnalysis {
        let reader: FileReader
        do { reader = try FileReader(url: url, from: 0, to: format, downmix: true) } catch { throw JobFailure.open }
        let totalSamples = max(1, Int64((reader.duration * Double(format.sampleRate)).rounded()))
        let clips: MemoryClips? = printsReady ? MemoryClips() : nil
        let speakers = try WindowSpeakers(engines: engines, clips: clips, prefix: "", availableMemory: memory)
        defer { speakers.close() }
        let windowSamples = IncrementalTranscript.windowSamples, overlap = IncrementalTranscript.overlapSamples
        let rate = Int64(format.sampleRate)
        let plain = words.map { Word("", $0.startMs, $0.endMs, $0.text) }
        var window: [Float] = []
        window.reserveCapacity(windowSamples)
        var start: Int64 = 0
        var decodedEnd: Int64 = 0
        func process() throws {
            try cancel.check()
            let startMs = start * 1000 / rate
            let audio = PcmAudio(window, sampleRate: Int(rate))
            let endMs = startMs + audio.durationMs
            let inside = plain.filter { $0.endMs > startMs && $0.startMs < endMs }.map {
                Word("", max($0.startMs, startMs) - startMs, min($0.endMs, endMs) - startMs, $0.text)
            }
            _ = try speakers.window(audio, startMs: startMs, words: Transcript(inside))
            decodedEnd = start + Int64(window.count)
            progress(.analyzing(min(1, Double(decodedEnd) / Double(totalSamples))))
        }
        while let (buffer, _) = reader.nextBuffer() {
            try cancel.check()
            let count = Int(buffer.frameLength)
            var samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)[...]
            while !samples.isEmpty {
                let n = min(windowSamples - window.count, samples.count)
                window.append(contentsOf: samples.prefix(n))
                samples = samples.dropFirst(n)
                if window.count == windowSamples {
                    try process()
                    window = Array(window.suffix(overlap))
                    start += Int64(windowSamples - overlap)
                }
            }
        }
        guard reader.failure == nil, reader.reachedEnd else { throw JobFailure.open }
        // An exact window end leaves just its overlap, which was analysed already.
        if start + Int64(window.count) > decodedEnd, !window.isEmpty { try process() }
        try cancel.check()
        guard !(speakers.failed && speakers.turns.isEmpty) else { throw JobFailure.speakers }
        var prints: [SpeakerPrint] = []
        if let clips, !speakers.clipWindows.isEmpty, SpeakerMemory.allows(availableBytes: memory(), SpeakerMemory.beforePrintsBytes) {
            // Best effort: without prints the speakers are still told apart, and nobody is named from a saved voice.
            let made = try? CheckedPrints.check(engines.prints(clips, windows: speakers.clipWindows) { try cancel.check() })
            try cancel.check()
            prints = (made ?? [:]).sorted { $0.key < $1.key }.map {
                SpeakerPrint(speakerID: $0.key, model: VoiceprintModel.sha256, vector: $0.value.vector,
                             speechSeconds: $0.value.seconds)
            }
        }
        return SpeakerAnalysis(turns: speakers.turns.map { $0.speakerTurn(prefix: "") }, prints: prints, transcript: nil,
                               elapsedMs: speakers.elapsedMs, streaming: true, printsReady: printsReady)
    }

    // MARK: - Engines

    /// The native models of the installed files, on the speech inference thread.
    struct Engines: SpeakerEngines {
        let runtime: SpeakerRuntime
        let diarizer: URL
        let voiceprint: URL
        let thread: InferenceThread

        func openDiarizer(restored: DiarizerState?) throws -> any StreamingDiarizer {
            try runtime.makeDiarizer(diarizer, restored)
        }

        func prints(_ audio: any PcmSource, windows: [String: [PrintWindow]],
                    active: () throws -> Void) throws -> [String: Voiceprint] {
            try runtime.prints(voiceprint, audio, windows, active)
        }

        func run<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
            try await thread.run(body)
        }
    }
}
