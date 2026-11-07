import Foundation
import CassiniNotebook

/// Whether a job may download the models it needs. Without it the job waits as "Ready to transcribe" and nothing
/// touches the network.
public struct ModelConsent: Sendable {
    public let allows: @MainActor @Sendable (_ kind: JobKind, _ language: String) async -> Bool

    public let unavailability: @MainActor @Sendable (_ kind: JobKind, _ language: String) async -> JobFailure?

    public init(unavailability: @escaping @MainActor @Sendable (JobKind, String) async -> JobFailure? = { _, _ in nil },
                _ allows: @escaping @MainActor @Sendable (_ kind: JobKind, _ language: String) async -> Bool) {
        self.allows = allows; self.unavailability = unavailability
    }

    /// The recorded consent, or nothing to download: for the transcribe kinds, Android's rule (`models.consentAt`, or
    /// Parakeet installed, `parakeetReady`), and on a device that keeps Apple Speech (decision D2) also Apple's speech
    /// assets installed. Unavailable hardware/locales are refused separately before consent or queue admission. On a Parakeet device Apple's
    /// assets never count: iOS may have installed them for dictation, which is no consent to the Parakeet download. The
    /// speaker models for speakers only.
    @MainActor public static func recorded(settings: SettingsStore, speech: any Transcribing,
                                           speakers: any SpeakerAnalyzing,
                                           parakeetReady: @escaping @Sendable () -> Bool) -> ModelConsent {
        ModelConsent(unavailability: { kind, language in
            guard kind != .speakersOnly else { return nil }
            return await speech.unavailability(locale: Locale(identifier: language))
        }) { kind, language in
            switch kind {
            case .transcribe, .transcribeAgain:
                if settings.modelsConsentAt != nil || parakeetReady() { return true }
                guard speech.recognizer == .appleSpeech else { return false }
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
