import Foundation
import CassiniEngine
import CassiniNotebook

/// The preference is immutable for one app launch; the queue persists the chosen identity. Legacy jobs always
/// retain their original device-selected recognizer, and an unknown/disabled identity fails closed.
public struct RoutedTranscriber: Transcribing {
    private let legacy: any Transcribing
    private let retained: (any Transcribing)?
    private let preferred: (any Transcribing)?
    public init(legacy: any Transcribing, preferred: (any Transcribing)? = nil, retained: (any Transcribing)? = nil) {
        self.legacy = legacy; self.preferred = preferred; self.retained = retained
    }
    private var selected: any Transcribing { preferred ?? legacy }
    public var recognizer: SpeechRecognizer { selected.recognizer }
    public func forJob(recognizer identity: String?) throws -> any Transcribing {
        guard let identity else { return legacy }
        if let preferred, identity == preferred.recognizer.rawValue { return preferred }
        if identity == legacy.recognizer.rawValue { return legacy }
        if let retained, identity == retained.recognizer.rawValue { return retained }
        throw TranscriptionError.failed(.model)
    }
    public var assetInstallBytes: Int64 { selected.assetInstallBytes }
    public func segmentation() async -> String? { await selected.segmentation() }
    public func assetStatus(locale: Locale) async -> ModelPartStatus { await selected.assetStatus(locale: locale) }
    public func unavailability(locale: Locale) async -> JobFailure? { await selected.unavailability(locale: locale) }
    public func speechLanguages() async -> [SpeechLanguage] { await selected.speechLanguages() }
    public func modelName(locale: Locale) async -> String? { await selected.modelName(locale: locale) }
    public func runLanguage(requested: String) async -> String? { await selected.runLanguage(requested: requested) }
    public func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await selected.installAssets(locale: locale, progress: progress)
    }
    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        try await selected.transcribe(request, events: events)
    }
}
