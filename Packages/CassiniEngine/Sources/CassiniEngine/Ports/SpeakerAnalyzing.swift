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

public protocol SpeakerAnalyzing: Sendable {
    func analyze(url: URL, allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis
    /// The installed model and its weights, as stored with each voiceprint; nil while no model is installed.
    var modelIdentity: String? { get async }
    func modelStatus() async -> ModelPartStatus
}
