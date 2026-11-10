import Foundation
import CassiniEngine
import CassiniNotebook
import CassiniWhistle

/// Bundled recognizer: bounded file streaming through the desktop FIR/HPF/Silero gate. The ASR branch stays raw.
/// The job commits each batch's words with the DSP state needed to continue at its exact source frame.
/// The private session budget prevents two callers interleaving model lifetime.
public struct WhistleTranscriber: Transcribing {
    private static let sessions = NativeBudget()
    private let acceptance: @Sendable () -> WhistleCapability
    private let bundle: Bundle
    private let memoryReport: (@Sendable (WhistleMemoryReport) -> Void)?
    private let availableMemory: @Sendable () -> Int64?
    private let trace: Trace?

    struct Trace: Sendable {
        var read: @Sendable (Range<Int64>) -> Void
        var submitted: @Sendable (Range<Int>) -> Void
        var resultReady: @Sendable (Range<Int>) async -> Void
    }
    public init(acceptance: WhistleCapability, bundle: Bundle = .main,
                availableMemory: @escaping @Sendable () -> Int64? = TranscriptionJob.availableMemory,
                memoryReport: (@Sendable (WhistleMemoryReport) -> Void)? = nil,
                acceptanceProvider: (@Sendable () -> WhistleCapability)? = nil) {
        self.init(acceptance: acceptanceProvider ?? { acceptance }, bundle: bundle,
                  availableMemory: availableMemory, memoryReport: memoryReport, trace: nil)
    }

    init(acceptance: @escaping @Sendable () -> WhistleCapability, bundle: Bundle = .main,
         availableMemory: @escaping @Sendable () -> Int64?, memoryReport: (@Sendable (WhistleMemoryReport) -> Void)? = nil,
         trace: Trace?) {
        self.acceptance = acceptance
        self.bundle = bundle
        self.availableMemory = availableMemory
        self.memoryReport = memoryReport
        self.trace = trace
    }
    public var recognizer: SpeechRecognizer { .whistle }
    public var assetInstallBytes: Int64 { 0 }
    private static let segmentationID = "desktop-whistle-fir97-hpf100-silero6.2.1-ort1.27.1-gate-v2"
    public func segmentation() async -> String? { Self.segmentationID }
    public func speechLanguages() async -> [SpeechLanguage] { [] }
    public func runLanguage(requested: String) async -> String? { nil }
    public func modelName(locale: Locale) async -> String? { SpeechRecognizer.whistle.checkpointModel(language: "") }
    public func availability(locale: Locale) async -> SpeechAvailability {
        var capability = acceptance()
        capability.bundleVerified = await WhistleRuntime.verifyBundle(bundle)
        guard capability.available else { return SpeechAvailability(assets: .unsupported, failure: .model) }
        let free = availableMemory()
        let enough = free.map { $0 > 0 && UInt64($0) >= WhistleCapability.loadHeadroom } ?? false
        return SpeechAvailability(assets: .ready, failure: enough ? nil : .memory)
    }
    public func assetStatus(locale: Locale) async -> ModelPartStatus { await availability(locale: locale).assets }
    public func unavailability(locale: Locale) async -> JobFailure? { await availability(locale: locale).failure }
    public func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        guard await assetStatus(locale: locale) == .ready else { throw TranscriptionError.failed(.model) }
    }
    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        var candidate = self.acceptance()
        candidate.bundleVerified = await WhistleRuntime.verifyBundle(bundle)
        let acceptance = candidate
        guard acceptance.available else { throw TranscriptionError.failed(.model) }
        return try await Self.sessions.withBudget {
            let measurement = WhistleMemoryMonitor()
            do {
                let value = try await Session(acceptance: acceptance, bundle: bundle, memory: availableMemory, trace: trace)
                    .decode(request, events: events)
                let released = await WhistleRuntime.shared.close()
                memoryReport?(measurement.finish(succeeded: true, nativeModelReleased: released))
                return value
            } catch {
                let released = await WhistleRuntime.shared.close()
                memoryReport?(measurement.finish(succeeded: false, nativeModelReleased: released))
                if error is CancellationError || error is TranscriptionError { throw error }
                if let e = error as? WhistleError {
                    throw TranscriptionError.failed(e == .invalidInput ? .audio : e == .integrity ? .modelVerify : .model)
                }
                throw TranscriptionError.failed(.open)
            }
        }
    }

    private actor Session {
        let acceptance: WhistleCapability
        let bundle: Bundle
        let memory: @Sendable () -> Int64?
        let trace: Trace?
        init(acceptance: WhistleCapability, bundle: Bundle, memory: @escaping @Sendable () -> Int64?, trace: Trace?) {
            self.acceptance = acceptance; self.bundle = bundle; self.memory = memory; self.trace = trace
        }
        private var raw: [Float] = []
        private var base = 0, totalSamples = 0, finalized = 0
        private var segments: [TranscriptSegment] = []
        private var gate = WhistleSpeechGate()
        private var vad: WhistleVAD?
        private static let maximumRawSamples = 240_128 + 16_000 + 5_120
        private struct PipelineState: Codable {
            let version: Int
            let finished: Bool
            let gate: WhistleSpeechGate
            let fir: WhistleResampler.State
            let vad: WhistleVAD.State
            let raw: Data
        }
        func headroom(_ required: UInt64) throws {
            guard let value = memory(), value > 0, UInt64(value) >= required else { throw TranscriptionError.failed(.memory) }
        }
        func consume(_ pcm: [Float], final: Bool, reader: WhistleAudioReader, resampler: WhistleResampler,
                     events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
            try Task.checkCancellation()
            guard pcm.allSatisfy({ $0.isFinite }) else { throw WhistleError.invalidInput }
            raw.append(contentsOf: pcm); totalSamples += pcm.count
            guard let vad else { throw WhistleError.unavailable }
            var boundaries = try gate.feed(pcm) { frame in
                try Task.checkCancellation()
                return try vad.probability(frame)
            }
            let safeThrough = gate.retainedStart
            if final { boundaries += gate.flush() }
            var decoded: [TranscriptSegment] = []
            var languages: [String] = []
            for boundary in boundaries {
                try Task.checkCancellation()
                try headroom(WhistleCapability.windowHeadroom)
                guard boundary.startSample >= base, boundary.endSample <= base + raw.count,
                      boundary.endSample - boundary.startSample <= 240128 else { throw WhistleError.invalidInput }
                let offset = Double(boundary.startSample) / 16000
                let samples = Array(raw[(boundary.startSample-base)..<(boundary.endSample-base)])
                let result: WhistleResult
                if let trace {
                    let range = boundary.startSample..<boundary.endSample
                    result = try await WhistleRuntime.shared.transcribe(samples, acceptance: acceptance, bundle: bundle,
                        submitted: { trace.submitted(range) }, resultReady: { await trace.resultReady(range) })
                } else {
                    result = try await WhistleRuntime.shared.transcribe(samples, acceptance: acceptance, bundle: bundle)
                }
                let words = result.words.map { TimedWord(text: $0.word, start: offset + $0.start, end: offset + $0.end) }
                let segment = TranscriptSegment(text: result.text, start: offset, end: Double(boundary.endSample)/16000, words: words)
                languages.append(result.language)
                decoded.append(segment)
                finalized = max(finalized, boundary.endSample)
            }
            let safe = final ? totalSamples : safeThrough
            finalized = max(finalized, safe)
            let discard = min(raw.count, max(0, safe - base))
            raw.removeFirst(discard); base += discard
            guard raw.count <= Self.maximumRawSamples else { throw WhistleError.invalidInput }
            let state = PipelineState(version: 1, finished: final, gate: gate, fir: resampler.state, vad: vad.state,
                                      raw: raw.withUnsafeBufferPointer { Data(buffer: $0) })
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let bytes = try encoder.encode(state)
            let checkpoint = WhistleCheckpoint(sourceFrame: reader.position, processedSamples: totalSamples,
                                               doneSamples: finalized, state: bytes)
            segments += decoded
            events(.whistleBatch(.init(checkpoint: checkpoint, segments: decoded, languages: languages)))
        }

        /// The prefix's finalized words are already held by the job. Restore only the raw audio for the
        /// open gate and its pre-roll, plus the FIR, HPF and Silero state used to derive the next boundary.
        func restore(_ checkpoint: WhistleCheckpoint, reader: WhistleAudioReader,
                     resampler: inout WhistleResampler, vad: WhistleVAD) throws -> Bool {
            do {
                guard checkpoint.valid else { throw WhistleError.invalidInput }
                let state = try PropertyListDecoder().decode(PipelineState.self, from: checkpoint.state)
                guard state.version == 1 else { throw WhistleError.invalidInput }
                let inputCount = reader.inputFrames(through: reader.position)
                let processed = checkpoint.processedSamples
                if state.finished {
                    let expected = reader.rate == 16_000 ? inputCount : (inputCount + 2) / 3
                    guard reader.position == reader.length, processed == expected,
                          checkpoint.doneSamples == processed, state.raw.isEmpty else { throw WhistleError.invalidInput }
                    return true
                }
                let expected = reader.rate == 16_000 ? inputCount : max(0, (inputCount - 49) / 3 + 1)
                guard processed == expected, state.gate.valid(at: processed),
                      checkpoint.doneSamples >= state.gate.retainedStart else { throw WhistleError.invalidInput }
                let rawStart = state.gate.retainedStart
                let sampleCount = processed - rawStart
                guard sampleCount <= Self.maximumRawSamples,
                      state.raw.count == sampleCount * MemoryLayout<Float>.stride else { throw WhistleError.invalidInput }
                var restored = [Float](repeating: 0, count: sampleCount)
                _ = restored.withUnsafeMutableBytes { state.raw.copyBytes(to: $0) }
                guard restored.allSatisfy(\.isFinite) else { throw WhistleError.invalidInput }
                try resampler.restore(state.fir, inputCount: inputCount, outputCount: processed)
                try vad.restore(state.vad)
                raw = restored
                base = rawStart
                gate = state.gate
                totalSamples = processed
                finalized = checkpoint.doneSamples
                return false
            } catch {
                throw TranscriptionError.failed(.checkpointMismatch)
            }
        }

        func decode(_ request: TranscriptionRequest, events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
            try Task.checkCancellation()
            try headroom(WhistleCapability.loadHeadroom)
            events(.preparingModel(.checking))
            let reader = try WhistleAudioReader(url: request.url, position: request.whistleResume?.sourceFrame ?? 0, onRead: trace?.read)
            guard reader.duration.isFinite, reader.duration <= 36 * 3600 else { throw TranscriptionError.failed(.long) }
            let inputCount = reader.inputFrames(through: reader.length)
            let outputCount = reader.rate == 16_000 ? inputCount : (inputCount + 2) / 3
            let duration = max(reader.duration, Double(outputCount) / 16_000)
            let result = { TranscriptionResult(segments: self.segments, segmentation: WhistleTranscriber.segmentationID) }
            guard let root = bundle.resourceURL?.appendingPathComponent("Whistle") else { throw WhistleError.unavailable }
            let detector = try WhistleVAD(model: root.appendingPathComponent("silero-vad-6.2.1.onnx"))
            vad = detector
            defer { vad = nil }
            var resampler = try WhistleResampler(rate: reader.rate)
            if let checkpoint = request.whistleResume,
               try restore(checkpoint, reader: reader, resampler: &resampler, vad: detector) {
                events(.progress(done: duration, total: duration))
                return result()
            }
            try await WhistleRuntime.shared.prepare(acceptance: acceptance, bundle: bundle)
            events(.progress(done: Double(finalized) / 16_000, total: duration))
            while true {
                try Task.checkCancellation()
                guard let pcm = try reader.next() else { break }
                try await consume(resampler.feed(pcm), final: false, reader: reader, resampler: resampler, events: events)
            }
            try await consume(resampler.feed([], final: true), final: true, reader: reader, resampler: resampler, events: events)
            try Task.checkCancellation()
            events(.progress(done: duration, total: duration))
            return result()
        }
    }
}
