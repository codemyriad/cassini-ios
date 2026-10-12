#if DEBUG
import Foundation
import CassiniEngine
import CassiniNotebook

/// A transcriber that either returns fixed segments or stops at a fixed point and waits until it is cancelled.
public struct FakeTranscriber: Transcribing {
    public enum Script: Sendable {
        case returns([TranscriptSegment], total: TimeInterval)
        /// Reports `done` of `total` seconds and never finishes.
        case frozen(done: TimeInterval, total: TimeInterval)
        case fails(TranscriptionError)
    }

    public let script: Script
    public let status: ModelPartStatus

    public init(_ script: Script, status: ModelPartStatus = .ready) { self.script = script; self.status = status }

    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
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
        case .fails(let error):
            throw error
        }
    }

    public func assetStatus(locale: Locale) async -> ModelPartStatus { status }
}
#endif
