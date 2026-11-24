import AVFoundation
import CassiniCore
import CassiniEngine
import CassiniNotebook
import CassiniWhistle
import Foundation
import Synchronization

/// Resource and lifecycle signals inspected by `CAFPrefixPrecomputer` before starting and before every committed block.
public struct PrecomputePressure: Sendable {
    public var isAppActive: @Sendable () -> Bool
    public var thermalState: @Sendable () -> ProcessInfo.ThermalState
    public var availableMemory: @Sendable () -> Int64?
    public var hasForegroundSavedJob: @Sendable () -> Bool

    public init(
        isAppActive: @escaping @Sendable () -> Bool = { true },
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        availableMemory: @escaping @Sendable () -> Int64? = TranscriptionJob.availableMemory,
        hasForegroundSavedJob: @escaping @Sendable () -> Bool = { false }
    ) {
        self.isAppActive = isAppActive
        self.thermalState = thermalState
        self.availableMemory = availableMemory
        self.hasForegroundSavedJob = hasForegroundSavedJob
    }

    public func shouldYield(minMemoryBytes: Int64? = nil) -> Bool {
        if Task.isCancelled { return true }
        if !isAppActive() { return true }
        if thermalState().rawValue >= ProcessInfo.ThermalState.serious.rawValue { return true }
        if hasForegroundSavedJob() { return true }
        if let minMemoryBytes, let free = availableMemory(), free > 0, free < minMemoryBytes {
            return true
        }
        return false
    }
}

/// Read-only `.caf` prefix checkpoint runner (`transcribeWhileRecording`, `D-1123`).
///
/// - Never touches `AVAudioRecorder` or capture threads; opens `capture.caf` strictly read-only via `LiveCAFReader`
///   off the main actor at `.utility` priority, staying safely behind the writer cursor.
/// - Reuses the exact Parakeet (`IncrementalTranscript` + `ParakeetDecode` + `WindowSpeakers` + `clips.pcm`) and
///   Whistle (`WhistleResampler` + `WhistleVAD` + `WhistleSpeechGate` + `WhistlePipelineState`) pipelines, writing
///   standard prefix-verified `work/checkpoint.json` + `work/clips.pcm` checkpoints so post-Stop `TranscriptionJob`
///   resumes in O(1) from the last committed boundary.
/// - Yields immediately on pause, interruption, route change, backgrounding, thermal `>= .serious`, low headroom,
///   or `NativeBudget` preemption.
/// - In `recordOnly` or `afterStop` mode, allocates zero native models and spawns zero workers.
public final class CAFPrefixPrecomputer: RecordingPrecomputing, Sendable {
    public struct ParakeetEngine: Sendable {
        public var models: ParakeetTranscriber.Models
        public var runtime: SpeechRuntime
        public var speakerEngines: (@Sendable () async -> (any SpeakerEngines)?)?
        public var identifySpeakers: @Sendable () -> Bool
        public var printsReady: @Sendable () async -> Bool

        public init(
            models: ParakeetTranscriber.Models,
            runtime: SpeechRuntime,
            speakerEngines: (@Sendable () async -> (any SpeakerEngines)?)? = nil,
            identifySpeakers: @escaping @Sendable () -> Bool = { true },
            printsReady: @escaping @Sendable () async -> Bool = { true }
        ) {
            self.models = models
            self.runtime = runtime
            self.speakerEngines = speakerEngines
            self.identifySpeakers = identifySpeakers
            self.printsReady = printsReady
        }
    }

    public struct WhistleEngine: Sendable {
        public var acceptance: @Sendable () -> WhistleCapability
        public var bundle: Bundle
        var backend: WhistleSessionBackend
        var skipBundleVerification: Bool

        public init(acceptance: @escaping @Sendable () -> WhistleCapability, bundle: Bundle = .main) {
            self.acceptance = acceptance
            self.bundle = bundle
            self.backend = .live
            self.skipBundleVerification = false
        }

        init(acceptance: @escaping @Sendable () -> WhistleCapability, bundle: Bundle = .main,
             backend: WhistleSessionBackend, skipBundleVerification: Bool) {
            self.acceptance = acceptance
            self.bundle = bundle
            self.backend = backend
            self.skipBundleVerification = skipBundleVerification
        }
    }

    public enum EngineChoice: Sendable {
        case parakeet(ParakeetEngine)
        case whistle(WhistleEngine)
        case none
    }

    private struct ActiveState: Sendable {
        var noteID: UUID?
        var task: Task<Void, Never>?
        var cancelFlag: CancelFlag?
    }

    /// Default cadence (in seconds of processed audio) between periodic Whistle precompute checkpoint disk writes
    /// (`D111` §4). Pending settled state is always flushed immediately on Pause, Stop, Yield, or clean pass exit.
    public static let defaultWhistleCheckpointIntervalSeconds: UInt64 = 10

    private let checkpoints: any CheckpointStoring
    private let budget: NativeBudget
    private let mode: @Sendable () -> TranscriptionMode
    private let engine: @Sendable () -> EngineChoice
    private let pressure: PrecomputePressure
    private let safetyMarginFrames: UInt64
    private let pollInterval: Duration
    private let whistleCheckpointIntervalSeconds: UInt64
    private let onCheckpointSaved: (@Sendable (UUID, CheckpointState) -> Void)?
    private let state = Mutex(ActiveState())

    public init(
        checkpoints: any CheckpointStoring,
        budget: NativeBudget = .shared,
        mode: @escaping @Sendable () -> TranscriptionMode,
        engine: @escaping @Sendable () -> EngineChoice,
        pressure: PrecomputePressure = PrecomputePressure(),
        safetyMarginFrames: UInt64 = LiveCAFReader.defaultSafetyMarginFrames,
        pollInterval: Duration = .milliseconds(500),
        whistleCheckpointIntervalSeconds: UInt64 = defaultWhistleCheckpointIntervalSeconds,
        onCheckpointSaved: (@Sendable (UUID, CheckpointState) -> Void)? = nil
    ) {
        self.checkpoints = checkpoints
        self.budget = budget
        self.mode = mode
        self.engine = engine
        self.pressure = pressure
        self.safetyMarginFrames = safetyMarginFrames
        self.pollInterval = pollInterval
        self.whistleCheckpointIntervalSeconds = max(1, whistleCheckpointIntervalSeconds)
        self.onCheckpointSaved = onCheckpointSaved
    }

    public func start(noteID: UUID, captureURL: URL) {
        let policy = TranscriptionModePolicy.evaluate(
            rawMode: mode().rawValue,
            hasForegroundSavedJob: pressure.hasForegroundSavedJob(),
            manualTranscribeRequested: false,
            platformSupportsPrecompute: true
        )
        guard policy.spawnWorkerDuringRecording else { return }
        guard !pressure.shouldYield() else { return }

        let cancel = CancelFlag()
        let previous: (Task<Void, Never>?, CancelFlag?) = state.withLock { s in
            if s.noteID == noteID, s.task != nil { return (nil, nil) }
            let old = (s.task, s.cancelFlag)
            s.noteID = noteID
            s.cancelFlag = cancel
            s.task = Task.detached(priority: .utility) { [weak self] in
                old.1?.set()
                old.0?.cancel()
                await old.0?.value
                await self?.followLoop(noteID: noteID, captureURL: captureURL, cancel: cancel)
            }
            return old
        }
        previous.1?.set()
        previous.0?.cancel()
    }

    public func stop(noteID: UUID) async {
        let running: (Task<Void, Never>?, CancelFlag?) = state.withLock { s in
            guard s.noteID == noteID else { return (nil, nil) }
            let pair = (s.task, s.cancelFlag)
            s.noteID = nil
            s.task = nil
            s.cancelFlag = nil
            return pair
        }
        running.1?.set()
        running.0?.cancel()
        await running.0?.value
    }

    public func preempt() async {
        let running: (Task<Void, Never>?, CancelFlag?) = state.withLock { s in
            let pair = (s.task, s.cancelFlag)
            s.noteID = nil
            s.task = nil
            s.cancelFlag = nil
            return pair
        }
        running.1?.set()
        running.0?.cancel()
        await running.0?.value
    }

    public func hasPrecomputeCheckpoint(for noteID: UUID) -> Bool {
        guard let loaded = (try? checkpoints.load(noteID)) ?? nil else { return false }
        return loaded.isPrecompute && loaded.committedPrefix != nil
    }

    /// Runs a single synchronous-to-current-disk pass over committed frames in `captureURL`, writing
    /// prefix-verified `work/checkpoint.json` (+ `work/clips.pcm` for Parakeet with speakers).
    /// Useful both inside `followLoop` and for deterministic event-gated tests with zero wall-clock sleeps.
    public func runOnce(noteID: UUID, captureURL: URL) async {
        let policy = TranscriptionModePolicy.evaluate(
            rawMode: mode().rawValue,
            hasForegroundSavedJob: pressure.hasForegroundSavedJob(),
            manualTranscribeRequested: false,
            platformSupportsPrecompute: true
        )
        guard policy.spawnWorkerDuringRecording, !pressure.shouldYield() else { return }
        let cancel = CancelFlag()
        await runPass(noteID: noteID, captureURL: captureURL, cancel: cancel, continuous: false)
    }

    // MARK: - Follower loop

    private func followLoop(noteID: UUID, captureURL: URL, cancel: CancelFlag) async {
        await runPass(noteID: noteID, captureURL: captureURL, cancel: cancel, continuous: true)
        state.withLock { s in
            if s.noteID == noteID, s.cancelFlag === cancel {
                s.noteID = nil
                s.task = nil
                s.cancelFlag = nil
            }
        }
    }

    private func runPass(noteID: UUID, captureURL: URL, cancel: CancelFlag, continuous: Bool) async {
        let chosen = engine()
        switch chosen {
        case .none:
            return
        case .parakeet(let config):
            guard config.models.speechReady, ParakeetFiles(root: config.models.root).present() else { return }
            guard !pressure.shouldYield(minMemoryBytes: ParakeetMemory.beforeLoadBytes) else { return }
            guard budget.tryAcquire() else { return }
            defer { budget.release() }
            await followParakeet(noteID: noteID, captureURL: captureURL, config: config, cancel: cancel, continuous: continuous)
        case .whistle(let config):
            var cap = config.acceptance()
            cap.bundleVerified = config.skipBundleVerification ? true : await WhistleRuntime.verifyBundle(config.bundle)
            guard cap.available else { return }
            guard !pressure.shouldYield(minMemoryBytes: Int64(WhistleCapability.loadHeadroom)) else { return }
            guard budget.tryAcquire() else { return }
            defer { budget.release() }
            await followWhistle(noteID: noteID, captureURL: captureURL, config: config, capability: cap, cancel: cancel, continuous: continuous)
        }
    }

    // MARK: - Parakeet + Streaming Sortformer

    private func followParakeet(
        noteID: UUID,
        captureURL: URL,
        config: ParakeetEngine,
        cancel: CancelFlag,
        continuous: Bool
    ) async {
        // Wait for the CAF header to appear on disk (only in continuous mode).
        var reader: LiveCAFReader?
        while reader == nil {
            if cancel.isSet || pressure.shouldYield(minMemoryBytes: ParakeetMemory.beforeLoadBytes) { return }
            if let opened = try? LiveCAFReader(url: captureURL) {
                reader = opened
            } else if continuous {
                try? await Task.sleep(for: pollInterval)
            } else {
                return
            }
        }
        guard let reader else { return }
        defer { reader.close() }

        let detector: URL?
        do {
            detector = try config.models.checked(cancel: cancel)
        } catch {
            return
        }

        // Optional streaming Sortformer + clips.pcm (matching TranscriptionJob's streaming speaker plan).
        var windowSpeakers: WindowSpeakers?
        if config.identifySpeakers(), let engines = await config.speakerEngines?() {
            let printsReady = await config.printsReady()
            let clips: ClipFile? = if printsReady, let url = checkpoints.clipsURL(for: noteID) {
                try? ClipFile(url: url, keeping: nil)
            } else {
                nil
            }
            windowSpeakers = try? WindowSpeakers(
                engines: engines,
                clips: clips,
                restored: nil,
                availableMemory: pressure.availableMemory
            )
        }
        defer { windowSpeakers?.close() }

        let speech: (any SpeechDetecting)? = detector.flatMap { try? config.runtime.makeDetector(SileroConfig(model: $0)) }
        let files = ParakeetFiles(root: config.models.root)
        let sourceRate = reader.sampleRate
        let blockFrames = UInt64(AppleSpeechWindows.samples(AppleSpeechWindows.blockMs, sampleRate: sourceRate))
        let lookahead = sourceRate == 48_000 ? Int(LiveCAFReader.firLookaheadFrames) : 0
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sourceRate), channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Limits.asrRate), channels: 1, interleaved: false) else {
            return
        }
        let converter: AVAudioConverter? = sourceFormat == outputFormat ? nil : AVAudioConverter(from: sourceFormat, to: outputFormat)
        converter?.downmix = true

        var decoder: SpeechWordDecoder?
        let input: SpeechInput? = speech != nil ? SpeechInput(start: 0) : nil
        var inferenceNanoseconds: UInt64 = 0
        let startedAt = TranscriptionJob.uptimeMs()

        let recognize: (PcmAudio, Int64) throws -> Transcript = { [pressure, runtime = config.runtime] audio, startMs in
            if cancel.isSet || pressure.shouldYield(minMemoryBytes: decoder == nil ? ParakeetMemory.beforeLoadBytes : ParakeetMemory.beforeWindowBytes) {
                throw CancellationError()
            }
            if decoder == nil {
                decoder = SpeechWordDecoder(try runtime.makeDecoder(ParakeetConfig(files)), cancelled: { cancel.isSet })
            }
            let began = DispatchTime.now().uptimeNanoseconds
            let start = startMs * Int64(Limits.asrRate) / 1000
            let detectorInput = speech.map { _ in Self.detectorInput(input, from: start, audio) }
            let decoded = try ParakeetDecode.transcribe(
                audio,
                decoder: decoder!,
                detector: speech,
                detectorInput: detectorInput,
                policy: .wholeSpans,
                cutting: DecodeCutting.cutting(detectorReady: speech != nil)
            )
            inferenceNanoseconds += DispatchTime.now().uptimeNanoseconds - began
            input?.discard(before: start + Int64(audio.samples.count - IncrementalTranscript.overlapSamples))
            let words = Transcript(decoded.words.map { Word("", $0.startMs, $0.endMs, $0.text) })
            if cancel.isSet || pressure.shouldYield() { throw CancellationError() }
            return try windowSpeakers?.window(audio, startMs: startMs, words: words) {
                if cancel.isSet { throw CancellationError() }
            } ?? words
        }

        guard let transcript = try? IncrementalTranscript(recognize: recognize) else { return }

        var framesRead: UInt64 = 0
        var reportedMs: Int64 = 0
        var prefixHasher = LiveCAFReader.IncrementalPrefixHasher()

        while !cancel.isSet && !pressure.shouldYield() {
            guard let safeThrough = try? reader.safeThroughFrame(safetyMarginFrames: safetyMarginFrames) else { return }
            if framesRead + blockFrames <= safeThrough {
                guard let floats = try? reader.readFloats(fromFrame: framesRead, frameCount: blockFrames) else { return }
                let samples16k: [Float]
                if let converter {
                    guard let converted = Self.convertBlock(floats, sourceFormat: sourceFormat, outputFormat: outputFormat, converter: converter) else { return }
                    samples16k = converted
                } else {
                    samples16k = floats
                }
                framesRead += blockFrames
                input?.append(samples16k)
                do {
                    try transcript.accept(samples16k, count: samples16k.count)
                } catch {
                    return
                }
                if transcript.doneMs > reportedMs {
                    let st = transcript.checkpoint()
                    let recognition = RecognitionCheckpoint(st)
                    let minRequired = CommittedPrefix.minRequiredCafSourceFrames(
                        consumed16kSamples: UInt64(recognition.position),
                        sourceSampleRateHz: sourceRate,
                        resamplerLookaheadFrames: lookahead
                    )
                    let committedFrames = max(framesRead, minRequired)
                    if committedFrames <= safeThrough {
                        let sha: String
                        do {
                            sha = try prefixHasher.advance(to: committedFrames, using: reader) {
                                cancel.isSet || pressure.shouldYield()
                            }
                        } catch is CancellationError {
                            return
                        } catch {
                            continue
                        }
                        reportedMs = transcript.doneMs
                        let lastEnd = st.words.map(\.endMs).max() ?? 0
                        let doneMs = max(recognition.doneMs, lastEnd)
                        let now = TranscriptionJob.uptimeMs()
                        let checkpoint = CheckpointState(
                            source: captureURL.lastPathComponent,
                            signature: CheckpointState.signature(of: captureURL),
                            model: SpeechRecognizer.parakeet.checkpointModel(language: ""),
                            segments: TranscriptSegment.segments(of: st.words),
                            doneMs: doneMs,
                            totalMs: 0,
                            elapsedMs: max(0, now - startedAt),
                            inferenceMs: Int64(inferenceNanoseconds / 1_000_000),
                            resumedFromMs: 0,
                            wordsComplete: false,
                            recognition: recognition,
                            speakers: windowSpeakers?.checkpoint(),
                            origin: .precompute,
                            recognitionSampleCount: recognition.position,
                            committedPrefix: CommittedPrefix(
                                kind: .cafPcm16LeFrames,
                                sourceSampleRateHz: sourceRate,
                                committedUnitCount: committedFrames,
                                prefixSha256: sha
                            )
                        )
                        if (try? checkpoints.save(checkpoint, for: noteID)) != nil {
                            onCheckpointSaved?(noteID, checkpoint)
                        }
                    }
                }
            } else if continuous {
                try? await Task.sleep(for: pollInterval)
            } else {
                break
            }
        }
    }

    private static func detectorInput(_ input: SpeechInput?, from start: Int64, _ audio: PcmAudio) -> [Float] {
        if let held = input?.window(from: start, count: audio.samples.count) { return held }
        var filter = SpeechInputFilter()
        return filter(audio.samples)
    }

    private static func convertBlock(
        _ floats: [Float],
        sourceFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> [Float]? {
        let count = AVAudioFrameCount(floats.count)
        guard let block = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: count) else { return nil }
        block.frameLength = count
        floats.withUnsafeBufferPointer { src in
            block.floatChannelData![0].update(from: src.baseAddress!, count: floats.count)
        }
        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(count) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return block
        }
        guard status != .error, error == nil else { return nil }
        return Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
    }

    // MARK: - Whistle DSP + Checkpoint

    private func followWhistle(
        noteID: UUID,
        captureURL: URL,
        config: WhistleEngine,
        capability: WhistleCapability,
        cancel: CancelFlag,
        continuous: Bool
    ) async {
        var reader: LiveCAFReader?
        while reader == nil {
            if cancel.isSet || pressure.shouldYield(minMemoryBytes: Int64(WhistleCapability.loadHeadroom)) { return }
            if let opened = try? LiveCAFReader(url: captureURL) {
                reader = opened
            } else if continuous {
                try? await Task.sleep(for: pollInterval)
            } else {
                return
            }
        }
        guard let reader else { return }
        defer { reader.close() }

        let sourceRate = reader.sampleRate
        guard sourceRate == 48_000 || sourceRate == 16_000 else { return }
        guard let resampler = try? WhistleResampler(rate: sourceRate),
              let vad = try? config.backend.makeVAD(config.bundle) else { return }
        do {
            try await config.backend.prepare(capability, config.bundle)
        } catch {
            return
        }
        await followWhistleLoop(
            noteID: noteID, captureURL: captureURL, reader: reader,
            config: config, capability: capability, resampler: resampler, vad: vad,
            cancel: cancel, continuous: continuous
        )
        _ = await config.backend.close()
    }

    private enum WhistlePersistOutcome {
        case saved
        case skipped
        case cancelled
        case encodeFailed
    }

    private func followWhistleLoop(
        noteID: UUID,
        captureURL: URL,
        reader: LiveCAFReader,
        config: WhistleEngine,
        capability: WhistleCapability,
        resampler initialResampler: WhistleResampler,
        vad: WhistleSessionBackend.VADHandle,
        cancel: CancelFlag,
        continuous: Bool
    ) async {
        var resampler = initialResampler
        let sourceRate = reader.sampleRate
        let blockFrames = UInt64(sourceRate) // 1 second, matching WhistleAudioReader
        let checkpointIntervalFrames = blockFrames * whistleCheckpointIntervalSeconds
        let lookahead = sourceRate == 48_000 ? Int(LiveCAFReader.firLookaheadFrames) : 0
        var framesRead: UInt64 = 0
        var lastSavedFrames: UInt64 = 0
        var lastSafeThrough: UInt64 = 0
        var raw: [Float] = []
        var base = 0
        var totalSamples = 0
        var finalized = 0
        var gate = WhistleSpeechGate()
        var segments: [TranscriptSegment] = []
        var reportedLanguage: String?
        let maximumRawSamples = 240_128 + 16_000 + 5_120
        let startedAt = TranscriptionJob.uptimeMs()
        var prefixHasher = LiveCAFReader.IncrementalPrefixHasher()
        var stateConsistent = true

        while !cancel.isSet && !pressure.shouldYield(minMemoryBytes: Int64(WhistleCapability.windowHeadroom)) {
            guard let safeThrough = try? reader.safeThroughFrame(safetyMarginFrames: safetyMarginFrames) else { break }
            lastSafeThrough = max(lastSafeThrough, safeThrough)
            if framesRead + blockFrames <= safeThrough {
                guard let block = try? reader.readFloats(fromFrame: framesRead, frameCount: blockFrames) else { break }
                stateConsistent = false
                framesRead += blockFrames
                let pcm = resampler.feed(block, final: false)
                guard pcm.allSatisfy(\.isFinite) else { return }
                raw.append(contentsOf: pcm)
                totalSamples += pcm.count

                let boundaries: [WhistleSegment]
                do {
                    boundaries = try gate.feed(pcm) { frame in
                        if cancel.isSet || pressure.shouldYield(minMemoryBytes: Int64(WhistleCapability.windowHeadroom)) {
                            throw CancellationError()
                        }
                        return try vad.probability(frame)
                    }
                } catch {
                    return
                }
                let safeThroughSample = gate.retainedStart
                for boundary in boundaries {
                    if cancel.isSet || pressure.shouldYield(minMemoryBytes: Int64(WhistleCapability.windowHeadroom)) { return }
                    guard boundary.startSample >= base, boundary.endSample <= base + raw.count,
                          boundary.endSample - boundary.startSample <= 240_128 else { return }
                    let offset = Double(boundary.startSample) / 16_000
                    let slice = Array(raw[(boundary.startSample - base)..<(boundary.endSample - base)])
                    guard let result = try? await config.backend.transcribe(slice, capability, config.bundle, nil, nil) else { return }
                    let words = result.words.map { TimedWord(text: $0.word, start: offset + $0.start, end: offset + $0.end) }
                    let segment = TranscriptSegment(text: result.text, start: offset, end: Double(boundary.endSample) / 16_000, words: words)
                    if !segment.text.isEmpty { segments.append(segment) }
                    if let known = TranscriptLanguage.known(result.language) {
                        reportedLanguage = reportedLanguage == nil || reportedLanguage == known ? known : "mul"
                    }
                    finalized = max(finalized, boundary.endSample)
                }
                finalized = max(finalized, safeThroughSample)
                let discard = min(raw.count, max(0, safeThroughSample - base))
                raw.removeFirst(discard)
                base += discard
                guard raw.count <= maximumRawSamples else { return }
                stateConsistent = true

                if framesRead - lastSavedFrames >= checkpointIntervalFrames {
                    let outcome = persistWhistleCheckpoint(
                        noteID: noteID,
                        captureURL: captureURL,
                        reader: reader,
                        sourceRate: sourceRate,
                        lookahead: lookahead,
                        framesRead: framesRead,
                        safeThrough: safeThrough,
                        totalSamples: totalSamples,
                        finalized: finalized,
                        gate: gate,
                        firState: resampler.state,
                        vadState: vad.state(),
                        raw: raw,
                        segments: segments,
                        reportedLanguage: reportedLanguage,
                        startedAt: startedAt,
                        prefixHasher: &prefixHasher,
                        cancel: cancel,
                        allowWhenCancelled: false
                    )
                    switch outcome {
                    case .saved:
                        lastSavedFrames = framesRead
                    case .cancelled:
                        // Cancelled mid-hash during periodic save: exit loop and flush cleanly below.
                        break
                    case .encodeFailed:
                        return
                    case .skipped:
                        break
                    }
                    if outcome == .cancelled { break }
                }
            } else if continuous {
                try? await Task.sleep(for: pollInterval)
            } else {
                break
            }
        }

        // Always flush settled Whistle work accumulated since the last periodic checkpoint on
        // Pause, Stop, Yield, or clean loop exit so no settled work is lost (`D111` §4).
        if stateConsistent, framesRead > lastSavedFrames, lastSafeThrough > 0 {
            let flushSafeThrough = (try? reader.safeThroughFrame(safetyMarginFrames: safetyMarginFrames)) ?? lastSafeThrough
            let outcome = persistWhistleCheckpoint(
                noteID: noteID,
                captureURL: captureURL,
                reader: reader,
                sourceRate: sourceRate,
                lookahead: lookahead,
                framesRead: framesRead,
                safeThrough: max(lastSafeThrough, flushSafeThrough),
                totalSamples: totalSamples,
                finalized: finalized,
                gate: gate,
                firState: resampler.state,
                vadState: vad.state(),
                raw: raw,
                segments: segments,
                reportedLanguage: reportedLanguage,
                startedAt: startedAt,
                prefixHasher: &prefixHasher,
                cancel: cancel,
                allowWhenCancelled: true
            )
            if outcome == .saved {
                lastSavedFrames = framesRead
            }
        }
    }

    private func persistWhistleCheckpoint(
        noteID: UUID,
        captureURL: URL,
        reader: LiveCAFReader,
        sourceRate: Int,
        lookahead: Int,
        framesRead: UInt64,
        safeThrough: UInt64,
        totalSamples: Int,
        finalized: Int,
        gate: WhistleSpeechGate,
        firState: WhistleResampler.State,
        vadState: WhistleVAD.State,
        raw: [Float],
        segments: [TranscriptSegment],
        reportedLanguage: String?,
        startedAt: Int64,
        prefixHasher: inout LiveCAFReader.IncrementalPrefixHasher,
        cancel: CancelFlag,
        allowWhenCancelled: Bool
    ) -> WhistlePersistOutcome {
        let minRequired = CommittedPrefix.minRequiredCafSourceFrames(
            consumed16kSamples: UInt64(max(0, totalSamples)),
            sourceSampleRateHz: sourceRate,
            resamplerLookaheadFrames: lookahead
        )
        let committedFrames = max(framesRead, minRequired)
        guard committedFrames <= safeThrough else { return .skipped }

        let pipelineState = WhistlePipelineState(
            version: 1,
            finished: false,
            gate: gate,
            fir: firState,
            vad: vadState,
            raw: raw.withUnsafeBufferPointer { Data(buffer: $0) }
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let stateBytes = try? encoder.encode(pipelineState) else { return .encodeFailed }
        let whistleCP = WhistleCheckpoint(
            sourceFrame: Int64(framesRead),
            processedSamples: totalSamples,
            doneSamples: finalized,
            state: stateBytes
        )
        let sha: String
        do {
            sha = try prefixHasher.advance(
                to: committedFrames,
                using: reader,
                checkTaskCancellation: !allowWhenCancelled
            ) {
                allowWhenCancelled
                    ? false
                    : (cancel.isSet || pressure.shouldYield(minMemoryBytes: Int64(WhistleCapability.windowHeadroom)))
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .skipped
        }
        let now = TranscriptionJob.uptimeMs()
        var checkpoint = CheckpointState(
            source: captureURL.lastPathComponent,
            signature: CheckpointState.signature(of: captureURL),
            model: SpeechRecognizer.whistle.checkpointModel(language: ""),
            segments: segments,
            doneMs: whistleCP.doneMs,
            totalMs: 0,
            elapsedMs: max(0, now - startedAt),
            inferenceMs: max(0, now - startedAt),
            resumedFromMs: 0,
            wordsComplete: false,
            recognition: nil,
            speakers: nil,
            origin: .precompute,
            recognitionSampleCount: Int64(totalSamples),
            committedPrefix: CommittedPrefix(
                kind: .cafPcm16LeFrames,
                sourceSampleRateHz: sourceRate,
                committedUnitCount: committedFrames,
                prefixSha256: sha
            )
        )
        checkpoint.reportedLanguage = reportedLanguage
        checkpoint.whistle = whistleCP
        if (try? checkpoints.save(checkpoint, for: noteID)) != nil {
            onCheckpointSaved?(noteID, checkpoint)
            return .saved
        }
        return .skipped
    }
}
