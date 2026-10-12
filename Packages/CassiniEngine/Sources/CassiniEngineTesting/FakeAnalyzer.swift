import Foundation
import Synchronization
import CassiniEngine
import CassiniNotebook

/// A speaker analyzer that returns a fixed analysis, optionally after the test lets it go.
public final class FakeAnalyzer: SpeakerAnalyzing {
    private let analysis: SpeakerAnalysis
    private let identity: String?
    private let gate: Mutex<[CheckedContinuation<Void, Never>]?>
    private let calls = Mutex(0)

    /// With `suspends`, every analysis waits for `resume()`.
    public init(analysis: SpeakerAnalysis = SpeakerAnalysis(turns: [], prints: []), modelIdentity: String? = "fake-model",
                suspends: Bool = false) {
        self.analysis = analysis
        identity = modelIdentity
        gate = Mutex(suspends ? [] : nil)
    }

    public var analyzeCount: Int { calls.withLock { $0 } }

    public func analyze(url: URL, allowDownload: Bool,
                        progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        calls.withLock { $0 += 1 }
        progress(.analyzing(0))
        await withCheckedContinuation { continuation in
            let waits = gate.withLock { waiters in
                guard waiters != nil else { return false }
                waiters?.append(continuation)
                return true
            }
            if !waits { continuation.resume() }
        }
        try Task.checkCancellation()
        progress(.analyzing(1))
        return analysis
    }

    /// Lets every waiting analysis finish, and the next ones run straight through.
    public func resume() {
        let waiting = gate.withLock { waiters in defer { waiters = nil }; return waiters ?? [] }
        for continuation in waiting { continuation.resume() }
    }

    public var modelIdentity: String? { get async { identity } }
    public func modelStatus() async -> ModelPartStatus { identity == nil ? .notDownloaded : .ready }
}
