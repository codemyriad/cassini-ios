import Foundation
import CassiniNotebook

public struct TranscriptionRequest: Hashable, Sendable {
    public var url: URL
    /// BCP-47.
    public var language: String
    /// Where in the audio to begin, for a resumed job. Result times stay on the recording's clock.
    public var startOffset: TimeInterval
    /// Whether a missing speech model may be downloaded.
    public var allowDownload: Bool
    public init(url: URL, language: String, startOffset: TimeInterval = 0, allowDownload: Bool) {
        self.url = url; self.language = language; self.startOffset = startOffset; self.allowDownload = allowDownload
    }
}

public enum TranscriptionEvent: Hashable, Sendable {
    /// The speech model is being prepared or downloaded; the fraction is nil while unknown.
    case preparingModel(Double?)
    /// Audio up to `done` seconds of `total` is transcribed.
    case progress(done: TimeInterval, total: TimeInterval)
    /// A result that will not change any more.
    case finalized(TranscriptSegment)
    /// The words heard after the last finalized result so far; they may still change. Nil when there are none.
    case volatile(TranscriptSegment?)
}

public struct TranscriptionResult: Hashable, Sendable {
    /// In time order.
    public var segments: [TranscriptSegment]
    public init(segments: [TranscriptSegment]) { self.segments = segments }
}

public enum TranscriptionError: Error, Hashable {
    case failed(JobFailure)
    /// The speech model is missing and downloading it was not allowed.
    case needsConsent
}

/// A transcriber that read its input to the end reports `.progress(done: total, total: total)` before it returns; one
/// that cannot read the input to the end throws `TranscriptionError.failed(.open)` rather than returning what it has.
public protocol Transcribing: Sendable {
    func transcribe(_ request: TranscriptionRequest,
                    events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult
    func assetStatus(locale: Locale) async -> ModelPartStatus
    /// Downloads and installs the speech model for `locale` now, as the model download screen's Download does,
    /// reporting the fraction done. Does nothing when it is installed or not offered for `locale`; a failed download
    /// or install throws `TranscriptionError.failed(.download(_))`.
    func installAssets(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws
    /// The languages the speech model can transcribe here, each marked when its assets are installed.
    func speechLanguages() async -> [SpeechLanguage]
    /// The speech model that transcribes `locale` here, as the provenance's `model` names it; nil when unknown.
    func modelName(locale: Locale) async -> String?
}

extension Transcribing {
    public func modelName(locale: Locale) async -> String? { nil }
}

/// A language of speech the transcriber offers.
public struct SpeechLanguage: Hashable, Sendable {
    /// BCP-47, as `SettingsStore.speechLanguage` stores it.
    public var id: String
    /// Its speech assets are on the device.
    public var installed: Bool
    public init(id: String, installed: Bool) { self.id = id; self.installed = installed }
}
