import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The transcription queue: one job at a time, in order, each run by a `TranscriptionJobRunning`. The queue lives in
/// memory; a stopped job keeps its checkpoint, so transcribing the note again resumes it.
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
        progress.onPublish = { [weak self] in self?.showProgress() }
    }

    func speakerModelsReady() async -> Bool { await analyzer.modelStatus() == .ready }

    func beginFinalizing(_ id: UUID) { finalizing.insert(id) }
    func endFinalizing(_ id: UUID) { finalizing.remove(id) }

    func enqueue(_ id: UUID, speakersOnly onlySpeakers: Bool = false) {
        guard let note = library.note(id), note.trashedAt == nil, !note.isRecording, note.audio.isPlayable,
              !state.isRunning(id), !finalizing.contains(id), !state.isQueued(id), library.audioURL(note) != nil else { return }
        let language = settings.speechLanguage
        guard library.update(id, { note in
            note.status = .queued; note.failure = nil
            if !onlySpeakers { note.language = language }
        }) else { return }
        if onlySpeakers { speakersOnly.insert(id) }
        state.queue.append(id)
        processNext()
    }

    /// Takes the note out of the queue or cancels its job and drops its progress; its earlier transcript stays.
    func cancel(_ id: UUID, failure: JobFailure? = nil) {
        state.queue.removeAll { $0 == id }
        speakersOnly.remove(id)
        if state.isRunning(id) { stop?.stop(.cancel) } else { try? checkpoints.discard(id) }
        resetStatus(id, failure: failure)
    }

    /// Stop and keep progress: the running job keeps what it has transcribed, and transcribing the note again resumes.
    func stop(_ id: UUID) {
        guard state.isRunning(id) else { cancel(id); return }
        stop?.stop(.pause(.user))
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

    /// The running row follows the progress card.
    private func showProgress() {
        guard let id = state.running?.noteID, progress.noteID == id else { return }
        let phase = progress.processingPhase, fraction = progress.fraction
        if state.running?.phase != phase { state.running?.phase = phase }
        if state.running?.fraction != fraction { state.running?.fraction = fraction }
    }

    private func finish(_ id: UUID, _ outcome: JobOutcome) {
        switch outcome {
        case .done, .adoptPending:
            library.update(id) { $0.status = .ready; $0.failure = nil }
        case .paused(let reason):
            resetStatus(id, failure: reason == .user ? nil : .interrupted)
        case .failed(let failure):
            library.update(id) { $0.status = .failed; $0.failure = failure }
        case .downloadFailed(let failure):
            library.update(id) { $0.status = .failed; $0.failure = .download(failure.error) }
        case .needsConsent:
            resetStatus(id, failure: nil)
            notices.post(String(localized: "A speech model is needed. Allow model downloads in Settings, then try again. Audio stays on this device.",
                                table: "Processing"))
        case .cancelled:
            try? checkpoints.discard(id)
        }
        if let backgroundToken { background.end(backgroundToken) }
        backgroundToken = nil
        progress.end()
        state.running = nil
        stop = nil
        task = nil
        processNext()
    }

    private func resetStatus(_ id: UUID, failure: JobFailure?) {
        library.update(id) { $0.status = $0.transcript.isEmpty ? .audioOnly : .ready; $0.failure = failure }
    }

    /// iOS takes the background time back: the running job stops now and keeps its progress, and the queue empties.
    private func suspendAll() {
        for id in state.queue { cancel(id, failure: .interrupted) }
        if let running = state.running?.noteID {
            stop?.stop(.pause(.system))
            resetStatus(running, failure: .interrupted)
        }
    }
}
