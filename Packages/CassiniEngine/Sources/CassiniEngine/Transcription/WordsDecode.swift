import Foundation
import Synchronization
import CassiniNotebook

/// The words step of one run: gathers the transcriber's results, saves checkpoints, applies the limits and turns a
/// stop into a saved checkpoint. The transcriber calls `handle` in order from its own thread; the job calls `attach`,
/// `stopRequested` from its stop watch, and `finish` once the transcriber returned.
final class WordsDecode: Sendable {
    enum Ending: Sendable {
        case complete(CheckpointState)
        case stopped(StopRequest)
        case failed(JobFailure)
        case needsConsent
    }

    /// Draft events go out at most this often, and less often for long drafts: each one carries every word.
    static let minimumEmitIntervalMs: Int64 = 1_000
    static let wordsPerEmitMs = 50

    private struct State: Sendable {
        var checkpoint: CheckpointState
        var savedMs: Int64
        var savedAt: Int64?
        var words: [DraftWord]
        var volatile: [DraftWord] = []
        /// Transcribed audio as the transcriber reports it; at least `checkpoint.doneMs`.
        var progressMs: Int64
        var shownMs: Int64
        var wordsShown = false
        var emittedAt: Int64?
        var finalizedThisRun = false
        var ended: Ending?
        var stopping = false
        var task: Task<TranscriptionResult, any Error>?
        var cancelPending = false
    }

    private let state: Mutex<State>
    private let noteID: UUID
    private let resumeDoneMs: Int64
    private let limits: TranscriptionJob.Limits
    private let checkpoints: any CheckpointStoring
    private let stop: StopSignal
    private let events: @Sendable (JobEvent) -> Void
    private let uptimeMs: @Sendable () -> Int64
    private let startedAt: Int64
    private let base: CheckpointState

    init(base: CheckpointState, noteID: UUID, resumeDoneMs: Int64, limits: TranscriptionJob.Limits,
         checkpoints: any CheckpointStoring, stop: StopSignal, events: @escaping @Sendable (JobEvent) -> Void,
         uptimeMs: @escaping @Sendable () -> Int64) {
        var resumed = base
        if resumeDoneMs > 0 { resumed.resumedFromMs = resumeDoneMs }
        self.base = base
        self.noteID = noteID; self.resumeDoneMs = resumeDoneMs; self.limits = limits; self.checkpoints = checkpoints
        self.stop = stop; self.events = events; self.uptimeMs = uptimeMs
        startedAt = uptimeMs()
        state = Mutex(State(checkpoint: resumed, savedMs: base.doneMs, words: base.draftWords, progressMs: base.doneMs,
                            shownMs: base.doneMs))
    }

    /// The transcriber's task, cancelled once the step ends early.
    func attach(_ task: Task<TranscriptionResult, any Error>) {
        state.withLock { s in
            s.task = task
            if s.cancelPending { task.cancel() }
        }
    }

    func handle(_ event: TranscriptionEvent) {
        state.withLock { s in
            guard s.ended == nil else { return }
            switch event {
            case .preparingModel(let fraction):
                events(.downloading(fraction.map(TranscriptionJob.fractionProgress(.speech))))
            case .progress(let done, let total):
                guard accept(total: CheckpointState.ms(total), &s) else { return }
                s.progressMs = max(s.progressMs, CheckpointState.ms(done))
                emit(&s, force: false)
            case .finalized(let segment):
                finalize(segment, &s)
            case .volatile(let segment):
                s.volatile = segment.map { $0.draftWords.filter { $0.endMs > s.checkpoint.doneMs } } ?? []
                emit(&s, force: false)
            }
        }
    }

    /// The stop watch saw a stop.
    func stopRequested(_ request: StopRequest) {
        state.withLock { s in
            guard s.ended == nil else { return }
            requestStop(request, &s)
        }
    }

    /// How the step ended, once the transcriber returned with `result`.
    func finish(_ result: Result<TranscriptionResult, any Error>) -> Ending {
        state.withLock { s in
            if let ended = s.ended { return ended }
            switch result {
            case .failure(TranscriptionError.needsConsent):
                return .needsConsent
            case .failure(TranscriptionError.failed(let failure)):
                return .failed(failure)
            case .failure(let error):
                if let request = stop.request { requestStop(request, &s); return s.ended ?? .stopped(request) }
                return error is CancellationError ? .stopped(.cancel) : .failed(.unknown)
            case .success(let transcription):
                if !s.finalizedThisRun {
                    for segment in transcription.segments { finalize(segment, &s) }
                    if let ended = s.ended { return ended }
                }
            }
            // Every bit of the audio is transcribed.
            let lastEnd = s.checkpoint.segments.last.map { CheckpointState.ms($0.end) } ?? 0
            s.checkpoint.doneMs = max(s.checkpoint.doneMs, s.checkpoint.totalMs, lastEnd)
            if s.checkpoint.totalMs == 0 { s.checkpoint.totalMs = s.checkpoint.doneMs }
            s.progressMs = s.checkpoint.doneMs
            s.volatile = []
            guard s.checkpoint.totalMs >= limits.minDurationMs else { return .failed(.short) }
            guard fits(s) else { return .failed(.long) }
            if let request = stop.request {
                requestStop(request, &s, complete: true)
                return s.ended ?? .stopped(request)
            }
            guard save(&s, complete: true) else { return .failed(.save) }
            emit(&s, force: true)
            return .complete(s.checkpoint)
        }
    }

    // MARK: - Under the lock

    private func finalize(_ segment: TranscriptSegment, _ s: inout State) {
        guard accept(total: s.checkpoint.totalMs, &s) else { return }
        s.finalizedThisRun = true
        let kept = resumeDoneMs > 0 ? segment.resumed(after: resumeDoneMs) : segment
        if let kept, !kept.text.isEmpty {
            s.checkpoint.segments.append(kept)
            s.words.append(contentsOf: kept.draftWords)
        }
        s.checkpoint.doneMs = max(s.checkpoint.doneMs, CheckpointState.ms(segment.end))
        s.progressMs = max(s.progressMs, s.checkpoint.doneMs)
        s.volatile.removeAll { $0.endMs <= s.checkpoint.doneMs }
        // A stop is honoured at the result boundary.
        if let request = stop.request { requestStop(request, &s); return }
        let now = uptimeMs()
        if SpeechWindows.checkpointDue(doneMs: s.checkpoint.doneMs, savedMs: s.savedMs, nowMs: now, savedAt: s.savedAt) {
            guard fits(s) else { end(.failed(.long), &s); return }
            guard save(&s, complete: false) else { end(.failed(.save), &s); return }
        }
        emit(&s, force: false)
    }

    /// False, and the step ends with `LONG`, when the audio is longer than the limit.
    private func accept(total: Int64, _ s: inout State) -> Bool {
        guard total <= limits.maxDurationMs else { end(.failed(.long), &s); return false }
        if total > 0 { s.checkpoint.totalMs = total }
        return true
    }

    private func requestStop(_ request: StopRequest, _ s: inout State, complete: Bool = false) {
        guard !s.stopping else { return }
        s.stopping = true
        events(.stopping)
        if case .pause = request, s.checkpoint.doneMs > s.savedMs || complete, s.checkpoint.doneMs > 0, fits(s) {
            // A failed save keeps the checkpoint before it.
            _ = save(&s, complete: complete)
        }
        end(.stopped(request), &s)
    }

    private func end(_ ending: Ending, _ s: inout State) {
        s.ended = ending
        if let task = s.task { task.cancel() } else { s.cancelPending = true }
    }

    private func fits(_ s: State) -> Bool {
        TranscriptBudget.fits(s.checkpoint.segments, language: s.checkpoint.language, maxBytes: limits.maxBodyBytes)
    }

    /// Writes the checkpoint; `checkpointed` follows only once it is on disk.
    private func save(_ s: inout State, complete: Bool) -> Bool {
        let now = uptimeMs()
        var checkpoint = s.checkpoint
        checkpoint.elapsedMs = base.elapsedMs + (now - startedAt)
        checkpoint.inferenceMs = base.inferenceMs + (now - startedAt)
        checkpoint.wordsComplete = complete
        do { try checkpoints.save(checkpoint, for: noteID) } catch { return false }
        s.checkpoint = checkpoint
        s.savedMs = checkpoint.doneMs
        s.savedAt = now
        events(.checkpointed(doneMs: checkpoint.doneMs))
        return true
    }

    /// The words so far, at most every `minimumEmitIntervalMs` (longer for long drafts) unless `force`.
    private func emit(_ s: inout State, force: Bool) {
        let now = uptimeMs()
        let interval = max(Self.minimumEmitIntervalMs, Int64(s.words.count / Self.wordsPerEmitMs))
        guard force || s.emittedAt.map({ now - $0 >= interval }) ?? true else { return }
        s.emittedAt = now
        if s.progressMs > s.shownMs || !s.wordsShown {
            // The headline shows the audio transcribed since the last update.
            events(.stageChanged(.words, startMs: s.shownMs, endMs: s.progressMs))
            s.shownMs = s.progressMs
            s.wordsShown = true
        }
        events(.windowDone(doneMs: s.progressMs, totalMs: s.checkpoint.totalMs, words: s.words))
        if !s.volatile.isEmpty {
            events(.draft(words: s.words + s.volatile, tentativeFromMs: s.checkpoint.doneMs - ProgressTracker.settleMs))
        }
    }
}
