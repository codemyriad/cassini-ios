import AVFoundation
import Foundation
import CassiniEngine
import CassiniNotebook
import CassiniWhistle

/// Internal experiment: bounded file streaming through the desktop FIR/HPF/Silero gate. The ASR branch stays raw.
/// Every resume rereads from zero to restore FIR, filter and recurrent VAD state; finalized words are deduplicated
/// by WordsDecode at the saved boundary. The private session budget prevents two callers interleaving model lifetime.
public struct WhistleTranscriber: Transcribing {
    private static let sessions = NativeBudget()
    private let acceptance: WhistleCapability
    private let bundle: Bundle
    private let memoryReport: (@Sendable (WhistleMemoryReport) -> Void)?
    private let availableMemory: @Sendable () -> Int64?
    public init(acceptance: WhistleCapability, bundle: Bundle = .main,
                availableMemory: @escaping @Sendable () -> Int64? = TranscriptionJob.availableMemory,
                memoryReport: (@Sendable (WhistleMemoryReport) -> Void)? = nil) {
        self.acceptance = acceptance; self.bundle = bundle; self.availableMemory = availableMemory; self.memoryReport = memoryReport
    }
    public var recognizer: SpeechRecognizer { .whistle }
    public var assetInstallBytes: Int64 { 0 }
    public func segmentation() async -> String? { "desktop-whistle-fir97-hpf100-silero6.2.1-ort1.27.1-gate-v1" }
    public func speechLanguages() async -> [SpeechLanguage] { [] }
    public func runLanguage(requested: String) async -> String? { nil }
    public func modelName(locale: Locale) async -> String? { SpeechRecognizer.whistle.checkpointModel(language: "") }
    public func assetStatus(locale: Locale) async -> ModelPartStatus {
        acceptance.available && WhistleRuntime.bundleIsVerified(bundle) ? .ready : .unsupported
    }
    public func unavailability(locale: Locale) async -> JobFailure? {
        await assetStatus(locale: locale) == .ready ? nil : .model
    }
    public func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        guard await assetStatus(locale: locale) == .ready else { throw TranscriptionError.failed(.model) }
    }
    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        guard acceptance.available else { throw TranscriptionError.failed(.model) }
        return try await Self.sessions.withBudget {
            let measurement = WhistleMemoryMonitor()
            do {
                let value = try await Session(acceptance: acceptance, bundle: bundle, memory: availableMemory)
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
        init(acceptance: WhistleCapability, bundle: Bundle, memory: @escaping @Sendable () -> Int64?) {
            self.acceptance = acceptance; self.bundle = bundle; self.memory = memory
        }
        private var raw: [Float] = []
        private var base = 0, totalSamples = 0, finalized = 0
        private var segments: [TranscriptSegment] = []
        private var gate = WhistleSpeechGate()
        private var vad: WhistleVAD?
        private var duration = 0.0
        func headroom(_ required: UInt64) throws {
            guard let value = memory(), value > 0, UInt64(value) >= required else { throw TranscriptionError.failed(.memory) }
        }
        func consume(_ pcm: [Float], final: Bool, events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
            try Task.checkCancellation()
            guard pcm.allSatisfy({ $0.isFinite }) else { throw WhistleError.invalidInput }
            raw.append(contentsOf: pcm); totalSamples += pcm.count
            var boundaries = try gate.feed(pcm) { frame in
                try Task.checkCancellation()
                guard let vad else { throw WhistleError.unavailable }
                return try vad.probability(frame)
            }
            let safeThrough = gate.retainedStart
            if final { boundaries += gate.flush() }
            for boundary in boundaries {
                try Task.checkCancellation()
                try headroom(WhistleCapability.windowHeadroom)
                guard boundary.startSample >= base, boundary.endSample <= base + raw.count,
                      boundary.endSample - boundary.startSample <= 240128 else { throw WhistleError.invalidInput }
                let offset = Double(boundary.startSample) / 16000
                let samples = Array(raw[(boundary.startSample-base)..<(boundary.endSample-base)])
                let result = try await WhistleRuntime.shared.transcribe(samples, acceptance: acceptance, bundle: bundle)
                let words = result.words.map { TimedWord(text: $0.word, start: offset + $0.start, end: offset + $0.end) }
                let segment = TranscriptSegment(text: result.text, start: offset, end: Double(boundary.endSample)/16000, words: words)
                events(.detectedLanguage(result.language))
                events(.finalized(segment)); segments.append(segment); finalized = max(finalized, boundary.endSample)
            }
            let safe = final ? totalSamples : safeThrough
            if safe > finalized {
                events(.finalized(TranscriptSegment(text: "", start: Double(finalized)/16000, end: Double(safe)/16000)))
                finalized = safe
            }
            events(.progress(done: Double(finalized)/16000, total: duration))
            let discard = min(raw.count, max(0, safe - base))
            raw.removeFirst(discard); base += discard
            // One desktop segment, pre-roll and one decoder batch; never the whole meeting's PCM.
            guard raw.count <= 240128 + 16000 + 5120 else { throw WhistleError.invalidInput }
        }
        func decode(_ request: TranscriptionRequest, events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
            try Task.checkCancellation()
            try headroom(WhistleCapability.loadHeadroom)
            events(.preparingModel(nil))
            let native = try AVAudioFile(forReading: request.url)
            let rate = native.processingFormat.sampleRate == 16000 ? 16000 : 48000
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false) else {
                throw TranscriptionError.failed(.audio)
            }
            let reader = try FileReader(url: request.url, from: 0, to: format, downmix: true)
            guard reader.duration.isFinite, reader.duration <= 36 * 3600 else { throw TranscriptionError.failed(.long) }
            guard let root = bundle.resourceURL?.appendingPathComponent("Whistle") else { throw WhistleError.unavailable }
            vad = try WhistleVAD(model: root.appendingPathComponent("silero-vad-6.2.1.onnx"))
            defer { vad = nil }
            try await WhistleRuntime.shared.prepare(acceptance: acceptance, bundle: bundle)
            events(.progress(done: 0, total: reader.duration))
            duration = reader.duration
            var resampler = try WhistleResampler(rate: rate)
            while let next = reader.nextBuffer() {
                guard let channel = next.0.floatChannelData?.pointee else { throw TranscriptionError.failed(.audio) }
                let pcm = Array(UnsafeBufferPointer(start: channel, count: Int(next.0.frameLength)))
                try await consume(resampler.feed(pcm), final: false, events: events)
            }
            guard reader.failure == nil, reader.reachedEnd else { throw TranscriptionError.failed(.open) }
            try await consume(resampler.feed([], final: true), final: true, events: events)
            try Task.checkCancellation()
            events(.progress(done: reader.duration, total: reader.duration))
            return TranscriptionResult(segments: segments, segmentation: "desktop-whistle-fir97-hpf100-silero6.2.1-ort1.27.1-gate-v1")
        }
    }
}
