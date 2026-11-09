import Foundation
import CassiniEngine
import CassiniNotebook

/// The speech candidate of a system without Apple speech on a device where no other recognizer can run. It reports
/// the device failure (`JobFailure.model`), so a job is refused before it is queued and the note disables Transcribe
/// with the same caption as an Apple device without the model. It holds the Apple identity, the slot Apple's adapter
/// holds where the system has it, so a router that selects no recognizer reaches it; it never runs a job.
public struct UnavailableSpeechTranscriber: Transcribing {
    public init() {}
    public var recognizer: SpeechRecognizer { .appleSpeech }
    public func availability(locale: Locale) async -> SpeechAvailability { SpeechAvailability(assets: .unsupported, failure: .model) }
    public func assetStatus(locale: Locale) async -> ModelPartStatus { .unsupported }
    public func unavailability(locale: Locale) async -> JobFailure? { .model }
    public func speechLanguages() async -> [SpeechLanguage] { [] }
    public func runLanguage(requested: String) async -> String? { nil }
    public func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        throw TranscriptionError.failed(.model)
    }
    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        throw TranscriptionError.failed(.model)
    }
}
