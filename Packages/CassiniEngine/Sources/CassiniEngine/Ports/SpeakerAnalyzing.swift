import Foundation
import CassiniNotebook

public struct SpeakerAnalysis: Hashable, Sendable {
    public var turns: [SpeakerTurn]
    public var prints: [SpeakerPrint]
    public init(turns: [SpeakerTurn], prints: [SpeakerPrint]) { self.turns = turns; self.prints = prints }
}

public enum SpeakerAnalysisEvent: Hashable, Sendable {
    /// Speaker models are being loaded or downloaded; the fraction is nil while unknown.
    case preparingModels(Double?)
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
    /// that runs, reporting the fraction done (nil while unknown). Does nothing when they are installed; a failed
    /// install throws `SpeakerAnalysisError.download`.
    func installModels(progress: @escaping @Sendable (Double?) -> Void) async throws
}
