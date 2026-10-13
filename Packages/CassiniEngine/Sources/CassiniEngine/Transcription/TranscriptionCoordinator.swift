import Foundation
import Observation
import os
import CassiniNotebook

/// The durable transcription queue: queue actions, the drain loop that runs one job at a time in queue order, holds,
/// the launch repair and the background time jobs run in. One per app run.
///
/// - Every queue transition (claim, outcome, dequeue, trash, Start over) runs in one serial section over `JobStore`,
///   so a job's outcome and a user action never interleave.
/// - Nothing reads the queue before `reconcileOnStart` has repaired it; queue actions wait for it.
/// - `note.json` keeps the coarse `status` (and the failure of a failed job) in step with the job, for older readers.
///
/// The `TranscriptionCoordinator+*.swift` extensions split this class by topic and share its internals; each one's
/// header names the internals it touches. The observed state (`state`, `isReady`, `loadFailure`) is written only in
/// this file, through `refresh`, `setHold`, `setRunning`, `markTrashed`, `markReady` and `recordLoadFailure`.
@MainActor @Observable
public final class TranscriptionCoordinator {
    /// The coordinator's collaborators; the app passes its adapters, tests pass fakes.
    public struct Parts {
        public var jobs: JobStore
        public var notes: NoteStore
        public var runner: any TranscriptionJobRunning
        public var checkpoints: any JobCheckpoints
        public var consent: ModelConsent
        public var notifier: any Notifier
        public var background: any BackgroundRunner
        public var clock: any AppClock
        /// The title of the system's progress while a note with this title is transcribed.
        public var backgroundTitle: @MainActor (_ noteTitle: String) -> String
        /// The running job's progress that the Note screen and the Library rows read: it is told when each job
        /// begins, each of its events in order, and when it ends. The system's progress follows it when it is given.
        public var progress: JobProgress?

        public init(jobs: JobStore, notes: NoteStore, runner: any TranscriptionJobRunning,
                    checkpoints: any JobCheckpoints, consent: ModelConsent, notifier: any Notifier,
                    background: any BackgroundRunner, clock: any AppClock,
                    backgroundTitle: @escaping @MainActor (_ noteTitle: String) -> String = { "Transcribing “\($0)”" },
                    progress: JobProgress? = nil) {
            self.jobs = jobs; self.notes = notes; self.runner = runner; self.checkpoints = checkpoints
            self.consent = consent; self.notifier = notifier; self.background = background; self.clock = clock
            self.backgroundTitle = backgroundTitle; self.progress = progress
        }
    }

    public private(set) var state = ProcessingState()
    /// The launch repair has run and the queue may be read.
    public private(set) var isReady = false
    /// A drain loop runs: a job runs or is about to be claimed.
    public var isDraining: Bool { drainTask != nil }
    /// Why the stored queue could not be read at launch, for the notice that tells it; nil when it was read.
    public private(set) var loadFailure: JobStore.Failure?

    @ObservationIgnored let parts: Parts
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let lock = SerialLock()
    @ObservationIgnored let readiness = OneShot()
    @ObservationIgnored var active: Active?
    @ObservationIgnored var drainTask: Task<Void, Never>?
    @ObservationIgnored var rerun = false
    @ObservationIgnored var visible = false
    /// The background time of the drain loop, held from its first claim until the queue is empty or held; nil once
    /// iOS took it back.
    @ObservationIgnored var background: BackgroundToken?
    /// The progress the system shows while the drain runs; each job reports into it from 0.
    @ObservationIgnored var backgroundProgress = Progress(totalUnitCount: 100)
    /// Notes in Recently Deleted (read at launch, then kept in step by Trash and Restore). Their jobs never start or
    /// count as waiting, even before the note write lands.
    @ObservationIgnored var trashed: Set<UUID> = []
    /// Notes whose recorded audio is still being written (`beginFinalizing`); they cannot be queued yet.
    @ObservationIgnored var finalizing: Set<UUID> = []
    /// Notes waiting for their job to end on their way to Recently Deleted (`trash(_:then:)`); they cannot be queued
    /// meanwhile.
    @ObservationIgnored var trashing: Set<UUID> = []
    @ObservationIgnored let log = Logger(subsystem: "app.codemyriad.cassini", category: "queue")

    /// How an interrupted job ends: `discard` (Start over) drops its work, `keep` pauses it with its progress, and
    /// `restore` (Cancel of a download) puts the note back to its state from before.
    enum CancelMode { case discard, keep, restore }

    /// The job that runs now.
    final class Active {
        let job: Job
        let title: String
        let stop = StopSignal()
        let finished = OneShot()
        var cancel: CancelMode?
        var run: Task<JobOutcome, Never>?
        var events: Task<Void, Never>?

        var noteID: UUID { job.noteID }

        init(job: Job, title: String) { self.job = job; self.title = title }
    }

    public init(_ parts: Parts, settings: SettingsStore) {
        self.parts = parts
        self.settings = settings
        state.hold = settings.queueHold
    }

    // MARK: Queue actions

    /// Transcribe, Transcribe again, Resume and Try again: puts the note at the back of the queue and starts the queue
    /// when nothing holds it. Without consent the job becomes "Ready to transcribe" and nothing is downloaded.
    @discardableResult
    public func transcribe(_ noteID: UUID, kind: JobKind = .transcribe, origin: StartOrigin = .screen) async -> TranscribeOutcome {
        if let refusal = admissionRefusal(noteID) { return .refused(refusal) }
        await readiness.wait()
        // A job asked to stop may still be ending: this request waits for its outcome, so that outcome never
        // overwrites it and the note is queued again once it has ended.
        if let current = active, current.noteID == noteID {
            let stopping = current.stop.request != nil || current.cancel != nil
            let stillRunning = await parts.jobs.job(noteID)?.state == .running
            if stopping || !stillRunning { await current.finished.wait() }
        }
        guard let note = await parts.notes.note(noteID) else { return .refused(.noNote) }
        if let refusal = EnqueueRules.refusal(for: note) { return .refused(refusal) }
        guard await parts.jobs.isWritable else { return .refused(.queueUnavailable) }
        let language = await language(for: noteID, kind: kind, note: note)
        guard await parts.consent.allows(kind, language.job) else {
            return await lock.run { await needConsent(noteID, kind: kind, language: language) }
        }
        let resume = await parts.jobs.job(noteID)?.state == .paused
        if EnqueueRules.clears(settings.queueHold, origin: origin, resume: resume) { setHold(nil) }
        let outcome = await lock.run { await enqueue(noteID, kind: kind, language: language) }
        if case .queued = outcome, settings.queueHold == nil { drain() }
        return outcome
    }

    /// "Stop and keep progress" on the note that runs now. False when it does not run.
    @discardableResult
    public func stop(_ noteID: UUID) -> Bool {
        guard let current = active, current.noteID == noteID else { return false }
        current.stop.stop(.pause(.user))
        return true
    }

    /// Stop from outside the note: holds the queue, then stops the running note with its progress.
    public func stopAll() {
        setHold(.user)
        active?.stop.stop(.pause(.user))
    }

    /// Continue: clears the hold and starts the queue.
    public func continueQueue() {
        setHold(nil)
        drain()
    }

    /// "Remove from queue" on a queued note.
    @discardableResult
    public func dequeue(_ noteID: UUID) async -> DequeueOutcome {
        await leaveQueuedWhileFinalizing(noteID)
        await readiness.wait()
        return await lock.run {
            guard await parts.jobs.job(noteID)?.state == .queued else { return .notQueued }
            let outcome: DequeueOutcome
            if case .saved = await parts.checkpoints.status(of: noteID) {
                await markPaused(noteID, .user)
                outcome = .paused
            } else {
                await write { try await $0.remove(noteID) }
                outcome = .removed
            }
            await mirror(noteID)
            await refresh()
            return outcome
        }
    }

    /// Removes the failed job of a note whose failure was dismissed. A recording too long to transcribe cannot use
    /// its saved progress again, so that goes with it.
    public func clearFailed(_ noteID: UUID) async {
        await readiness.wait()
        await lock.run {
            guard let job = await parts.jobs.job(noteID), job.state == .failed else { return }
            if job.failure == .long { await discardWork(noteID) } else { await write { try await $0.remove(noteID) } }
            await mirror(noteID, clearingFailure: true)
            await refresh()
        }
    }

    /// Start over: stops the job if it runs, discards its saved progress, then queues the note again with the kind it
    /// had.
    @discardableResult
    public func startOver(_ noteID: UUID, origin: StartOrigin = .screen) async -> TranscribeOutcome {
        await readiness.wait()
        let kind = await parts.jobs.job(noteID)?.kind ?? .transcribe
        await cancel(noteID, discard: true)
        return await transcribe(noteID, kind: kind, origin: origin)
    }

    /// Interrupts the job of the note and waits until its outcome is written. With `discard` its `work/` goes and the
    /// job is removed; without, it is paused by the user with its progress. A note that does not run only loses its
    /// work with `discard`. Returns whether the note was running.
    @discardableResult
    public func cancel(_ noteID: UUID, discard: Bool) async -> Bool {
        await readiness.wait()
        let current: Active? = await lock.run {
            if let current = active, current.noteID == noteID {
                // Set inside the section: the outcome is written inside one too, so it always sees the mode.
                current.cancel = discard ? .discard : .keep
                return current
            }
            if discard {
                await discardWork(noteID)
                await mirror(noteID)
                await refresh()
            }
            return nil
        }
        guard let current else { return false }
        current.stop.stop(.cancel)
        await current.finished.wait()
        return true
    }

    /// Returns once the job running for the note, if any, has ended and its outcome is written.
    public func waitForJob(of noteID: UUID) async {
        guard let current = active, current.noteID == noteID else { return }
        await current.finished.wait()
    }

    // MARK: Observed state: its only writers

    /// Reads the stored jobs into `state`: the jobs, the queue without the trashed notes, and the hold.
    func refresh() async {
        let all = await parts.jobs.all()
        var next = state
        next.jobs = Dictionary(uniqueKeysWithValues: all.map { ($0.noteID, $0) })
        next.queue = all.filter { $0.state == .queued && !trashed.contains($0.noteID) }.map(\.noteID)
        next.hold = settings.queueHold
        if next != state { state = next }
    }

    func setHold(_ hold: QueueHold?) {
        settings.queueHold = hold
        state.hold = hold
    }

    /// The running job as the Note screen and the Library show it; nil once it ended.
    func setRunning(_ running: RunningJob?) {
        if running != state.running { state.running = running }
    }

    /// The note went to Recently Deleted: its job never starts or counts as waiting from now on.
    func markTrashed(_ noteID: UUID) {
        trashed.insert(noteID)
        state.queue.removeAll { $0 == noteID }
    }

    /// The launch repair has run: queue actions stop waiting, and a waiting queue starts when Cassini is on screen.
    func markReady() {
        guard !isReady else { return }
        isReady = true
        readiness.signal()
        if visible { Task { await startWaitingQueue() } }
    }

    func recordLoadFailure(_ error: any Error) {
        log.error("Cannot read the queue: \(String(describing: error))")
        loadFailure = error as? JobStore.Failure ?? .readOnly
    }

    // MARK: Notifications

    /// The result notification of `outcome` (`ResultNotification.announcing`), only while Cassini is not on the screen.
    func announce(_ current: Active, _ outcome: JobOutcome) async {
        guard !visible else { return }
        let sealed = outcome == .done || outcome == .adoptPending
        let note = sealed ? await parts.notes.note(current.noteID) : nil
        guard let notification = ResultNotification.announcing(outcome, noteID: current.noteID, title: current.title,
                                                               note: note) else { return }
        await parts.notifier.post(notification)
    }

    func notifyHidden(_ noteID: UUID, _ title: String, _ kind: ResultNotification.Kind) async {
        guard !visible else { return }
        await parts.notifier.post(ResultNotification(noteID: noteID, title: title, kind: kind))
    }
}
