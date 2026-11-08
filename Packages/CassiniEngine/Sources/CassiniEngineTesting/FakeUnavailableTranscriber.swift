#if DEBUG
import Foundation
import CassiniEngine
import CassiniNotebook

/// Hardware/model and locale failures share an asset status but remain distinct admission failures.
public struct FakeUnavailableTranscriber: Transcribing {
    public let failure: JobFailure
    public init(_ failure: JobFailure) { self.failure = failure }
    public func availability(locale: Locale) async -> SpeechAvailability { SpeechAvailability(assets: .unsupported, failure: failure) }
    public func assetStatus(locale: Locale) async -> ModelPartStatus { .unsupported }
    public func unavailability(locale: Locale) async -> JobFailure? { failure }
    public func speechLanguages() async -> [SpeechLanguage] { [] }
    public func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        throw TranscriptionError.failed(failure)
    }
    public func transcribe(_ request: TranscriptionRequest, events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        throw TranscriptionError.failed(failure)
    }
}
#endif
