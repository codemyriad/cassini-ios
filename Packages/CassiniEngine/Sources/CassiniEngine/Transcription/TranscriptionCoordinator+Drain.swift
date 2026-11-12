import Foundation
import CassiniNotebook

/// The drain loop: one job at a time in queue order, in the background time it holds, and the system's Stop.
///
/// Touches: `drainTask`, `rerun`, `background`, `backgroundProgress`, `systemStopWrites`,
/// `systemStops` and `unresolvedSystemStops` (main actor); `active` and
/// the outcome writes inside `lock`'s section; the running job only through `setRunning`, the hold through `setHold`.
extension TranscriptionCoordinator {
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
    func drainLoop() async {
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

    func holdBackgroundTime(for current: Active) {
        let title = parts.backgroundTitle(current.title)
        backgroundProgress.completedUnitCount = 0
        if let background {
            parts.background.update(background, title: title)
            return
        }
        // A new progress each time: a progress joins the system's task only once.
        backgroundProgress = Progress(totalUnitCount: 100)
        background = parts.background.begin(title: title, subtitle: parts.backgroundSubtitle,
                                            progress: backgroundProgress) { [weak self] in
            // The runner ends the token right after this; an ended token never expires, so this is the drain's.
            self?.background = nil
            self?.systemStop()
        }
    }

    /// The next queued job of a live note becomes running and `active`; nil when there is none or the queue cannot be
    /// written now (the job then stays queued for the next drain).
    func claim() async -> Active? {
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

    func start(_ current: Active) {
        active = current
        setRunning(RunningJob(noteID: current.noteID, title: current.title))
        parts.progress?.begin(current.noteID, finalizationMs: settings.finalizationMs)
        let (events, sink) = AsyncStream.makeStream(of: (JobEvent, Int64?).self)
        current.events = Task { [weak self] in
            for await (event, receivedAt) in events { self?.apply(event, to: current, receivedAt: receivedAt) }
        }
        let runner = parts.runner, job = current.job, stop = current.stop, eventUptimeMs = parts.eventUptimeMs
        current.run = Task.detached {
            let outcome = await runner.run(job, stop: stop) { sink.yield(($0, eventUptimeMs?())) }
            sink.finish()
            return outcome
        }
    }

    /// Follows the job to its end, writes its outcome, clears `active` and tells the outcome. These steps run on every
    /// path, so the queue never waits on a job that ended.
    func runOne(_ current: Active) async {
        let outcome = await current.run?.value ?? .failed(.unknown)
        await current.events?.value
        var handOver: HandOver?
        await lock.run {
            handOver = await record(current, outcome)
            if unresolvedSystemStops.contains(current.noteID), await parts.jobs.job(current.noteID)?.state != .running {
                unresolvedSystemStops.remove(current.noteID)
            }
            // The jobs first: while `active` is set, Trash reads the job from it, and after, from `state.jobs`.
            await refresh()
            // A stop that came while the job was handed over (a Stop, the system's, Recently Deleted) is for this
            // job, whose run is over: the hand-over is undone, so no new run starts against it. Until `active` is
            // cleared below, with no suspension after this check, every stop still reaches `current.stop`.
            if let undone = handOver, current.stop.request != nil {
                await undo(undone)
                handOver = nil
                await mirror(current.noteID)
                await refresh()
            }
            active = nil
            setRunning(nil)
            parts.progress?.end()
        }
        current.finished.signal()
        // A job handed to another recognizer has not ended: its result is announced when that run ends.
        if handOver == nil { await announce(current, outcome) }
    }

    func apply(_ event: JobEvent, to current: Active, receivedAt: Int64? = nil) {
        guard active === current, let running = state.running else { return }
        let updated = running.applying(event)
        setRunning(updated)
        parts.progress?.apply(event, receivedAt: receivedAt)
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

    /// A job queued again for another recognizer instead of failing: the job and the failure it would have had.
    struct HandOver {
        let job: Job
        let failure: JobFailure
    }

    /// Writes the job for `outcome`; runs inside the serial section. Returns the hand-over when the job was queued
    /// again for another recognizer instead of failing (`fallBack`).
    @discardableResult
    func record(_ current: Active, _ outcome: JobOutcome) async -> HandOver? {
        let id = current.noteID
        // One read: the mode does not change between the checks below.
        let cancel = current.cancel
        let sealed = outcome == .done || outcome == .adoptPending
        if cancel == .discard, !sealed {
            await discardWork(id)
            await mirror(id)
            return nil
        }
        if cancel == .restore, Self.isStop(outcome) {
            if case .saved = await parts.checkpoints.status(of: id) {
                await markPaused(id, .user)
            } else {
                await write { try await $0.remove(id) }
            }
            await mirror(id)
            return nil
        }
        switch outcome {
        case .done, .adoptPending:
            await write { try await $0.remove(id) }
            await mirror(id, clearingFailure: true)
            return nil
        case .paused(let reason):
            await markPaused(id, reason)
        case .failed(let failure):
            if let handOver = await fallBack(current, after: failure) {
                await mirror(id)
                return handOver
            }
            await markFailed(id, failure)
            await endFallback(current.job)
        case .downloadFailed(let download):
            await markFailed(id, .download(download.error))
            await endFallback(current.job)
        case .needsConsent:
            await write { try await $0.transition(id, now: self.parts.clock.now) { $0.state = .needsConsent; $0.pauseReason = nil; $0.failure = nil } }
        case .cancelled:
            await markPaused(id, cancel == .keep ? .user : .interrupted)
        }
        await mirror(id)
        return nil
    }

    /// A run that its recognizer could not hold in memory or could not load goes back to the front of the queue for
    /// the recognizer `Parts.fallbackRecognizer` names, from the start. Only a run that leaves nothing behind is handed
    /// over: another recognizer cannot continue saved progress, and discarding `work/` would take the draft's
    /// speaker names and merges with it, so a run with either fails as it is and keeps them for Try again. Nothing
    /// is deleted here. A job already asked to stop is not handed over either; a stop that comes later, while the
    /// fallback is chosen or the job is written, makes `runOne` undo the hand-over. Nil when the job fails as it is.
    func fallBack(_ current: Active, after failure: JobFailure) async -> HandOver? {
        let id = current.noteID
        guard RecognizerFallback.applies(to: failure), current.cancel == nil, current.stop.request == nil,
              let job = await parts.jobs.job(id), job.kind != .speakersOnly,
              await !parts.checkpoints.holdsDraft(id),
              let recognizer = await parts.fallbackRecognizer?(job, failure), recognizer != job.recognizer
        else { return nil }
        let queued = await write {
            try await $0.transition(id, now: self.parts.clock.now) { job in
                job.state = .queued; job.recognizer = recognizer; job.failure = nil; job.pauseReason = nil
                job.doneMs = 0; job.totalMs = nil; job.words = 0
            }
        }
        guard (queued ?? nil)?.state == .queued else { return nil }
        // The reason stays on the note, so the notice is there after the other recognizer's run and a relaunch.
        await setFallbackFailure(id, failure)
        log.notice("A \(job.recognizer ?? "legacy", privacy: .public) run ended with \(failure.code, privacy: .public); queued again for \(recognizer, privacy: .public)")
        return HandOver(job: job, failure: failure)
    }

    /// Takes a hand-over back: the job fails as its own run ended, with the recognizer and the numbers it had.
    func undo(_ handOver: HandOver) async {
        await write {
            try await $0.transition(handOver.job.noteID, now: self.parts.clock.now) { job in
                job.recognizer = handOver.job.recognizer
                job.doneMs = handOver.job.doneMs; job.totalMs = handOver.job.totalMs; job.words = handOver.job.words
                job.state = .failed; job.failure = handOver.failure; job.pauseReason = nil
            }
        }
        await setFallbackFailure(handOver.job.noteID, nil)
        log.notice("A stop came while \(handOver.job.noteID) was handed to another recognizer; the job failed as its run ended")
    }

    /// Writes why another recognizer took the note's job (`Note.fallbackFailure`), or nil when none did; no write when
    /// the note already says so.
    func setFallbackFailure(_ noteID: UUID, _ failure: JobFailure?) async {
        guard let note = await parts.notes.note(noteID), note.fallbackFailure != failure else { return }
        do { try await parts.notes.mutate(noteID) { $0.fallbackFailure = failure } } catch {
            log.error("Cannot save why another recognizer took \(noteID): \(String(describing: error))")
        }
    }

    /// A transcription of the note failed, or a new one begins: no transcript of a hand-over will follow, or the
    /// next one is not its. A speakers-only job changes no words, so the note keeps what it says.
    func endFallback(_ job: Job) async {
        if job.kind != .speakersOnly { await setFallbackFailure(job.noteID, nil) }
    }

    static func isStop(_ outcome: JobOutcome) -> Bool {
        switch outcome {
        case .paused, .cancelled: true
        default: false
        }
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
        systemStops += 1
        guard let current else { return nil }
        // Registered before anything can run: an activation that sees the hold also sees that its pause is pending.
        let id = UUID()
        let write = Task {
            await lock.run {
                // Only while it still runs: an outcome written meanwhile stays.
                if active === current, await parts.jobs.job(current.noteID)?.state == .running {
                    await markPaused(current.noteID, .system)
                    await mirror(current.noteID)
                    await refresh()
                }
                // Still stored as running, by this run or by one whose outcome could not be stored: the stop is not
                // resolved until an outcome is. A new run of the same note is running for its own reasons.
                if active === current || active?.noteID != current.noteID,
                   await parts.jobs.job(current.noteID)?.state == .running {
                    unresolvedSystemStops.insert(current.noteID)
                }
                systemStopWrites[id] = nil
            }
        }
        systemStopWrites[id] = write
        return Task {
            await write.value
            await notifyHidden(current.noteID, current.title, .pausedBySystem)
        }
    }
}
