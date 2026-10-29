import CassiniEngine
import CassiniNotebook
import Foundation
#if canImport(SherpaOnnxC)
import SherpaOnnxC
#endif

/// The settings of Android's Sortformer diarizer (`SortformerStream.config`): the model, CPU with `threads`, the
/// activity threshold and the minimum turn and gap of `Diarization`. Clustering keeps Kotlin's defaults (-1 clusters,
/// 0.5); Sortformer ignores it and the embedding model.
public struct SortformerConfig: Sendable, Equatable {
    public var model: URL
    public var threads: Int32
    public var provider = "cpu"
    public var threshold = Diarization.threshold
    public var minDurationOn = Diarization.minDurationOn
    public var minDurationOff = Diarization.minDurationOff
    public var clusters: Int32 = -1
    public var clusteringThreshold: Float = 0.5

    public init(model: URL, threads: Int32 = 2) { self.model = model; self.threads = threads }
}

/// The settings of Android's CAM++ extractor (`VoiceprintExtractor`): the model, CPU with 2 threads.
public struct VoiceprintConfig: Sendable, Equatable {
    public var model: URL
    public var threads: Int32 = 2
    public var provider = "cpu"

    public init(model: URL) { self.model = model }
}

/// What a `SortformerStream` saves into a checkpoint (Android's `diarizer` member).
public typealias SortformerState = DiarizerState

extension SherpaRuntime {
    /// Streaming Sortformer and CAM++ for the speaker step (`SpeakerAnalyzer`); both throw `notLinked` without the
    /// runtime.
    public static let speakers = SpeakerRuntime(
        linked: isLinked,
        makeDiarizer: { try SortformerStream(model: $0, restored: $1) },
        prints: { try VoiceprintExtractor.compute(model: $0, audio: $1, windows: $2, active: $3) })
}

private func fileExists(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
}

/// Streaming Sortformer diarization over the sherpa-onnx C API (Android's `SortformerStream`): one instance keeps
/// speaker slots across chunks of at most 28 s, and `TurnHistory` puts their turns on the recording clock. `state` and
/// `init(model:restored:)` are the checkpoint's `diarizer` member; the native cache is capped at
/// `SpeakerBudget.diarizerStateFloats` floats. Not thread-safe: one thread owns it. Cancellation throws
/// `CancellationError` before and after each native call, which itself always runs to its end.
public final class SortformerStream: StreamingDiarizer, @unchecked Sendable {
    /// The longest chunk `process` takes: IncrementalTranscript's 28 s window.
    public static let maxChunkMs: Int64 = 28_000

    public private(set) var elapsedMs: Int64 = 0
    private var history: TurnHistory
    #if canImport(SherpaOnnxC)
    private let diarizer: OpaquePointer
    #endif

    /// The turns so far on the recording clock.
    public var turns: [DiarizerTurn] { history.turns }

    /// A new diarizer, or one that resumes `restored`. Throws `SherpaError.restoreFailed` for a cache the model does
    /// not take or that is over the cap.
    public init(model: URL, restored: SortformerState? = nil) throws {
        #if canImport(SherpaOnnxC)
        diarizer = try Self.create(SortformerConfig(model: model))
        history = TurnHistory(restored?.turns ?? [])
        if let restored {
            // self is whole here, so a throw runs deinit, which releases the diarizer.
            guard restore(restored.cache) else { throw SherpaError.restoreFailed }
            elapsedMs = restored.elapsedMs
        }
        #else
        throw SherpaError.notLinked
        #endif
    }

    /// Diarizes one chunk of 16 kHz samples that starts at `startMs` of the recording. Returns the chunk's own turns
    /// (on its clock) and adds them to `turns`.
    @discardableResult
    public func process(_ audio: PcmAudio, startMs: Int64) throws -> [DiarizerTurn] {
        guard audio.sampleRate == 16_000, audio.durationMs <= Self.maxChunkMs else { throw SherpaError.invalidAudio }
        try Task.checkCancellation()
        let began = DispatchTime.now().uptimeNanoseconds
        #if canImport(SherpaOnnxC)
        let segments = audio.samples.withUnsafeBufferPointer { buffer in
            Self.segments(SherpaOnnxOfflineSpeakerDiarizationProcessStreamingChunk(diarizer, buffer.baseAddress, Int32(buffer.count)))
        }
        #else
        let segments: [DiarizerSegment] = []
        #endif
        let found = Diarization.chunkTurns(segments, durationMs: audio.durationMs)
        elapsedMs += Int64((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
        try Task.checkCancellation()
        history.add(found, startMs: startMs)
        return found
    }

    /// The native speaker cache; empty before the first chunk.
    public func saveState() -> [Float] {
        #if canImport(SherpaOnnxC)
        var count: Int32 = 0
        guard let pointer = SherpaOnnxOfflineSpeakerDiarizationSaveStreamingState(diarizer, &count) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyStreamingState(pointer) }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(max(0, count))))
        #else
        []
        #endif
    }

    /// Restores a cache from `saveState`; false when it does not fit the model or is over the cap.
    public func restore(_ cache: [Float]) -> Bool {
        guard cache.count <= SpeakerBudget.diarizerStateFloats else { return false }
        #if canImport(SherpaOnnxC)
        return cache.withUnsafeBufferPointer { buffer in
            SherpaOnnxOfflineSpeakerDiarizationRestoreStreamingState(diarizer, buffer.baseAddress, Int32(buffer.count)) == 1
        }
        #else
        return false
        #endif
    }

    /// The checkpoint's `diarizer` member.
    public var state: SortformerState { SortformerState(cache: saveState(), elapsedMs: elapsedMs, turns: turns) }

    /// The speaker turns of a whole recording in one native call (Android's `SortformerStream.turns`). `progress`
    /// reports each 27 s chunk; it cannot stop the native call, so cancellation is checked after it returns.
    public static func turns(_ audio: PcmAudio, model: URL, threads: Int32 = 2,
                             progress: @escaping (Int, Int) -> Void = { _, _ in }) throws -> [DiarizerTurn] {
        guard threads > 0, audio.sampleRate == 16_000 else { throw SherpaError.invalidAudio }
        guard !audio.samples.isEmpty else { throw JobFailure.audio }
        try Task.checkCancellation()
        #if canImport(SherpaOnnxC)
        let diarizer = try create(SortformerConfig(model: model, threads: threads))
        defer { SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer) }
        final class Box { let report: (Int, Int) -> Void; init(_ report: @escaping (Int, Int) -> Void) { self.report = report } }
        let box = Box(progress)
        let segments = withExtendedLifetime(box) {
            audio.samples.withUnsafeBufferPointer { buffer in
                segments(SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(
                    diarizer, buffer.baseAddress, Int32(buffer.count),
                    { done, total, arg in
                        // Never unwind across the C call; the return value does not cancel computation.
                        if let arg, !Task.isCancelled {
                            Unmanaged<Box>.fromOpaque(arg).takeUnretainedValue().report(Int(done), Int(total))
                        }
                        return 0
                    }, Unmanaged.passUnretained(box).toOpaque()))
            }
        }
        try Task.checkCancellation()
        return Diarization.wholeTurns(segments, durationMs: audio.durationMs)
        #else
        throw SherpaError.notLinked
        #endif
    }

    #if canImport(SherpaOnnxC)
    private static func create(_ config: SortformerConfig) throws -> OpaquePointer {
        // The native loader ends the process on a missing file instead of failing.
        guard fileExists(config.model) else { throw SherpaError.missingFiles }
        let strings = [config.model.path, config.provider, ""].map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var native = SherpaOnnxOfflineSpeakerDiarizationConfig()
        native.segmentation.sortformer.model = UnsafePointer(strings[0])
        native.segmentation.sortformer.threshold = config.threshold
        native.segmentation.pyannote.model = UnsafePointer(strings[2])
        native.segmentation.num_threads = config.threads
        native.segmentation.provider = UnsafePointer(strings[1])
        native.embedding.model = UnsafePointer(strings[2])
        native.embedding.num_threads = config.threads
        native.embedding.provider = UnsafePointer(strings[1])
        native.clustering.num_clusters = config.clusters
        native.clustering.threshold = config.clusteringThreshold
        native.min_duration_on = config.minDurationOn
        native.min_duration_off = config.minDurationOff
        guard let created = SherpaOnnxCreateOfflineSpeakerDiarization(&native) else { throw SherpaError.createFailed }
        return created
    }

    /// The segments of a result sorted by start time, as the JNI returns them; frees the result.
    private static func segments(_ result: OpaquePointer?) -> [DiarizerSegment] {
        guard let result else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard count > 0, let sorted = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(sorted) }
        return UnsafeBufferPointer(start: sorted, count: count).map {
            DiarizerSegment(start: $0.start, end: $0.end, speaker: Int($0.speaker))
        }
    }
    #endif

    deinit {
        #if canImport(SherpaOnnxC)
        SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer)
        #endif
    }
}

/// CAM++ voiceprints of selected clips over the sherpa-onnx C API (Android's `VoiceprintExtractor`): one print per
/// speaker from all of its windows, L2-normalised, with the seconds of audio behind it. `active` throws to cancel and
/// is called between native calls.
public enum VoiceprintExtractor {
    public static func compute(model: URL, audio: any PcmSource, windows: [String: [PrintWindow]],
                               active: () throws -> Void) throws -> [String: Voiceprint] {
        if windows.isEmpty { return [:] }
        try active()
        #if canImport(SherpaOnnxC)
        let config = VoiceprintConfig(model: model)
        guard fileExists(config.model) else { throw SherpaError.missingFiles }
        let extractor: OpaquePointer = try {
            let strings = [config.model.path, config.provider].map { strdup($0)! }
            defer { strings.forEach { free($0) } }
            var native = SherpaOnnxSpeakerEmbeddingExtractorConfig()
            native.model = UnsafePointer(strings[0])
            native.num_threads = config.threads
            native.provider = UnsafePointer(strings[1])
            guard let created = SherpaOnnxCreateSpeakerEmbeddingExtractor(&native) else { throw SherpaError.createFailed }
            return created
        }()
        defer { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }
        let dimension = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
        var prints: [String: Voiceprint] = [:]
        // Speakers in id order, so the native calls do not follow dictionary order.
        for speaker in windows.keys.sorted() {
            try active()
            guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { throw SherpaError.createFailed }
            defer { SherpaOnnxDestroyOnlineStream(stream) }
            var samples = 0
            for window in windows[speaker] ?? [] {
                try active()
                let start = min(max(window.startSample, 0), audio.sampleCount)
                let end = min(max(window.endSample, start), audio.sampleCount)
                guard end > start else { continue }
                let chunk = try audio.read(start, end - start)
                chunk.withUnsafeBufferPointer {
                    SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(audio.sampleRate), $0.baseAddress, Int32($0.count))
                }
                samples += end - start
            }
            SherpaOnnxOnlineStreamInputFinished(stream)
            guard samples > 0, SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
                  let embedding = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else { continue }
            let vector = Array(UnsafeBufferPointer(start: embedding, count: dimension))
            SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(embedding)
            if let normalised = Voiceprints.normalised(vector) {
                prints[speaker] = Voiceprint(vector: normalised, seconds: Double(samples) / Double(audio.sampleRate))
            }
        }
        try active()
        return prints
        #else
        throw SherpaError.notLinked
        #endif
    }
}
