import Foundation
import CryptoKit
import FluidAudio
import CassiniEngine
import CassiniNotebook

/// One inference job at a time, off the UI actor. FluidAudio receives only local file URLs.
public actor SpeakerAnalyzer: SpeakerAnalyzing {
    public static let modelID = "pyannote-community-1-wespeaker-coreml-v1"
    public static var modelsAvailable: Bool {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        let root = support.appendingPathComponent("CassiniModels/speaker-diarization")
        let models = ["Segmentation", "FBank", "Embedding", "PldaRho"]
        return models.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0).mlmodelc/coremldata.bin").path) }
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("plda-parameters.json").path)
    }
    private var busy = false
    public init() {}

    private var identity: String?

    public var modelIdentity: String? {
        get async {
            if let identity { return identity }
            guard Self.modelsAvailable, let cache = try? Self.cacheDirectory(), let fingerprint = try? Self.fingerprint(cache) else { return nil }
            identity = Self.modelID + ":" + fingerprint
            return identity
        }
    }

    public func modelStatus() async -> ModelPartStatus { Self.modelsAvailable ? .ready : .notDownloaded }

    public func analyze(url: URL, allowDownload: Bool, progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        guard !busy else { throw AnalyzerError.busy }
        busy = true; defer { busy = false; ModelHub.offlineMode = true }
        ModelHub.offlineMode = !allowDownload
        var config = OfflineDiarizerConfig.default
        config.embedding.batchSize = 4
        let manager = OfflineDiarizerManager(config: config)
        let cache = try Self.cacheDirectory()
        progress(.preparingModels(nil))
        let models = try await OfflineDiarizerModels.load(from: cache, progressHandler: { update in
            progress(.preparingModels(update.fractionCompleted))
        })
        try Task.checkCancellation()
        let fingerprint = try Self.fingerprint(cache)
        identity = Self.modelID + ":" + fingerprint
        manager.initialize(models: models)
        let result = try await manager.process(url, progressCallback: { count, total in
            progress(.analyzing(Double(count) / Double(max(1, total))))
        })
        try Task.checkCancellation()
        let turns = result.segments.map { SpeakerTurn(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        let database: [String: [Float]] = result.speakerDatabase ?? [:]
        var prints: [SpeakerPrint] = []
        for (id, vector) in database {
            guard let normalized = VoiceMatcher.normalized(vector) else { continue }
            // Only isolated speech counts toward eligibility for remembering a voice.
            let seconds = SpeakerAttribution.isolatedSeconds(speakerID: id, turns: turns)
            prints.append(SpeakerPrint(speakerID: id, model: Self.modelID + ":" + fingerprint, vector: normalized, speechSeconds: seconds))
        }
        return SpeakerAnalysis(turns: turns, prints: prints)
    }
    private static func cacheDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var cache = support.appendingPathComponent("CassiniModels", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try cache.setResourceValues(values)
        return cache
    }

    private static func fingerprint(_ cache: URL) throws -> String {
        var digest = SHA256()
        for model in ["Embedding", "FBank", "PldaRho"] {
            for file in ["model.mil", "weights/weight.bin"] {
                let relative = "speaker-diarization/\(model).mlmodelc/\(file)"
                digest.update(data: Data(relative.utf8))
                let handle = try FileHandle(forReadingFrom: cache.appendingPathComponent(relative))
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 65_536), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    enum AnalyzerError: LocalizedError {
        case busy
        var errorDescription: String? { "Speaker analysis is already running." }
    }
}
