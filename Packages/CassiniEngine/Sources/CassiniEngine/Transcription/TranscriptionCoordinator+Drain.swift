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
        var fellBack = false
        await lock.run {
            fellBack = await record(current, outcome)
            if unresolvedSystemStops.contains(current.noteID), await parts.jobs.job(current.noteID)?.state != .running {
                unresolvedSystemStops.remove(current.noteID)
            }
            // The jobs first: while `active` is set, Trash reads the job from it, and after, from `state.jobs`.
            await refresh()
            active = nil
            setRunning(nil)
            parts.progress?.end()
        }
        current.finished.signal()
        // A job handed to another recognizer has not ended: its result is announced when that run ends.
        if !fellBack { await announce(current, outcome) }
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

    /// Writes the job for `outcome`; runs inside the serial section. True when the job was queued again for another
    /// recognizer instead of failing (`fallBack`).
    @discardableResult
    func record(_ current: Active, _ outcome: JobOutcome) async -> Bool {
        let id = current.noteID
        // One read: the mode does not change between the checks below.
        let cancel = current.cancel
        let sealed = outcome == .done || outcome == .adoptPending
        if cancel == .discard, !sealed {
            await discardWork(id)
            await mirror(id)
            return false
        }
        if cancel == .restore, Self.isStop(outcome) {
            if case .saved = await parts.checkpoints.status(of: id) {
                await markPaused(id, .user)
            } else {
                await write { try await $0.remove(id) }
            }
            await mirror(id)
            return false
        }
        switch outcome {
        case .done, .adoptPending:
            await write { try await $0.remove(id) }
            await mirror(id, clearingFailure: true)
            return false
        case .paused(let reason):
            await markPaused(id, reason)
        case .failed(let failure):
            if await fallBack(id, after: failure) {
                await mirror(id)
                return true
            }
            await markFailed(id, failure)
        case .downloadFailed(let download):
            await markFailed(id, .download(download.error))
        case .needsConsent:
            await write { try await $0.transition(id, now: self.parts.clock.now) { $0.state = .needsConsent; $0.pauseReason = nil; $0.failure = nil } }
        case .cancelled:
            await markPaused(id, cancel == .keep ? .user : .interrupted)
        }
        await mirror(id)
        return false
    }

    /// A run that its recognizer could not hold in memory or could not load goes back to the front of the queue for
    /// the recognizer `Parts.fallbackRecognizer` names, from the start: the first recognizer's saved progress cannot
    /// be continued by another, so it is discarded first, and a process that ends between the two steps leaves a job
    /// without progress for the first recognizer rather than progress that the second would refuse. The recording and
    /// the note's earlier transcript are not touched. False when the job fails as it is.
    func fallBack(_ id: UUID, after failure: JobFailure) async -> Bool {
        guard RecognizerFallback.applies(to: failure), let job = await parts.jobs.job(id), job.kind != .speakersOnly,
              let recognizer = await parts.fallbackRecognizer?(job, failure), recognizer != job.recognizer else { return false }
        do { try await parts.checkpoints.discard(id) } catch {
            log.error("Cannot discard the work of \(id) before another recognizer takes it: \(String(describing: error))")
            return false
        }
        let queued = await write {
            try await $0.transition(id, now: self.parts.clock.now) { job in
                job.state = .queued; job.recognizer = recognizer; job.failure = nil; job.pauseReason = nil
                job.doneMs = 0; job.totalMs = nil; job.words = 0
            }
        }
        guard (queued ?? nil)?.state == .queued else { return false }
        log.notice("A \(job.recognizer ?? "legacy", privacy: .public) run ended with \(failure.code, privacy: .public); queued again for \(recognizer, privacy: .public)")
        return true
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
