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
    /// Told when a transcription stopped and kept what it saved, once its outcome is written: the paused notice. Not
    /// told for a note going to Recently Deleted, nor for a speakers-only job, which keeps nothing of its own.
    @ObservationIgnored public var onPause: (@MainActor (_ noteID: UUID, _ reason: PauseReason) -> Void)?

    @ObservationIgnored private let parts: Parts
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let lock = SerialLock()
    @ObservationIgnored private let readiness = OneShot()
    @ObservationIgnored private var active: Active?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var visible = false
    /// The background time of the drain loop, held from its first claim until the queue is empty or held; nil once
    /// iOS took it back.
    @ObservationIgnored private var background: BackgroundToken?
    /// The progress the system shows while the drain runs; each job reports into it from 0.
    @ObservationIgnored private var backgroundProgress = Progress(totalUnitCount: 100)
    /// Notes in Recently Deleted (read at launch, then kept in step by Trash and Restore). Their jobs never start or
    /// count as waiting, even before the note write lands.
    @ObservationIgnored private var trashed: Set<UUID> = []
    @ObservationIgnored private let log = Logger(subsystem: "app.codemyriad.cassini", category: "queue")

    /// How an interrupted job ends: `discard` (Start over) drops its work, `keep` pauses it with its progress, and
    /// `restore` (Cancel of a download) puts the note back to its state from before.
    private enum CancelMode { case discard, keep, restore }

    /// The job that runs now.
    private final class Active {
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

    /// After a recording or an import is saved, with Transcribe automatically on: the note is queued when the models
    /// may be used, the model download screen should ask when the person has not declined it, and otherwise the note
    /// stays audio only. Audio longer than one transcription takes stays audio only too. The automatic request never
    /// clears a hold.
    public func handOff(_ noteID: UUID) async -> HandOff {
        await readiness.wait()
        guard let note = await parts.notes.note(noteID), note.duration <= Limits.maxTranscribeDuration else {
            return .audioOnly
        }
        let language = EnqueueRules.language(for: .transcribe, speechLanguage: settings.speechLanguage) ?? note.language
        guard await parts.consent.allows(.transcribe, language) else {
            return settings.modelsDeclinedAt == nil ? .askConsent : .audioOnly
        }
        if case .queued = await transcribe(noteID, origin: .automatic) { return .queued }
        return .audioOnly
    }

    /// "Stop and keep progress" on the note that runs now. False when it does not run.
    @discardableResult
    public func stop(_ noteID: UUID) -> Bool {
        guard let current = active, current.noteID == noteID else { return false }
        current.stop.stop(.pause(.user))
        return true
    }

    /// The download notice's Cancel while the running job downloads a model (its phase is downloading, whatever its
    /// progress): the job stops, the files fetched so far stay, and the note goes back to its state from before:
    /// paused by the user with its saved progress, else without a job ("Audio only" for a first Transcribe). False
    /// when no job downloads; the standalone install is then the one to cancel.
    @discardableResult
    public func cancelDownload() -> Bool {
        guard let current = active, case .downloading = state.running?.phase else { return false }
        // A Start over at the same moment keeps its discard.
        if current.cancel == nil { current.cancel = .restore }
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

    /// Before a note goes to Recently Deleted: a running job stops and keeps its progress, a queued job leaves the
    /// queue (its `work/` stays for Restore), any other job stays. Returns what the note should remember for Restore.
    public func moveToTrash(_ noteID: UUID) -> TrashedJob? {
        trashed.insert(noteID)
        state.queue.removeAll { $0 == noteID }
        if let current = active, current.noteID == noteID {
            current.stop.stop(.pause(.user))
            return TrashedJob(state: .paused, kind: current.job.kind)
        }
        guard let job = state.jobs[noteID] else { return nil }
        if job.state == .queued {
            Task {
                await lock.run {
                    // An Undo that ran first queued the note again: that job stays.
                    if trashed.contains(noteID), await parts.jobs.job(noteID)?.state == .queued {
                        await write { try await $0.remove(noteID) }
                    }
                    await refresh()
                }
            }
        }
        return TrashedJob(state: job.state, kind: job.kind)
    }

    /// Undo and Restore: a job that was queued when the note was trashed is queued again at the back, and the queue
    /// starts as after a Transcribe.
    public func restore(_ noteID: UUID, trashedJob: TrashedJob?) async {
        trashed.remove(noteID)
        await readiness.wait()
        guard let trashedJob, trashedJob.state == .queued, let note = await parts.notes.note(noteID) else {
            await refresh()
            return
        }
        let requeued = await lock.run {
            let checkpoint = await parts.checkpoints.status(of: noteID)
            let job = await write {
                try await $0.requeueAtBack(noteID, kind: trashedJob.kind, language: note.language,
                                           checkpoint: checkpoint, now: parts.clock.now)
            }
            await mirror(noteID)
            await refresh()
            return job != nil
        }
        if requeued, await parts.consent.allows(trashedJob.kind, note.language), settings.queueHold == nil { drain() }
    }

    /// The first step of a permanent delete: stops the job if it runs, then removes it.
    public func forget(_ noteID: UUID) async {
        await cancel(noteID, discard: false)
        await lock.run {
            await write { try await $0.remove(noteID) }
            await refresh()
        }
        trashed.remove(noteID)
    }

    /// iOS takes the background time back, or the person pressed Stop in the system's progress: the running job
    /// learns of it and the `system` hold is stored before this returns, and its job shows as paused by the system at
    /// once. The returned steps (the job stored as paused by the system and, while Cassini is hidden, the notification
    /// that tells it) may not run before iOS suspends or kills Cassini; the launch repair then reads the stored hold
    /// and pauses the job by the system itself.
    @discardableResult
    public func systemStop() -> Task<Void, Never>? {
        let current = active
        current?.stop.stop(.pause(.system))
        setHold(.system)
        guard let current else { return nil }
        return Task {
            await lock.run {
                // Only while it still runs: an outcome written meanwhile stays.
                if active === current, await parts.jobs.job(current.noteID)?.state == .running {
                    await markPaused(current.noteID, .system)
                    await mirror(current.noteID)
                    await refresh()
                }
            }
            await notifyHidden(current.noteID, current.title, .pausedBySystem)
        }
    }

    /// The app came to the screen or left it. On the screen, a waiting queue starts when nothing runs, nothing holds
    /// it and the models may be used; paused jobs never resume on their own.
    public func setVisible(_ isVisible: Bool) {
        visible = isVisible
        guard isVisible else { return }
        Task { await startWaitingQueue() }
    }

    // MARK: Launch

    /// Repairs the queue after Cassini closed: reads `jobs.json`, applies `Reconcile`, deletes `work/` that no job
    /// owns, brings each note's status in line, and then lets the queue be read. `activeNoteID` is the note being
    /// recorded, which is left alone.
    ///
    /// A `jobs.json` that cannot be read is never overwritten (see `JobStore.load`): the queue opens empty, or takes no
    /// writes when the file is kept, no `work/` is deleted, notes that say they were queued are set back, and the
    /// failure is thrown once the queue is open.
    @discardableResult
    public func reconcileOnStart(activeNoteID: UUID? = nil) async throws -> ReconcileReport {
        defer { markReady() }
        let jobs: [Job]
        do {
            jobs = try await parts.jobs.load(now: parts.clock.now)
        } catch {
            log.error("Cannot read the queue: \(String(describing: error))")
            loadFailure = error as? JobStore.Failure ?? .readOnly
            jobs = []
        }
        let notes = await parts.notes.all()
        trashed = Set(notes.filter { $0.trashedAt != nil }.map(\.id))
        let work = await parts.checkpoints.notesWithWork()
        var checkpoints: [UUID: CheckpointStatus] = [:]
        for id in Set(jobs.map(\.noteID)).union(work) { checkpoints[id] = await parts.checkpoints.status(of: id) }
        let plan = Reconcile.plan(
            jobs: jobs, checkpoints: checkpoints, work: work, trashed: trashed, existing: Set(notes.map(\.id)),
            activeNoteID: activeNoteID, hold: settings.queueHold, now: parts.clock.now)
        do { try await parts.jobs.replace(plan.jobs, removing: plan.removeJobs) } catch {
            // The repair goes on in memory, so no job stays running without a run; the next write saves it.
            log.error("Cannot save the repaired queue: \(String(describing: error))")
            await parts.jobs.assume(plan.jobs, removing: plan.removeJobs)
        }
        // Without the stored queue every `work/` would look orphaned: none is deleted.
        for id in plan.deleteWork where loadFailure == nil {
            do { try await parts.checkpoints.discard(id) } catch { log.error("Cannot delete the work of \(id): \(String(describing: error))") }
        }
        let stored = Dictionary(uniqueKeysWithValues: await parts.jobs.all().map { ($0.noteID, $0) })
        for note in notes where note.id != activeNoteID
            && (stored[note.id] != nil || note.status == .queued || note.status == .transcribing) {
            await mirror(note.id, stored[note.id], closedDuringJob: stored[note.id] == nil)
        }
        await refresh()
        for id in plan.report.interrupted {
            if let note = await parts.notes.note(id) { await notifyHidden(id, note.title, .transcriptionStopped) }
        }
        // Killed before the system pause was told: tell it now, when Cassini comes back hidden.
        for id in plan.report.pausedBySystem {
            if let note = await parts.notes.note(id) { await notifyHidden(id, note.title, .pausedBySystem) }
        }
        if let loadFailure { throw loadFailure }
        return plan.report
    }

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        readiness.signal()
        if visible { Task { await startWaitingQueue() } }
    }

    private func startWaitingQueue() async {
        await readiness.wait()
        guard visible, active == nil, drainTask == nil, settings.queueHold == nil,
              let head = await parts.jobs.all().first(where: { $0.state == .queued && !trashed.contains($0.noteID) }),
              await parts.consent.allows(head.kind, head.language) else { return }
        drain()
    }

    // MARK: The drain loop

    /// Starts the drain loop, or makes the running one look at the queue again before it ends.
    public func drain() {
        guard isReady else { return }
        if drainTask != nil { rerun = true; return }
        drainTask = Task { await drainLoop() }
    }

    /// Waits until no drain loop runs.
    public func awaitIdle() async {
        while let task = drainTask { await task.value }
    }

    /// Claims and runs queued jobs one at a time until the queue is empty or held. One background time covers the
    /// whole loop: it begins with the first claim, while Cassini is on the screen, and each next job only gives it its
    /// title, so iOS keeps the queue going after Cassini leaves the screen. A job starts only once its background time
    /// is held and has its title.
    private func drainLoop() async {
        repeat {
            rerun = false
            while settings.queueHold == nil, let next = await lock.run({ await claim() }) {
                await runOne(next)
            }
        } while rerun
        if let background { parts.background.end(background) }
        background = nil
        drainTask = nil
    }

    private func holdBackgroundTime(for current: Active) {
        let title = parts.backgroundTitle(current.title)
        backgroundProgress.completedUnitCount = 0
        if let background {
            parts.background.update(background, title: title)
            return
        }
        // A new progress each time: a progress joins the system's task only once.
        backgroundProgress = Progress(totalUnitCount: 100)
        background = parts.background.begin(title: title, progress: backgroundProgress) { [weak self] in
            // The runner ends the token right after this; an ended token never expires, so this is the drain's.
            self?.background = nil
            self?.systemStop()
        }
    }

    /// The next queued job of a live note becomes running and `active`; nil when there is none or the queue cannot be
    /// written now (the job then stays queued for the next drain).
    private func claim() async -> Active? {
        let skipped = Set(await parts.notes.all().filter { $0.trashedAt != nil }.map(\.id)).union(trashed)
        while true {
            let claimed: Job?
            do { claimed = try await parts.jobs.claimNext(now: parts.clock.now, skipping: skipped) } catch {
                log.error("Cannot claim the next job: \(String(describing: error))")
                return nil
            }
            guard let job = claimed else { return nil }
            guard let note = await parts.notes.note(job.noteID) else {
                await write { try await $0.remove(job.noteID) }
                continue
            }
            let current = Active(job: job, title: note.title)
            holdBackgroundTime(for: current)
            start(current)
            await mirror(job.noteID)
            await refresh()
            return current
        }
    }

    private func start(_ current: Active) {
        active = current
        state.running = RunningJob(noteID: current.noteID, title: current.title)
        parts.progress?.begin(current.noteID, finalizationMs: settings.finalizationMs)
        let (events, sink) = AsyncStream.makeStream(of: JobEvent.self)
        current.events = Task { [weak self] in
            for await event in events { self?.apply(event, to: current) }
        }
        let runner = parts.runner, job = current.job, stop = current.stop
        current.run = Task.detached {
            let outcome = await runner.run(job, stop: stop) { sink.yield($0) }
            sink.finish()
            return outcome
        }
    }

    /// Follows the job to its end, writes its outcome, clears `active` and tells the outcome. These steps run on every
    /// path, so the queue never waits on a job that ended.
    private func runOne(_ current: Active) async {
        let outcome = await current.run?.value ?? .failed(.unknown)
        await current.events?.value
        await lock.run {
            await record(current, outcome)
            // The jobs first: while `active` is set, Trash reads the job from it, and after, from `state.jobs`.
            await refresh()
            active = nil
            state.running = nil
            parts.progress?.end()
        }
        current.finished.signal()
        await announce(current, outcome)
    }

    private func apply(_ event: JobEvent, to current: Active) {
        guard active === current, let running = state.running else { return }
        let updated = running.applying(event)
        if updated != running { state.running = updated }
        parts.progress?.apply(event)
        let fraction = parts.progress?.fraction(for: current.noteID) ?? updated.fraction
        backgroundProgress.completedUnitCount = Int64(((fraction ?? 0) * 100).rounded())
        if case .checkpointed(let doneMs) = event {
            Task {
                await lock.run {
                    guard active === current else { return }
                    await write { try await $0.transition(current.noteID, now: self.parts.clock.now) { $0.doneMs = doneMs } }
                    await refresh()
                }
            }
        }
    }

    /// Writes the job for `outcome`; runs inside the serial section.
    private func record(_ current: Active, _ outcome: JobOutcome) async {
        let id = current.noteID
        // One read: the mode does not change between the checks below.
        let cancel = current.cancel
        let sealed = outcome == .done || outcome == .adoptPending
        if cancel == .discard, !sealed {
            await discardWork(id)
            await mirror(id)
            return
        }
        if cancel == .restore, Self.isStop(outcome) {
            if case .saved = await parts.checkpoints.status(of: id) {
                await markPaused(id, .user)
            } else {
                await write { try await $0.remove(id) }
            }
            await mirror(id)
            return
        }
        switch outcome {
        case .done, .adoptPending:
            await write { try await $0.remove(id) }
            await mirror(id, clearingFailure: true)
            return
        case .paused(let reason):
            await markPaused(id, reason)
        case .failed(let failure):
            await markFailed(id, failure)
        case .downloadFailed(let download):
            await markFailed(id, .download(download.error))
        case .needsConsent:
            await write { try await $0.transition(id, now: self.parts.clock.now) { $0.state = .needsConsent; $0.pauseReason = nil; $0.failure = nil } }
        case .cancelled:
            await markPaused(id, cancel == .keep ? .user : .interrupted)
        }
        await mirror(id)
    }

    private static func isStop(_ outcome: JobOutcome) -> Bool {
        switch outcome {
        case .paused, .cancelled: true
        default: false
        }
    }

    /// The result notification of `outcome`, only while Cassini is not on the screen.
    private func announce(_ current: Active, _ outcome: JobOutcome) async {
        switch outcome {
        case .done, .adoptPending:
            guard let note = await parts.notes.note(current.noteID) else { return }
            await notifyHidden(note.id, note.title, .transcribed(speakers: note.speakers?.count ?? 0, duration: note.duration))
        case .failed(let failure):
            await notifyHidden(current.noteID, current.title, .failed(failure))
        case .downloadFailed(let download):
            await notifyHidden(current.noteID, current.title, .failed(.download(download.error)))
        case .needsConsent:
            await notifyHidden(current.noteID, current.title, .readyToTranscribe)
        case .paused(let reason):
            // A cancelled download that left no job says nothing: the note is back to its state from before.
            let kept = current.cancel != .restore || state.jobs[current.noteID]?.state == .paused
            if current.job.kind != .speakersOnly, !trashed.contains(current.noteID), kept { onPause?(current.noteID, reason) }
        case .cancelled:
            break
        }
    }

    // MARK: Helpers

    /// The language a job is queued with, and whether the note takes it too (only for the transcribe kinds).
    private struct Language {
        var job: String
        var setsNote: Bool
        var forNote: String? { setsNote ? job : nil }
    }

    /// The Settings language for the transcribe kinds, except that saved progress resumes in the language it began
    /// in (its job's, else the note's), which its checkpoint must match; a speakers-only job keeps the note's.
    private func language(for noteID: UUID, kind: JobKind, note: Note) async -> Language {
        guard let spoken = EnqueueRules.language(for: kind, speechLanguage: settings.speechLanguage) else {
            return Language(job: note.language, setsNote: false)
        }
        if case .saved = await parts.checkpoints.status(of: noteID) {
            let jobLanguage = await parts.jobs.job(noteID)?.language ?? ""
            let began = jobLanguage.isEmpty ? note.language : jobLanguage
            if !began.isEmpty { return Language(job: began, setsNote: false) }
        }
        return Language(job: spoken, setsNote: true)
    }

    private func enqueue(_ noteID: UUID, kind: JobKind, language: Language) async -> TranscribeOutcome {
        let existing = await parts.jobs.job(noteID)
        if let existing, existing.state == .queued || existing.state == .running { return .queued(changed: false) }
        guard await write({ try await $0.enqueue(noteID, kind: kind, language: language.job, now: self.parts.clock.now) }) != nil else {
            return .queued(changed: false)
        }
        trashed.remove(noteID)
        await mirror(noteID, language: language.forNote)
        await refresh()
        return .queued(changed: true)
    }

    private func needConsent(_ noteID: UUID, kind: JobKind, language: Language) async -> TranscribeOutcome {
        let now = parts.clock.now
        switch await parts.jobs.job(noteID)?.state {
        case .running:
            return .queued(changed: false)
        case .queued:
            await write { try await $0.transition(noteID, now: now) { $0.state = .needsConsent } }
        default:
            await write { try await $0.enqueue(noteID, kind: kind, language: language.job, now: now, waitingForConsent: true) }
        }
        await mirror(noteID, language: language.forNote)
        await refresh()
        return .needsConsent
    }

    /// Paused for `reason` with the numbers of the saved progress (none without it).
    private func markPaused(_ noteID: UUID, _ reason: PauseReason) async {
        let checkpoint = await parts.checkpoints.status(of: noteID)
        await write {
            try await $0.transition(noteID, now: self.parts.clock.now) { job in
                let total = job.totalMs
                job = job.withNumbers(of: checkpoint)
                if case .saved = checkpoint {} else { job.totalMs = total }
                job.state = .paused
                job.pauseReason = reason
                job.failure = nil
            }
        }
    }

    private func markFailed(_ noteID: UUID, _ failure: JobFailure) async {
        await write {
            try await $0.transition(noteID, now: self.parts.clock.now) { $0.state = .failed; $0.failure = failure; $0.pauseReason = nil }
        }
    }

    /// Start over and a trashed note's end: the `work/` directory, then the job.
    private func discardWork(_ noteID: UUID) async {
        do { try await parts.checkpoints.discard(noteID) } catch { log.error("Cannot discard the work of \(noteID): \(String(describing: error))") }
        await write { try await $0.remove(noteID) }
    }

    /// Brings the note's stored status in line with its job. `language` is set on the note for the transcribe kinds;
    /// `closedDuringJob` marks a note that says it was transcribing although no job remains (an older version's queue).
    private func mirror(_ noteID: UUID, _ known: Job?? = nil, language: String? = nil, clearingFailure: Bool = false,
                        closedDuringJob: Bool = false) async {
        let job: Job? = if let known { known } else { await parts.jobs.job(noteID) }
        do {
            try await parts.notes.mutate(noteID) { note in
                let wasWorking = note.status == .queued || note.status == .transcribing
                note.status = .mirroring(job, hasTranscript: !note.transcript.isEmpty)
                if let language { note.language = language }
                switch job?.state {
                case .failed: note.failure = job?.failure
                case .queued, .running: note.failure = nil
                case .paused, .needsConsent, nil: if clearingFailure { note.failure = nil }
                }
                if closedDuringJob, wasWorking { note.failure = .interrupted }
            }
        } catch {
            log.error("Cannot save the status of \(noteID): \(String(describing: error))")
        }
    }

    private func refresh() async {
        let all = await parts.jobs.all()
        var next = state
        next.jobs = Dictionary(uniqueKeysWithValues: all.map { ($0.noteID, $0) })
        next.queue = all.filter { $0.state == .queued && !trashed.contains($0.noteID) }.map(\.noteID)
        next.hold = settings.queueHold
        if next != state { state = next }
    }

    private func setHold(_ hold: QueueHold?) {
        settings.queueHold = hold
        state.hold = hold
    }

    /// Runs a queue write; a failed one is logged and leaves the queue as it was. Returns the result, nil on failure.
    @discardableResult
    private func write<T>(_ body: (JobStore) async throws -> T) async -> T? {
        do { return try await body(parts.jobs) } catch {
            log.error("Cannot write the queue: \(String(describing: error))")
            return nil
        }
    }

    private func notifyHidden(_ noteID: UUID, _ title: String, _ kind: ResultNotification.Kind) async {
        guard !visible else { return }
        await parts.notifier.post(ResultNotification(noteID: noteID, title: title, kind: kind))
    }
}
