import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The transcription queue as the screens use it: a thin layer over `TranscriptionCoordinator`, which owns the
/// queue, its holds and the background time. Without a library there is no queue, and every action does nothing.
@MainActor @Observable final class ProcessingStore {
    @ObservationIgnored let coordinator: TranscriptionCoordinator?
    /// What the model download screen works with; set once the graph is built.
    @ObservationIgnored var modelDownload: (any ModelDownloadPorts)?
    /// The standalone install of the speech model (the model download screen's Download): its progress, then its
    /// failure; nil when none ran or it finished.
    private(set) var speechInstall: DownloadFact?
    @ObservationIgnored private let transcriber: any Transcribing
    @ObservationIgnored private let analyzer: any SpeakerAnalyzing
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private var installing: Task<Void, Never>?
    /// Notes whose audio is still being written; they cannot be queued yet.
    @ObservationIgnored private var finalizing: Set<UUID> = []

    init(coordinator: TranscriptionCoordinator?, transcriber: any Transcribing, analyzer: any SpeakerAnalyzing,
         clock: any AppClock) {
        self.coordinator = coordinator
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.clock = clock
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
        return await coordinator.transcribe(id, kind: kind, origin: origin)
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

    /// Installs Apple's speech model for `language` now, outside any job, with its progress and failure in
    /// `speechInstall`. A second request while one runs joins it.
    func installSpeechModel(language: String) {
        guard installing == nil else { return }
        speechInstall = DownloadFact(part: .speech, at: clock.now)
        installing = Task { [weak self, transcriber] in
            let failure: DownloadError?
            do {
                try await transcriber.installAssets(locale: Locale(identifier: language)) { fraction in
                    Task { @MainActor in self?.reportInstall(fraction) }
                }
                failure = nil
            } catch {
                failure = error is URLError ? .noConnection : .install
            }
            self?.finishInstall(failure)
        }
    }

    private func reportInstall(_ fraction: Double) {
        guard installing != nil else { return }
        speechInstall = DownloadFact(part: .speech, fraction: fraction, at: clock.now)
    }

    private func finishInstall(_ failure: DownloadError?) {
        installing = nil
        speechInstall = failure.map { DownloadFact(part: .speech, failure: $0, at: clock.now) }
    }

    /// The Cancel of the processing card: a running note stops and keeps its progress, a queued one leaves the queue.
    func cancel(_ id: UUID) {
        guard let coordinator else { return }
        if coordinator.stop(id) { return }
        Task { await coordinator.dequeue(id) }
    }

    func stopAll() { coordinator?.stopAll() }
    func continueQueue() { coordinator?.continueQueue() }

    func startOver(_ id: UUID) {
        guard let coordinator else { return }
        Task { await coordinator.startOver(id) }
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

    /// Before the note goes to Recently Deleted; returns the job the note keeps for Restore.
    func moveToTrash(_ id: UUID) -> TrashedJob? { coordinator?.moveToTrash(id) }

    func restore(_ id: UUID, trashedJob: TrashedJob?) {
        guard let coordinator else { return }
        Task { await coordinator.restore(id, trashedJob: trashedJob) }
    }

    /// Before a permanent delete: a job that still runs stops and keeps its progress, and this returns once it ended.
    func stopForDelete(_ id: UUID) async { await coordinator?.cancel(id, discard: false) }

    /// After a permanent delete: the job goes.
    func forget(_ id: UUID) async { await coordinator?.forget(id) }

    // MARK: Notices

    /// Adds what the queue knows to the facts the banners are built from.
    func contribute(to facts: inout NoticeFacts) {
        let state = state
        facts.queueHold = state.hold
        facts.waitingJobs = state.queue.count
        facts.jobRunning = state.running != nil
        facts.failedJobs = state.jobs.values.filter { $0.state == .failed }
            .reduce(into: [:]) { $0[$1.noteID] = $1.failure ?? .unknown }
        if let speechInstall { facts.download = speechInstall }
    }
}
