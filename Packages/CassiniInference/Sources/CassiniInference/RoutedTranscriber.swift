import Foundation
import CassiniEngine
import CassiniNotebook

/// New jobs can follow a live default; resolving a persisted identity always returns its concrete adapter.
/// Legacy jobs retain their original device-selected recognizer. Missing/unknown identities fail closed.
public struct RoutedTranscriber: Transcribing {
    private let legacy: any Transcribing
    private let candidates: [SpeechRecognizer: any Transcribing]
    private let selection: @Sendable () -> SpeechRecognizer

    public init(legacy: any Transcribing, preferred: (any Transcribing)? = nil, retained: (any Transcribing)? = nil) {
        self.legacy = legacy
        var candidates: [SpeechRecognizer: any Transcribing] = [legacy.recognizer: legacy]
        if let retained { candidates[retained.recognizer] = retained }
        if let preferred { candidates[preferred.recognizer] = preferred }
        self.candidates = candidates
        let identity = preferred?.recognizer ?? legacy.recognizer
        self.selection = { identity }
    }

    /// D78: verification or an explicit choice can change the next job's model without a relaunch.
    public init(legacy: any Transcribing, candidates: [any Transcribing],
                selection: @escaping @Sendable () -> SpeechRecognizer) {
        self.legacy = legacy
        self.candidates = candidates.reduce(into: [legacy.recognizer: legacy]) { $0[$1.recognizer] = $1 }
        self.selection = selection
    }

    private var selected: (any Transcribing)? { candidates[selection()] }
    public var recognizer: SpeechRecognizer { selection() }
    public func forJob(recognizer identity: String?) throws -> any Transcribing {
        guard let identity else { return legacy }
        guard let recognizer = SpeechRecognizer(rawValue: identity), let candidate = candidates[recognizer] else {
            throw TranscriptionError.failed(.model)
        }
        return candidate
    }
    public var assetInstallBytes: Int64 { selected?.assetInstallBytes ?? 0 }
    public func segmentation() async -> String? { await selected?.segmentation() }
    public func availability(locale: Locale) async -> SpeechAvailability {
        guard let selected else { return SpeechAvailability(assets: .unsupported, failure: .model) }
        return await selected.availability(locale: locale)
    }
    public func assetStatus(locale: Locale) async -> ModelPartStatus {
        guard let selected else { return .unsupported }
        return await selected.assetStatus(locale: locale)
    }
    public func unavailability(locale: Locale) async -> JobFailure? {
        guard let selected else { return .model }
        return await selected.unavailability(locale: locale)
    }
    public func speechLanguages() async -> [SpeechLanguage] { await selected?.speechLanguages() ?? [] }
    public func modelName(locale: Locale) async -> String? { await selected?.modelName(locale: locale) }
    public func runLanguage(requested: String) async -> String? { await selected?.runLanguage(requested: requested) }
    public func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        guard let selected else { throw TranscriptionError.failed(.model) }
        try await selected.installAssets(locale: locale, progress: progress)
    }
    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        guard let selected else { throw TranscriptionError.failed(.model) }
        return try await selected.transcribe(request, events: events)
    }
}
