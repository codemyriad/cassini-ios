import Foundation
import CryptoKit
import FluidAudio
import CassiniEngine
import CassiniNotebook

/// FluidAudio's offline speaker pipeline, off the UI actor; it receives only local file URLs.
///
/// The models come from `SpeakerModelInstaller`, pinned to `SpeakerModelManifest.diarizer` and checked file by file.
/// An analysis that arrives while another runs waits its turn; a request that arrives during an install joins it. The
/// models are always loaded with FluidAudio offline, so a load never downloads on its own: downloads happen only in
/// the installer, which opens the network through `ModelNetworkGate` while it fetches.
public actor SpeakerAnalyzer: SpeakerAnalyzing {
    public static let modelID = "pyannote-community-1-wespeaker-coreml-v1"
    public static let manifest = SpeakerModelManifest.diarizer

    /// Loads the installed models from the models directory and analyses one local file with them.
    public typealias Analysis = @Sendable (_ url: URL, _ models: URL,
                                           _ progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis

    public nonisolated let installer: SpeakerModelInstaller
    private let analysis: Analysis
    private var identity: String?
    private var analyzing = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    /// `directory` is where the models go (Application Support/CassiniModels, excluded from backups); `storage` tells the
    /// free space there before a download.
    public init(directory: URL = SpeakerAnalyzer.defaultDirectory, storage: any StorageProbe,
                network: ModelNetworkGate = .fluidAudio) {
        self.init(installer: SpeakerModelInstaller(manifest: Self.manifest, directory: directory, storage: storage,
                                                   network: network, fetch: Self.fetchFromHub),
                  network: network, analysis: Self.fluidAudioAnalysis(network: network))
    }

    /// An analyzer over `installer` whose `analysis` does the work; tests pass a fake one.
    public init(installer: SpeakerModelInstaller, network: ModelNetworkGate, analysis: @escaping Analysis) {
        self.installer = installer
        self.analysis = analysis
        network.close()
    }

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("CassiniModels", isDirectory: true)
    }

    /// The free space an install of the models asks for, as the installer checks it.
    public nonisolated var modelInstallBytes: Int64 { installer.manifest.requiredFreeBytes }

    public var modelIdentity: String? {
        get async {
            if let identity { return identity }
            guard await installer.status() == .ready, let fingerprint = try? Self.fingerprint(installer.directory) else {
                return nil
            }
            identity = Self.modelID + ":" + fingerprint
            return identity
        }
    }

    public func modelStatus() async -> ModelPartStatus { await installer.status() }

    public func refreshModelStatus() async -> ModelPartStatus {
        let status = await installer.refresh()
        if status != .ready { identity = nil }
        return status
    }

    public func installModels(progress: @escaping @Sendable (Double?) -> Void) async throws {
        try await installer.install(allowDownload: true, progress: progress)
    }

    public func analyze(url: URL, allowDownload: Bool,
                        progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        progress(.preparingModels(nil))
        try await installer.install(allowDownload: allowDownload) { progress(.preparingModels($0)) }
        await takeTurn()
        defer { endTurn() }
        try Task.checkCancellation()
        let result = try await analysis(url, try Self.prepare(installer.directory), progress)
        if let model = result.prints.first?.model { identity = model }
        return result
    }

    /// FluidAudio's offline diarizer over the installed models.
    private static func fluidAudioAnalysis(network: ModelNetworkGate) -> Analysis {
        { url, directory, progress in
            var config = OfflineDiarizerConfig.default
            config.embedding.batchSize = 4
            let manager = OfflineDiarizerManager(config: config)
            // Installed and checked: the load reads the files only. With the network closed a damaged file fails the
            // load instead of being fetched again behind the user's back.
            network.close()
            let models = try await OfflineDiarizerModels.load(from: directory)
            try Task.checkCancellation()
            let fingerprint = try Self.fingerprint(directory)
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
    }

    /// One analysis at a time, in the order they arrived.
    private func takeTurn() async {
        guard analyzing else {
            analyzing = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    private func endTurn() {
        if queue.isEmpty { analyzing = false } else { queue.removeFirst().resume() }
    }

    /// FluidAudio's download of the pinned revision into `directory/speaker-diarization`.
    @Sendable private static func fetchFromHub(_ directory: URL, _ report: @escaping @Sendable (Double?) -> Void) async throws {
        let directory = try prepare(directory)
        try await ModelHub.download(.diarizer, to: directory, variant: "offline") { update in
            // The download is the first half of FluidAudio's progress; the second is compiling, which a download
            // alone skips.
            if case .downloading = update.phase { report(min(update.fractionCompleted * 2, 1)) } else { report(nil) }
        }
    }

    /// Creates the models directory, out of backups.
    private static func prepare(_ directory: URL) throws -> URL {
        var directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    private static func fingerprint(_ cache: URL) throws -> String {
        var digest = SHA256()
        for model in ["Embedding", "FBank", "PldaRho"] {
            for file in ["model.mil", "weights/weight.bin"] {
                let relative = "\(manifest.folder)/\(model).mlmodelc/\(file)"
                digest.update(data: Data(relative.utf8))
                let handle = try FileHandle(forReadingFrom: cache.appendingPathComponent(relative))
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 65_536), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
