import Foundation
import CassiniNotebook

/// The speaker models in the catalog (Android's SPEAKERS and VOICES parts): the Nemotron Sortformer diarizer and CAM++,
/// each from the model host as seekable Zstandard, each in its own revision directory. They install through the shared
/// `PinnedModelInstaller`, as one install of both parts. iOS shows them as one row ("Speaker models"), so their status
/// is one: ready when both are installed.
///
/// The speaker consent is iOS's own (`speakerModelsConsentAt`), which the caller checks; the install is `granted`.
public struct SpeakerModels: Sendable {
    public static let parts: Set<ModelPart> = [.speakers, .voices]

    public let repository: ModelRepository
    public let installer: PinnedModelInstaller

    public init(repository: ModelRepository, installer: PinnedModelInstaller) {
        self.repository = repository; self.installer = installer
    }

    public var root: URL { repository.root }

    /// The diarizer is installed: speakers can be told apart.
    public var diarizerReady: Bool { ModelCatalog.diarization.ready(in: root) }
    /// CAM++ is installed: voices can be matched.
    public var printsReady: Bool { ModelCatalog.voiceprint.ready(in: root) }

    public var diarizer: URL {
        URL(fileURLWithPath: ModelCatalog.diarization.path(in: root, ModelCatalog.diarizationModel.name))
    }
    public var voiceprint: URL {
        URL(fileURLWithPath: ModelCatalog.voiceprint.path(in: root, ModelCatalog.voiceprintModel.name))
    }

    /// What is still to install of the speaker parts.
    public var plan: ModelPlan { ModelPlan(ModelPlan.of(root: root).missing.filter { Self.parts.contains($0.part) }) }

    /// The free space the install of what is missing asks for before its first byte.
    public var installBytes: Int64 { plan.requiredFreeBytes }

    /// The status of the one row: an install of the speaker parts that runs, else ready, the failure the last install
    /// left, or not downloaded. `linked` false (a build without the native runtime) is unsupported.
    public func status(linked: Bool) -> ModelPartStatus {
        guard linked else { return .unsupported }
        if case .installing(let parts, let progress, _, _) = installer.status, !parts.isDisjoint(with: Self.parts) {
            guard let progress, Self.parts.contains(progress.part) else { return .downloading(nil) }
            return progress.verifying ? .checking : .downloading(fraction(of: progress))
        }
        if diarizerReady && printsReady { return .ready }
        for part in [ModelPart.speakers, .voices] {
            if case .failed(_, let detail)? = repository.status[part], let detail, let error = DownloadError(rawValue: detail) {
                return .failed(error)
            }
        }
        return .notDownloaded
    }

    /// Reads the files again, then the status.
    public func refresh(linked: Bool) async -> ModelPartStatus {
        await repository.refresh()
        return status(linked: linked)
    }

    /// Installs the missing speaker models, or joins the install that runs; `progress` gets the fraction of both
    /// downloads, then Checking files. Throws `SpeakerAnalysisError.download` when the diarizer, or CAM++ after it,
    /// could not be installed (offline: `NO_CONNECTION`), and `CancellationError` when cancelled.
    public func install(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        let plan = plan
        guard !plan.isEmpty else { return }
        let outcome = try await installer.install(Self.parts, granted: true) { report in
            progress(report.verifying ? .checking : .downloading(Self.fraction(of: report, plan: plan)))
        }
        switch outcome {
        case .installed(let skipped, let failed):
            for part in [ModelPart.speakers, .voices] where !part.primary.ready(in: root) {
                if let error = failed[part] {
                    let bytes = error == .notEnoughStorage ? ModelPlan(plan.missing.filter { $0.part == part }).requiredFreeBytes : 0
                    throw SpeakerAnalysisError.download(error, requiredFreeBytes: bytes)
                }
                if skipped.contains(part) { throw SpeakerAnalysisError.download(.noConnection, requiredFreeBytes: 0) }
            }
        case .failed(_, let error, let bytes):
            throw SpeakerAnalysisError.download(error, requiredFreeBytes: bytes)
        case .needsConsent:
            throw SpeakerAnalysisError.needsConsent
        }
    }

    private func fraction(of progress: DownloadProgress) -> Double? { Self.fraction(of: progress, plan: plan) }

    /// The share of the whole speaker download that `progress` (of one part) stands for.
    static func fraction(of progress: DownloadProgress, plan: ModelPlan) -> Double? {
        let items = plan.missing.filter { SpeakerModels.parts.contains($0.part) }
        let total = items.reduce(Int64(0)) { $0 + $1.downloadBytes }
        guard total > 0, progress.totalBytes > 0 else { return nil }
        let before = items.prefix { $0.part != progress.part }.reduce(Int64(0)) { $0 + $1.downloadBytes }
        let done = min(max(progress.doneBytes, 0), progress.totalBytes)
        return min(1, Double(before + done) / Double(total))
    }
}
