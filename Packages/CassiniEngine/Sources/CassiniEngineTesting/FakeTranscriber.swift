#if DEBUG
import Foundation
import CassiniEngine
import CassiniNotebook

/// A transcriber that either returns fixed segments or stops at a fixed point and waits until it is cancelled. Like
/// Apple's, it asks for consent when its model is not downloaded and the request may not download it.
public struct FakeTranscriber: Transcribing {
    public enum Script: Sendable {
        case returns([TranscriptSegment], total: TimeInterval)
        /// Reports `done` of `total` seconds and never finishes.
        case frozen(done: TimeInterval, total: TimeInterval)
        /// Downloads the speech model up to `fraction` and never finishes.
        case downloading(fraction: Double)
        case fails(TranscriptionError)
    }

    public let script: Script
    public let status: ModelPartStatus

    public init(_ script: Script, status: ModelPartStatus = .ready) { self.script = script; self.status = status }

    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        if status == .notDownloaded, !request.allowDownload { throw TranscriptionError.needsConsent }
        switch script {
        case .returns(let segments, let total):
            for segment in segments {
                try Task.checkCancellation()
                events(.finalized(segment))
                events(.progress(done: segment.end, total: total))
            }
            return TranscriptionResult(segments: segments)
        case .frozen(let done, let total):
            events(.progress(done: done, total: total))
            while true { try await Task.sleep(for: .seconds(3600)) }
        case .downloading(let fraction):
            events(.preparingModel(fraction))
            while true { try await Task.sleep(for: .seconds(3600)) }
        case .fails(let error):
            throw error
        }
    }

    public func assetStatus(locale: Locale) async -> ModelPartStatus { status }

    /// Reports the download as done at once; nothing is installed, so `assetStatus` stays as it was.
    public func installAssets(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(1)
    }
}
#endif
