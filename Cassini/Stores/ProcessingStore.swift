import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The transcription queue: one job at a time, in order, each run by a `TranscriptionJobRunning`. The queue lives in
/// memory; a stopped job keeps its checkpoint, so transcribing the note again resumes it.
///
/// Saved progress (`work/`) is dropped only by `cancel` (Cancel), by a finished transcription, and by a failure no new
/// try can use (`CHECKPOINT_MISMATCH`, `LONG`); deleting the note for good removes it with the note's folder. Taking a
/// note out of the queue (Remove from queue, Stop on a queued note, moving it to Recently Deleted, iOS taking the
/// background time back) keeps it. The running job's progress is read from
/// `progress`, not from `ProcessingState.running`.
@MainActor @Observable final class ProcessingStore {
    private(set) var state = ProcessingState()

    @ObservationIgnored let progress: JobProgress
    @ObservationIgnored private let job: any TranscriptionJobRunning
    @ObservationIgnored private let checkpoints: any CheckpointStoring
    @ObservationIgnored private let analyzer: any SpeakerAnalyzing
    @ObservationIgnored private let background: any BackgroundRunner
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let notices: NoticesStore
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private var speakersOnly: Set<UUID> = []
    @ObservationIgnored private var runningKind: JobKind?
    /// Notes on their way to Recently Deleted: they cannot be queued, and a running job's pause posts no notice.
    @ObservationIgnored private var trashing: Set<UUID> = []
    /// Notes whose audio is still being written; they cannot be queued yet.
    @ObservationIgnored private var finalizing: Set<UUID> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stop: StopSignal?
    @ObservationIgnored private var backgroundToken: BackgroundToken?

    init(job: any TranscriptionJobRunning, progress: JobProgress, checkpoints: any CheckpointStoring,
         analyzer: any SpeakerAnalyzing, background: any BackgroundRunner, library: LibraryStore,
         settings: SettingsStore, notices: NoticesStore, clock: any AppClock) {
        self.job = job; self.progress = progress; self.checkpoints = checkpoints; self.analyzer = analyzer
        self.background = background; self.library = library; self.settings = settings; self.notices = notices
        self.clock = clock
    }

    func speakerModelsReady() async -> Bool { await analyzer.modelStatus() == .ready }

    func beginFinalizing(_ id: UUID) { finalizing.insert(id) }
    func endFinalizing(_ id: UUID) { finalizing.remove(id) }

    /// Queues the note. A transcription takes the speech language from Settings, unless the note has saved progress:
    /// that resumes in the language it began in, as the checkpoint must match it.
    func enqueue(_ id: UUID, speakersOnly onlySpeakers: Bool = false) {
        guard let note = library.note(id), note.trashedAt == nil, !note.isRecording, note.audio.isPlayable,
              !state.isRunning(id), !trashing.contains(id), !finalizing.contains(id), !state.isQueued(id), library.audioURL(note) != nil else { return }
        let language = onlySpeakers || checkpoints.exists(id) ? nil : settings.speechLanguage
        guard library.update(id, { note in
            note.status = .queued; note.failure = nil
            if let language { note.language = language }
        }) else { return }
        if onlySpeakers { speakersOnly.insert(id) }
        state.queue.append(id)
        processNext()
    }

    /// Whether the note has a stopped transcription to resume.
    func hasSavedProgress(_ id: UUID) -> Bool { checkpoints.exists(id) }

    /// Cancel: stops the job or takes it out of the queue and drops its saved progress; the
    /// earlier transcript stays. A speakers-only job has no progress of its own, so a paused transcription keeps its.
    func cancel(_ id: UUID) {
        if state.isRunning(id) {
            stop?.stop(.cancel)
        } else {
            let transcribes = !speakersOnly.contains(id)
            removeFromQueue(id)
            if transcribes { try? checkpoints.discard(id) }
        }
        resetStatus(id, failure: nil)
    }

    /// Remove from queue: the note leaves the queue and keeps any saved progress, to resume later.
    func dequeue(_ id: UUID) {
        guard state.isQueued(id) else { return }
        removeFromQueue(id)
        resetStatus(id, failure: nil)
    }

    /// Stop and keep progress: the running job keeps what it has transcribed, and transcribing the note again resumes.
    /// A queued note leaves the queue with its saved progress.
    func stop(_ id: UUID) {
        guard state.isRunning(id) else { dequeue(id); return }
        stop?.stop(.pause(.user))
    }

    /// Moving to Recently Deleted: the running job stops and keeps its progress, as Stop does, and a queued note leaves
    /// the queue with its saved progress, so a restored note resumes. Nothing is posted about the stop.
    ///
    /// Waits for the running job to end, then runs `moveToTrash`, as Android trashes a note only once its job has
    /// finished. Until then the note cannot be queued again, so no job runs for it once it is in Recently Deleted.
    func trash(_ id: UUID, then moveToTrash: () -> Bool) async -> Bool {
        trashing.insert(id)
        defer { trashing.remove(id) }
        if state.isRunning(id) {
            stop?.stop(.pause(.user))
            await task?.value
        } else {
            dequeue(id)
        }
        return moveToTrash()
    }

    /// Before a note is deleted for good: a job still running for it is cancelled and has ended when this returns, so
    /// nothing writes into the note's folder after it is removed (Android's purge: `cancelAndJoin`).
    func end(_ id: UUID) async {
        removeFromQueue(id)
        guard state.isRunning(id) else { return }
        stop?.stop(.cancel)
        await task?.value
    }

    /// At launch: jobs that were queued or running when Cassini closed are not resumed; their notes can be
    /// transcribed again, from their checkpoint when they have one.
    func reconcileOnStart() {
        for note in library.notes where note.status == .transcribing || note.status == .queued {
            library.update(note.id) { $0.status = $0.transcript.isEmpty ? .audioOnly : .ready; $0.failure = .interrupted }
        }
    }

    private func processNext() {
        guard task == nil, !state.queue.isEmpty else { return }
        let id = state.queue.removeFirst()
        guard let note = library.note(id), note.trashedAt == nil,
              library.update(id, { $0.status = .transcribing }) else { processNext(); return }
        state.running = RunningJob(noteID: id, title: note.title)
        let kind: JobKind = speakersOnly.remove(id) != nil ? .speakersOnly : .transcribe
        runningKind = kind
        let record = Job(noteID: id, seq: 0, kind: kind, state: .running, language: note.language.isEmpty
                         ? settings.speechLanguage : note.language, enqueuedAt: clock.now)
        let signal = StopSignal()
        stop = signal
        progress.begin(id, finalizationMs: settings.finalizationMs)
        backgroundToken = background.begin(title: "Finish transcription", progress: Progress()) { [weak self] in
            self?.suspendAll()
        }
        task = Task { [weak self, job] in
            let outcome = await Self.ordered({ [weak self] in self?.report($0, for: id) }) { events in
                await job.run(record, stop: signal, events: events)
            }
            self?.finish(id, outcome)
        }
    }

    /// Runs `body` with a callback that may be called from any thread; `apply` gets the events here, in the order
    /// they were sent, and has had every one of them when this returns.
    private static func ordered<Event: Sendable, Value: Sendable>(
        _ apply: @escaping @MainActor (Event) -> Void,
        _ body: (@escaping @Sendable (Event) -> Void) async -> Value
    ) async -> Value {
        let (stream, sink) = AsyncStream.makeStream(of: Event.self)
        let consumer = Task { @MainActor in
            for await event in stream { apply(event) }
        }
        let result = await body { sink.yield($0) }
        sink.finish()
        await consumer.value
        return result
    }

    private func report(_ event: JobEvent, for id: UUID) {
        guard state.isRunning(id) else { return }
        progress.apply(event)
    }

    private func finish(_ id: UUID, _ outcome: JobOutcome) {
        let transcribes = runningKind != .speakersOnly
        switch outcome {
        case .done, .adoptPending:
            library.update(id) { $0.status = .ready; $0.failure = nil }
        case .paused(let reason):
            resetStatus(id, failure: reason == .user ? nil : .interrupted)
            if transcribes, !trashing.contains(id) { postPaused(id, reason: reason) }
        case .failed(let failure):
            // No new try can use this checkpoint: Transcribe again starts over.
            if transcribes, failure == .checkpointMismatch || failure == .long { try? checkpoints.discard(id) }
            library.update(id) { $0.status = .failed; $0.failure = failure }
        case .downloadFailed(let failure):
            library.update(id) { $0.status = .failed; $0.failure = .download(failure.error) }
        case .needsConsent:
            resetStatus(id, failure: nil)
            notices.post(String(localized: "A speech model is needed. Allow model downloads in Settings, then try again. Audio stays on this device.",
                                table: "Processing"))
        case .cancelled:
            if transcribes { try? checkpoints.discard(id) }
        }
        if let backgroundToken { background.end(backgroundToken) }
        backgroundToken = nil
        progress.end()
        state.running = nil
        runningKind = nil
        stop = nil
        task = nil
        processNext()
    }

    private func removeFromQueue(_ id: UUID) {
        state.queue.removeAll { $0 == id }
        speakersOnly.remove(id)
    }

    private func resetStatus(_ id: UUID, failure: JobFailure?) {
        library.update(id) { $0.status = $0.transcript.isEmpty ? .audioOnly : .ready; $0.failure = failure }
    }

    /// Says where a stopped transcription stands: how far its saved progress goes, or that it found no words yet.
    private func postPaused(_ id: UUID, reason: PauseReason) {
        guard let checkpoint = try? checkpoints.load(id), checkpoint.doneMs > 0 else {
            notices.post(String(localized: "Paused before any words were found. Resume to start transcribing.",
                                table: "Processing"))
            return
        }
        let done = TimeText.clock(Double(checkpoint.doneMs) / 1000)
        let total = TimeText.clock(Double(max(checkpoint.totalMs, checkpoint.doneMs)) / 1000)
        notices.post(reason == .user
            ? String(localized: "Paused at \(done) of \(total). Pick up where you left off. The draft so far is kept.",
                     table: "Processing")
            : String(localized: "Paused at \(done) of \(total). iOS ended the time Cassini had in the background. Resume to continue where it stopped.",
                     table: "Processing"))
    }

    /// iOS takes the background time back: the running job stops now and keeps its progress, and the queued notes
    /// leave the queue with theirs.
    private func suspendAll() {
        for id in state.queue {
            removeFromQueue(id)
            resetStatus(id, failure: .interrupted)
        }
        if let running = state.running?.noteID {
            stop?.stop(.pause(.system))
            resetStatus(running, failure: .interrupted)
        }
    }
}
