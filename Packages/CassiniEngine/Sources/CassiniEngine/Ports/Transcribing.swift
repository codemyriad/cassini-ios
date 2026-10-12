import Foundation
import CassiniNotebook

public struct TranscriptionRequest: Hashable, Sendable {
    public var url: URL
    /// BCP-47.
    public var language: String
    /// Where in the audio to begin, for a resumed job.
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

public protocol Transcribing: Sendable {
    func transcribe(_ request: TranscriptionRequest,
                    events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult
    func assetStatus(locale: Locale) async -> ModelPartStatus
}
