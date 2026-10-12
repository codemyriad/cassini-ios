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
}
