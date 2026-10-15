import Foundation
import CassiniNotebook

/// Whether a job may download the models it needs. Without it the job waits as "Ready to transcribe" and nothing
/// touches the network.
public struct ModelConsent: Sendable {
    public let allows: @MainActor @Sendable (_ kind: JobKind, _ language: String) async -> Bool

    public init(_ allows: @escaping @MainActor @Sendable (_ kind: JobKind, _ language: String) async -> Bool) {
        self.allows = allows
    }

    /// The recorded consent, or nothing to download: for the transcribe kinds, Android's rule (`models.consentAt`, or
    /// Parakeet installed, `parakeetReady`), and on a device that falls back to Apple Speech its assets installed or not
    /// offered for the language (which the job then reports); the speaker models for speakers only.
    @MainActor public static func recorded(settings: SettingsStore, speech: any Transcribing,
                                           speakers: any SpeakerAnalyzing,
                                           parakeetReady: @escaping @Sendable () -> Bool) -> ModelConsent {
        ModelConsent { kind, language in
            switch kind {
            case .transcribe, .transcribeAgain:
                if settings.modelsConsentAt != nil || parakeetReady() { return true }
                let status = await speech.assetStatus(locale: Locale(identifier: language))
                return status == .ready || status == .unsupported
            case .speakersOnly:
                if settings.speakerModelsConsentAt != nil { return true }
                return await speakers.modelStatus() == .ready
            }
        }
    }

    public static let always = ModelConsent { _, _ in true }
}
