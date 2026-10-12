import Foundation
import CassiniNotebook

/// Whether a job may download the models it needs. Without it the job waits as "Ready to transcribe" and nothing
/// touches the network.
public struct ModelConsent: Sendable {
    public let allows: @MainActor @Sendable (_ kind: JobKind, _ language: String) async -> Bool

    public init(_ allows: @escaping @MainActor @Sendable (_ kind: JobKind, _ language: String) async -> Bool) {
        self.allows = allows
    }

    /// The recorded consent, or models that are installed already: the speech model for the transcribe kinds, the
    /// speaker models for speakers only.
    @MainActor public static func recorded(settings: SettingsStore, speech: any Transcribing,
                                           speakers: any SpeakerAnalyzing) -> ModelConsent {
        ModelConsent { kind, language in
            switch kind {
            case .transcribe, .transcribeAgain:
                if settings.modelsConsentAt != nil { return true }
                return await speech.assetStatus(locale: Locale(identifier: language)) == .ready
            case .speakersOnly:
                if settings.speakerModelsConsentAt != nil { return true }
                return await speakers.modelStatus() == .ready
            }
        }
    }

    public static let always = ModelConsent { _, _ in true }
}
