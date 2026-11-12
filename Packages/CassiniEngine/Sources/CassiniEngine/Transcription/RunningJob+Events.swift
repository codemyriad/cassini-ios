import Foundation
import CassiniNotebook

extension RunningJob {
    /// The running job after `event`: its phase, and its overall progress where the event tells it. The progress never
    /// goes back within a run.
    public func applying(_ event: JobEvent) -> RunningJob {
        // Events already in flight must not undo an admitted Stop. Checkpoint persistence is handled separately
        // by the coordinator, and only the real outcome clears this running job.
        guard phase != .stopping else { return self }
        var job = self
        switch event {
        case .waitingForPrevious:
            job.phase = .starting
        case .downloading(let progress):
            job.phase = .downloading(progress.map { Double($0.percent) / 100 })
        case .started(let start):
            job.phase = .transcribing
            if let restored = start.restored, restored.totalMs > 0 {
                job.advance(to: Double(restored.doneMs) / Double(restored.totalMs))
            }
        case .stageChanged(let stage, _, _):
            job.phase = Self.phase(of: stage, current: job.phase)
        case .windowDone(let doneMs, let totalMs, _):
            job.phase = .transcribing
            if totalMs > 0 { job.advance(to: Double(doneMs) / Double(totalMs)) }
        case .namingClosed(let matching):
            if matching { job.phase = .matching }
        case .stopping:
            job.phase = .stopping
        case .reading, .draft, .checkpointed, .speakersUnavailable, .ended:
            break
        }
        return job
    }

    /// Below 100 % until the job has ended, and never lower than before.
    private mutating func advance(to value: Double) {
        let capped = min(max(value, 0), 0.99)
        fraction = max(fraction ?? 0, capped)
    }

    private static func phase(of stage: TranscriptionStage, current: ProcessingPhase) -> ProcessingPhase {
        if current == .stopping { return current }
        switch stage {
        case .reading, .preparing: return .starting
        case .words: return .transcribing
        case .speakers: return .identifyingSpeakers
        case .matching: return .matching
        case .saving: return .saving
        }
    }
}
