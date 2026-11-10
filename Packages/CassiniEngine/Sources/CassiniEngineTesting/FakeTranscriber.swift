#if DEBUG
import Foundation
import CassiniEngine
import CassiniNotebook

/// A transcriber that either returns fixed segments or stops at a fixed point and waits until it is cancelled. Like
/// Apple's, it asks for consent when its model is not downloaded and the request may not download it.
public struct FakeTranscriber: Transcribing {
    public enum Script: Sendable {
        case returns([TranscriptSegment], total: TimeInterval)
        /// Finalizes `draft`, reports `done` of `total` seconds and never finishes.
        /// With `pace`, two reports `pace` seconds of audio apart come first, as long apart as the job lets its
        /// results be, so it measures its speed and estimates the time left.
        case frozen(done: TimeInterval, total: TimeInterval, draft: [TranscriptSegment] = [], pace: TimeInterval? = nil)
        /// Downloads the speech model up to `fraction` and never finishes.
        case downloading(fraction: Double)
        /// Finalizes one of `segments` every `interval`, then never finishes: a draft that grows.
        case growing([TranscriptSegment], every: Duration, total: TimeInterval)
        case fails(TranscriptionError)
    }

    public let script: Script
    private static let resultInterval = Duration.milliseconds(1_200)
    public let status: ModelPartStatus
    /// Apple Speech, or Parakeet as on a device that can hold Ultra: the model download screen and the Settings row
    /// then show Ultra's sizes.
    public let recognizer: SpeechRecognizer

    public init(_ script: Script, status: ModelPartStatus = .ready, recognizer: SpeechRecognizer = .appleSpeech) {
        self.script = script; self.status = status; self.recognizer = recognizer
    }

    /// Parakeet's figure for a fresh install of Ultra and its detector, or the estimate for Apple's assets.
    public var assetInstallBytes: Int64 {
        recognizer == .parakeet ? ModelPlan([ModelPlan.Item(.speech, ModelPart.speech.models)]).requiredFreeBytes
            : ModelDownloadPlan.speechInstallBytes
    }

    public func modelName(locale: Locale) async -> String? { "Fake SpeechTranscriber \(locale.identifier(.bcp47))" }

    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        if status == .notDownloaded, !request.allowDownload { throw TranscriptionError.needsConsent }
        switch script {
        case .returns(let segments, let total):
            return try finalize(segments, total: total, events: events)
        case .frozen(let done, let total, let draft, let pace):
            for segment in draft { events(.finalized(segment)) }
            // The job shows its results at most once a second; a report after the pause is shown whole.
            if !draft.isEmpty || pace != nil { try await Task.sleep(for: Self.resultInterval) }
            if let pace {
                for back in [2.0, 1.0] {
                    events(.progress(done: done - back * pace, total: total))
                    try await Task.sleep(for: Self.resultInterval)
                }
            }
            events(.progress(done: done, total: total))
            while true { try await Task.sleep(for: .seconds(3600)) }
        case .downloading(let fraction):
            events(.preparingModel(.downloading(fraction)))
            while true { try await Task.sleep(for: .seconds(3600)) }
        case .growing(let segments, let interval, let total):
            for segment in segments {
                try await Task.sleep(for: interval)
                events(.finalized(segment))
                events(.progress(done: segment.end, total: total))
            }
            while true { try await Task.sleep(for: .seconds(3600)) }
        case .fails(let error):
            throw error
        }
    }

    private func finalize(_ segments: [TranscriptSegment], total: TimeInterval,
                          events: @Sendable (TranscriptionEvent) -> Void) throws -> TranscriptionResult {
        for segment in segments {
            try Task.checkCancellation()
            events(.finalized(segment))
            events(.progress(done: segment.end, total: total))
        }
        return TranscriptionResult(segments: segments)
    }

    public func assetStatus(locale: Locale) async -> ModelPartStatus { status }

    /// Reports the download as done at once; nothing is installed, so `assetStatus` stays as it was.
    public func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        progress(.downloading(1))
    }
}
#endif
