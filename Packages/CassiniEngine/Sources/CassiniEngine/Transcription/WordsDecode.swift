import Foundation
import Synchronization
import CassiniNotebook

/// The words step of one run: gathers the transcriber's results, saves checkpoints, applies the limits and turns a
/// stop into a saved checkpoint. The transcriber calls `handle` in order from its own thread; the job calls `attach`,
/// `stopRequested` from its stop watch, and `finish` once the transcriber returned.
///
/// The state is behind one lock. Job events are queued under it and sent once it is released, in order, so an event
/// sink may call back into the decode (a stop, say) without deadlocking; one that does has its own events sent after
/// the ones before. A checkpoint is written under the lock, so the next result waits for the `fsync`: that keeps every
/// decision about the next checkpoint on what is on disk.
///
/// Apple Speech sends finalized segments, which are added in order; a resumed run drops the words it already has.
/// Parakeet sends a `TranscriptWindow` after each 28 s window holding every word so far and where to go on from, which
/// replaces the checkpoint's words; a checkpoint follows each window (at most every 10 s), and the words must fit the
/// word body at every window. Its inference time is the windows' decode alone, not the step's running time.
final class WordsDecode: Sendable {
    enum Ending: Sendable {
        case complete(CheckpointState)
        case stopped(StopRequest)
        case failed(JobFailure)
        case downloadFailed(DownloadFailure)
        case needsConsent
    }

    /// A transcriber that returns with the audio this much short of the total ended early: it is a read failure, not
    /// the end of the words.
    static let endToleranceMs: Int64 = 2_000

    /// Draft events go out at most this often, and less often for long drafts: each one carries every word.
    static let minimumEmitIntervalMs: Int64 = 1_000
    static let wordsPerEmitMs = 50

    private struct State: Sendable {
        var checkpoint: CheckpointState
        var savedMs: Int64
        var savedAt: Int64?
        var savedWhistleSamples: Int = 0
        var words: [DraftWord]
        var volatile: [DraftWord] = []
        /// Transcribed audio as the transcriber reports it; at least `checkpoint.doneMs`.
        var progressMs: Int64
        var shownMs: Int64
        var wordsShown = false
        var emittedAt: Int64?
        var finalizedThisRun = false
        /// Parakeet's decode time this run, from its last window or its result.
        var decodeMs: Int64 = 0
        var ended: Ending?
        var stopping = false
        var task: Task<TranscriptionResult, any Error>?
        var cancelPending = false
        /// When the analyzer first reported: the inference clock leaves the model download out.
        var analyzerStartedAt: Int64?
        var outbox: [JobEvent] = []
        var delivering = false
    }

    private let state: Mutex<State>
    private let noteID: UUID
    private let resumeDoneMs: Int64
    private let limits: TranscriptionJob.Limits
    private let checkpoints: any CheckpointStoring
    private let stop: StopSignal
    private let events: @Sendable (JobEvent) -> Void
    private let uptimeMs: @Sendable () -> Int64
    private let base: CheckpointState
    private let recognizer: SpeechRecognizer
    /// The language the word body is counted with: the one the run's words are written with.
    private let language: String

    init(base: CheckpointState, noteID: UUID, resumeDoneMs: Int64, recognizer: SpeechRecognizer = .appleSpeech,
         language: String = "", limits: TranscriptionJob.Limits, checkpoints: any CheckpointStoring, stop: StopSignal,
         events: @escaping @Sendable (JobEvent) -> Void, uptimeMs: @escaping @Sendable () -> Int64) {
        var resumed = base
        if resumeDoneMs > 0 { resumed.resumedFromMs = resumeDoneMs }
        self.base = base
        self.noteID = noteID; self.resumeDoneMs = resumeDoneMs; self.limits = limits; self.checkpoints = checkpoints
        self.recognizer = recognizer; self.language = language
        self.stop = stop; self.events = events; self.uptimeMs = uptimeMs
        state = Mutex(State(checkpoint: resumed, savedMs: base.doneMs,
                            savedWhistleSamples: base.whistle?.processedSamples ?? 0, words: base.draftWords, progressMs: base.doneMs,
                            shownMs: base.doneMs))
    }

    /// The transcriber's task, cancelled once the step ends early.
    func attach(_ task: Task<TranscriptionResult, any Error>) {
        withState { s in
            s.task = task
            if s.cancelPending { task.cancel() }
        }
    }

    func handle(_ event: TranscriptionEvent) {
        withState { s in
            guard s.ended == nil else { return }
            if case .preparingModel = event {} else if s.analyzerStartedAt == nil { s.analyzerStartedAt = uptimeMs() }
            switch event {
            case .preparingModel(let preparation):
                let progress: DownloadProgress
                switch preparation {
                case .checking:
                    progress = DownloadProgress(part: .speech, doneBytes: 0, totalBytes: 0, verifying: true)
                case .downloading(let fraction):
                    progress = fraction.map(TranscriptionJob.fractionProgress(.speech))
                        ?? DownloadProgress(part: .speech, doneBytes: 0, totalBytes: 0, verifying: false)
                }
                s.outbox.append(.downloading(progress))
            case .progress(let done, let total):
                guard accept(total: CheckpointState.ms(total), &s) else { return }
                s.progressMs = max(s.progressMs, CheckpointState.ms(done))
                emit(&s, force: false)
            case .finalized(let segment):
                finalize(segment, &s)
            case .volatile(let segment):
                s.volatile = segment.map { $0.draftWords.filter { $0.endMs > s.checkpoint.doneMs } } ?? []
                emit(&s, force: false)
            case .window(let window):
                windowDone(window, &s)
            case .whistleBatch(let batch):
                whistleDone(batch, &s)
            }
        }
    }

    /// The stop watch saw a stop.
    func stopRequested(_ request: StopRequest) {
        withState { s in
            guard s.ended == nil else { return }
            requestStop(request, &s)
        }
    }

    /// How the step ended, once the transcriber returned with `result`.
    func finish(_ result: Result<TranscriptionResult, any Error>) -> Ending {
        withState { s in
            if let ended = s.ended { return ended }
            switch result {
            case .failure(TranscriptionError.needsConsent):
                return .needsConsent
            case .failure(TranscriptionError.failed(.download(let error))):
                return .downloadFailed(DownloadFailure(error: error, part: .speech))
            case .failure(TranscriptionError.failed(.cancelled)), .failure(JobFailure.cancelled):
                if let request = stop.request { requestStop(request, &s); return s.ended ?? .stopped(request) }
                return .stopped(.cancel)
            case .failure(TranscriptionError.failed(let failure)):
                return .failed(failure)
            case .failure(let failure as JobFailure):
                // The decode rules and the Parakeet adapter throw the failure itself (`TIMINGS`, `MEMORY`, `MODEL`).
                return .failed(failure)
            case .failure(let error):
                if let request = stop.request { requestStop(request, &s); return s.ended ?? .stopped(request) }
                return error is CancellationError ? .stopped(.cancel) : .failed(.unknown)
            case .success(let transcription) where recognizer == .parakeet:
                // Every word of the recording, gated as a whole: it replaces the windows' words.
                guard accept(total: s.checkpoint.totalMs, &s) else { return s.ended ?? .failed(.long) }
                s.checkpoint.segments = transcription.segments
                s.checkpoint.recognition = nil
                if let speakers = transcription.speakers { s.checkpoint.speakers = speakers }
                s.words = s.checkpoint.draftWords
                if let inferenceMs = transcription.inferenceMs { s.decodeMs = inferenceMs }
            case .success(let transcription):
                if !s.finalizedThisRun {
                    for segment in transcription.segments { finalize(segment, &s) }
                    if let ended = s.ended { return ended }
                }
            }
            // Every bit of the audio is transcribed, unless the input ended early.
            let lastEnd = s.checkpoint.segments.last.map { CheckpointState.ms($0.end) } ?? 0
            let reached = max(s.progressMs, lastEnd)
            if s.checkpoint.totalMs > 0, reached + Self.endToleranceMs < s.checkpoint.totalMs { return .failed(.open) }
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
            if let failure = save(&s, complete: true) { return .failed(failure) }
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
            if let failure = save(&s, complete: false) { end(.failed(failure), &s); return }
        }
        emit(&s, force: false)
    }

    private func reportLanguage(_ reported: String, _ s: inout State) {
        guard let known = TranscriptLanguage.known(reported) else { return }
        let previous = s.checkpoint.reportedLanguage
        s.checkpoint.reportedLanguage = previous == nil || previous == known ? known : "mul"
    }

    private func whistleDone(_ batch: WhistleBatch, _ s: inout State) {
        guard recognizer == .whistle, accept(total: s.checkpoint.totalMs, &s) else { return }
        s.finalizedThisRun = true
        s.checkpoint.whistle = batch.checkpoint
        s.checkpoint.doneMs = batch.checkpoint.doneMs
        s.progressMs = max(s.progressMs, s.checkpoint.doneMs)
        for language in batch.languages { reportLanguage(language, &s) }
        for segment in batch.segments where !segment.text.isEmpty {
            s.checkpoint.segments.append(segment)
            s.words.append(contentsOf: segment.draftWords)
        }
        if let request = stop.request { requestStop(request, &s); return }
        // Count source progress, including silence and open segments whose words aren't final.
        if batch.checkpoint.processedSamples - s.savedWhistleSamples >= 5 * 16_000 {
            guard fits(s) else { end(.failed(.long), &s); return }
            if let failure = save(&s, complete: false) { end(.failed(failure), &s); return }
        }
        emit(&s, force: false)
    }

    /// A Parakeet window: its words replace the checkpoint's (a resumed run's include the restored ones), and the run
    /// can go on from its recognition state.
    private func windowDone(_ window: TranscriptWindow, _ s: inout State) {
        guard accept(total: s.checkpoint.totalMs, &s) else { return }
        s.finalizedThisRun = true
        s.checkpoint.segments = TranscriptSegment.segments(of: window.words)
        s.checkpoint.recognition = window.recognition
        if let speakers = window.speakers { s.checkpoint.speakers = speakers }
        s.words = s.checkpoint.draftWords
        s.decodeMs = window.inferenceMs
        let lastEnd = window.words.map(\.endMs).max() ?? 0
        s.checkpoint.doneMs = max(s.checkpoint.doneMs, window.recognition.doneMs, lastEnd)
        s.progressMs = max(s.progressMs, s.checkpoint.doneMs)
        // A stop is honoured at the window boundary.
        if let request = stop.request { requestStop(request, &s); return }
        // Android counts the words at every window, not only at a checkpoint.
        guard fits(s) else { end(.failed(.long), &s); return }
        let now = uptimeMs()
        if SpeechWindows.windowCheckpointDue(doneMs: s.checkpoint.doneMs, savedMs: s.savedMs, nowMs: now, savedAt: s.savedAt),
           let failure = save(&s, complete: false) {
            end(.failed(failure), &s)
            return
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
        s.outbox.append(.stopping)
        let advanced = if let whistle = s.checkpoint.whistle {
            whistle.processedSamples > s.savedWhistleSamples || s.checkpoint.doneMs > s.savedMs
        } else { s.checkpoint.doneMs > s.savedMs }
        let hasProgress = s.checkpoint.doneMs > 0 || s.checkpoint.whistle != nil
        if case .pause = request, (advanced || complete), hasProgress, fits(s) {
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
        TranscriptBudget.fits(s.checkpoint.segments, language: language, maxBytes: limits.maxBodyBytes)
    }

    /// Writes the checkpoint; `checkpointed` follows only once it is on disk. Nil when saved, else the failure:
    /// `SPACE` on a full volume, `SAVE` otherwise.
    private func save(_ s: inout State, complete: Bool) -> JobFailure? {
        let now = uptimeMs()
        // The analyzer's time this run: from its first report, so a model download counts in neither the provenance's
        // inference time nor the pace a resumed run starts from.
        let analyzed = s.analyzerStartedAt.map { now - $0 } ?? 0
        var checkpoint = s.checkpoint
        checkpoint.elapsedMs = base.elapsedMs + analyzed
        // Parakeet counts its windows' decode alone, as Android's `inferenceMs` does; Apple Speech its analyzer's time.
        checkpoint.inferenceMs = base.inferenceMs + (recognizer == .parakeet ? s.decodeMs : analyzed)
        checkpoint.wordsComplete = complete
        do {
            try checkpoints.save(checkpoint, for: noteID)
        } catch {
            return Self.writeFailure(error)
        }
        s.checkpoint = checkpoint
        s.savedMs = checkpoint.doneMs
        s.savedWhistleSamples = checkpoint.whistle?.processedSamples ?? 0
        s.savedAt = now
        s.outbox.append(.checkpointed(doneMs: checkpoint.doneMs))
        return nil
    }

    static func writeFailure(_ error: any Error) -> JobFailure {
        error is CheckpointSpaceError || CheckpointFiles.isOutOfSpace(error) ? .space : .save
    }

    /// The words so far, at most every `minimumEmitIntervalMs` (longer for long drafts) unless `force`.
    private func emit(_ s: inout State, force: Bool) {
        let now = uptimeMs()
        let interval = max(Self.minimumEmitIntervalMs, Int64(s.words.count / Self.wordsPerEmitMs))
        guard force || s.emittedAt.map({ now - $0 >= interval }) ?? true else { return }
        s.emittedAt = now
        if s.progressMs > s.shownMs || !s.wordsShown {
            // The headline shows the audio transcribed since the last update.
            s.outbox.append(.stageChanged(.words, startMs: s.shownMs, endMs: s.progressMs))
            s.shownMs = s.progressMs
            s.wordsShown = true
        }
        s.outbox.append(.windowDone(doneMs: s.progressMs, totalMs: s.checkpoint.totalMs, words: s.words))
        if !s.volatile.isEmpty {
            s.outbox.append(.draft(words: s.words + s.volatile,
                                   tentativeFromMs: s.checkpoint.doneMs - ProgressTracker.settleMs))
        }
    }

    // MARK: - Delivery

    /// Runs `body` under the lock, then sends the events it queued with the lock released.
    @discardableResult
    private func withState<Value: Sendable>(_ body: (inout State) -> Value) -> Value {
        let (value, delivers) = state.withLock { s -> (Value, Bool) in
            let value = body(&s)
            guard !s.delivering, !s.outbox.isEmpty else { return (value, false) }
            s.delivering = true
            return (value, true)
        }
        if delivers { deliver() }
        return value
    }

    /// Sends the queued events in order until none is left; only one caller sends at a time.
    private func deliver() {
        while true {
            let batch = state.withLock { s -> [JobEvent] in
                let batch = s.outbox
                s.outbox = []
                if batch.isEmpty { s.delivering = false }
                return batch
            }
            guard !batch.isEmpty else { return }
            batch.forEach(events)
        }
    }
}
