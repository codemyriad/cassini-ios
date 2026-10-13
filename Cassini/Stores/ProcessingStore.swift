import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The transcription queue as the screens use it: a thin layer over `TranscriptionCoordinator`, which owns the
/// queue, its holds and the background time. Without a library there is no queue, and every action does nothing.
///
/// The running job's progress is read from `progress`, not from `ProcessingState.running`. Saved progress (`work/`)
/// is kept by Stop, Remove from queue, Recently Deleted and iOS taking the background time back, and dropped by Start
/// over, a finished transcription and a deleted note.
@MainActor @Observable final class ProcessingStore {
    @ObservationIgnored let coordinator: TranscriptionCoordinator?
    /// The running job's progress, which the coordinator keeps.
    @ObservationIgnored let progress: JobProgress
    /// What the model download screen works with; set once the graph is built.
    @ObservationIgnored var modelDownload: (any ModelDownloadPorts)?
    /// The models outside any job: their stored status and the model download screen's standalone Download.
    @ObservationIgnored let models: ModelInstalls
    @ObservationIgnored private let checkpoints: any CheckpointStoring
    @ObservationIgnored private let analyzer: any SpeakerAnalyzing
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let notices: NoticeCenter
    /// Notes whose audio is still being written; they cannot be queued yet.
    @ObservationIgnored private var finalizing: Set<UUID> = []
    /// Notes waiting for their job to end on their way to Recently Deleted; they cannot be queued meanwhile.
    @ObservationIgnored private var trashing: Set<UUID> = []

    init(coordinator: TranscriptionCoordinator?, progress: JobProgress, checkpoints: any CheckpointStoring,
         models: ModelInstalls, analyzer: any SpeakerAnalyzing, library: LibraryStore, notices: NoticeCenter) {
        self.coordinator = coordinator
        self.progress = progress
        self.checkpoints = checkpoints
        self.models = models
        self.analyzer = analyzer
        self.library = library
        self.notices = notices
    }

    var state: ProcessingState { coordinator?.state ?? ProcessingState() }

    func speakerModelsReady() async -> Bool { await analyzer.modelStatus() == .ready }

    func beginFinalizing(_ id: UUID) { finalizing.insert(id) }
    func endFinalizing(_ id: UUID) { finalizing.remove(id) }

    /// Transcribe, Transcribe again, Resume and Try again; see `TranscriptionCoordinator.transcribe`.
    @discardableResult
    func transcribe(_ id: UUID, kind: JobKind = .transcribe, origin: StartOrigin = .screen) async -> TranscribeOutcome {
        guard let coordinator else { return .refused(.noNote) }
        if finalizing.contains(id) { return .refused(.recording) }
        if trashing.contains(id) { return .refused(.trashed) }
        let outcome = await coordinator.transcribe(id, kind: kind, origin: origin)
        // The first Transcribe from the screen asks to notify the results; the queue does not wait for the answer.
        if origin == .screen { Task { [notices] in await notices.askNotificationsOnce() } }
        return outcome
    }

    /// `transcribe` without waiting for its outcome.
    func request(_ id: UUID, kind: JobKind = .transcribe, origin: StartOrigin = .automatic) {
        Task { await transcribe(id, kind: kind, origin: origin) }
    }

    /// After a recording or an import is saved with Transcribe automatically on; see
    /// `TranscriptionCoordinator.handOff`.
    func handOff(_ id: UUID) async -> HandOff {
        guard let coordinator, !finalizing.contains(id) else { return .audioOnly }
        return await coordinator.handOff(id)
    }

    /// Download again or Try again on a download failure banner: the part whose install failed installs again, the
    /// speech model when none failed.
    func retryInstall() {
        let failed = models.download.flatMap { $0.failure == nil ? nil : $0.part }
        models.install([failed ?? .speech])
    }

    /// The user closed the failure of the last install; the next install may fail again.
    func dismissInstallFailure() { models.dismissFailure() }

    /// Whether the note has a stopped transcription to resume.
    func hasSavedProgress(_ id: UUID) -> Bool { checkpoints.exists(id) }

    /// The words of the note's saved progress, for the read-only draft of a stopped or failed job; empty without any,
    /// or when it cannot be read. Read off the main actor: a long recording's checkpoint holds hours of words.
    func savedDraft(_ id: UUID) async -> [DraftWord] { await Self.draft(id, in: checkpoints) }

    @concurrent private static func draft(_ id: UUID, in checkpoints: any CheckpointStoring) async -> [DraftWord] {
        (try? checkpoints.load(id))?.draftWords ?? []
    }

    /// Stop and keep progress on the running note (also Cancel analysis); on a queued one, Remove from queue.
    func stop(_ id: UUID) {
        guard coordinator?.stop(id) != true else { return }
        dequeue(id)
    }

    /// Remove from queue: the job goes, or is paused by the user when the note has saved progress. A recording whose
    /// audio is still being written is not queued yet: it stays audio only.
    func dequeue(_ id: UUID) {
        if finalizing.contains(id) { library.update(id) { if $0.status == .queued { $0.status = .audioOnly } } }
        guard let coordinator else { return }
        Task { await coordinator.dequeue(id) }
    }

    func stopAll() { coordinator?.stopAll() }

    /// The processing card's Cancel of the running job's model download (`TranscriptionCoordinator.cancelDownload()`).
    /// The files fetched so far stay.
    func cancelJobDownload() { coordinator?.cancelDownload() }

    /// The Settings banner's Cancel of the standalone install (`ModelInstalls.cancel()`); a job that downloads at the
    /// same time goes on. The files fetched so far stay.
    func cancelStandaloneDownload() { models.cancel() }
    func continueQueue() { coordinator?.continueQueue() }

    /// Start over: the saved progress goes and the note is queued from the beginning.
    @discardableResult
    func startOver(_ id: UUID) async -> TranscribeOutcome {
        guard let coordinator else { return .refused(.noNote) }
        return await coordinator.startOver(id)
    }

    func clearFailed(_ id: UUID) {
        guard let coordinator else { return }
        Task { await coordinator.clearFailed(id) }
    }

    /// Cassini is on the screen, or no longer.
    func setVisible(_ visible: Bool) { coordinator?.setVisible(visible) }

    /// The launch repair; `activeNoteID` is the note being recorded.
    func reconcileOnStart(activeNoteID: UUID?) async throws {
        try await coordinator?.reconcileOnStart(activeNoteID: activeNoteID)
    }

    // MARK: Recently Deleted

    /// Moving to Recently Deleted: a running job stops and keeps its progress and a queued one leaves the queue (its
    /// `work/` stays for Restore); nothing is said about the stop. Once the job has ended, `move` writes the trash with
    /// the job the note keeps for Restore, as Android trashes a note only once its job has finished; until then the
    /// note cannot be queued. When `move` fails the job is restored. Returns what `move` returned.
    func trash(_ id: UUID, then move: (TrashedJob?) -> Bool) async -> Bool {
        guard let coordinator else { return move(nil) }
        trashing.insert(id)
        defer { trashing.remove(id) }
        let job = coordinator.moveToTrash(id)
        await coordinator.waitForJob(of: id)
        guard move(job) else {
            // The note stays where it was: so does its job.
            restore(id, trashedJob: job)
            return false
        }
        return true
    }

    func restore(_ id: UUID, trashedJob: TrashedJob?) {
        guard let coordinator else { return }
        Task { await coordinator.restore(id, trashedJob: trashedJob) }
    }

    /// The first step of a permanent delete: a job that still runs stops and is awaited, then the job goes.
    func forget(_ id: UUID) async { await coordinator?.forget(id) }

    // MARK: Notices

    /// Adds what the queue knows to the facts the banners are built from.
    func contribute(to facts: inout NoticeFacts) {
        let state = state
        facts.queueHold = state.hold
        facts.waitingJobs = state.queue.count
        // A job runs, or a model installs on its own.
        facts.jobRunning = state.running != nil || (models.download != nil && models.download?.failure == nil)
        facts.failedJobs = state.jobs.values.filter { $0.state == .failed }
            .reduce(into: [:]) { $0[$1.noteID] = $1.failure ?? .unknown }
        if let download = models.download { facts.download = download }
    }
}
