import Foundation
import CassiniNotebook

public struct SpeakerAnalysis: Hashable, Sendable {
    public var turns: [SpeakerTurn]
    public var prints: [SpeakerPrint]
    /// What ran, for the `x-speakerDiarization` record: the library and how it ran (nil: `fluidaudio`), the revision
    /// the models were installed from, and the time the analysis itself took, without the model install.
    public var backend: String?
    public var modelRevision: String?
    public var elapsedMs: Int64?
    public init(turns: [SpeakerTurn], prints: [SpeakerPrint], backend: String? = nil, modelRevision: String? = nil,
                elapsedMs: Int64? = nil) {
        self.turns = turns; self.prints = prints
        self.backend = backend; self.modelRevision = modelRevision; self.elapsedMs = elapsedMs
    }
}

/// How far a model install has got.
public enum InstallProgress: Hashable, Sendable {
    /// The files are being fetched: the fraction done, nil while unknown.
    case downloading(Double?)
    /// Every file is checked before it is used ("Checking files").
    case checking
}

public enum SpeakerAnalysisEvent: Hashable, Sendable {
    /// Speaker models are being loaded, downloaded or checked.
    case preparingModels(InstallProgress)
    case analyzing(Double)
}

/// Why the speaker models are not there for an analysis or a standalone install.
public enum SpeakerAnalysisError: Error, Hashable, Sendable {
    /// The models are missing and downloading them was not allowed; nothing touched the network.
    case needsConsent
    /// The install failed. `requiredFreeBytes` is what the space check asked for ("Free about N MB"), else 0.
    case download(DownloadError, requiredFreeBytes: Int64)
}

/// The speaker models and the analysis that uses them. One install runs at a time: a request that arrives while one
/// runs joins it, and an analysis that arrives while another runs waits for it rather than failing.
public protocol SpeakerAnalyzing: Sendable {
    /// Installs the models first when they are missing and `allowDownload`, else throws
    /// `SpeakerAnalysisError.needsConsent`. A failed install throws `SpeakerAnalysisError.download`.
    func analyze(url: URL, allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis
    /// The installed model and its weights, as stored with each voiceprint; nil while no model is installed.
    var modelIdentity: String? { get async }
    /// The stored status of the models: what the last check or install found, or the install that runs.
    func modelStatus() async -> ModelPartStatus
    /// Checks the installed files again (at launch, and when Settings opens) and returns the new status.
    func refreshModelStatus() async -> ModelPartStatus
    /// Downloads and installs the models now (the model download screen's standalone Download), or joins the install
    /// that runs, reporting how far it has got. Does nothing when they are installed; a failed install throws
    /// `SpeakerAnalysisError.download`.
    func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws
    /// Cancels the models' install that runs, if any: every caller waiting on it, an analysis or the standalone
    /// download, stops with `CancellationError`. The files fetched so far, partial ones too, stay for the next install.
    func cancelModelInstall() async
    /// The free space an install of the models asks for before its first byte; the model download screen asks for the
    /// same.
    var modelInstallBytes: Int64 { get }
}
