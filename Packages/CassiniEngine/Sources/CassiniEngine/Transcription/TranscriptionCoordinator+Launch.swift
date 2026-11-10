import Foundation
import CassiniNotebook

/// The launch repair, and starting a waiting queue when Cassini comes to the screen.
///
/// Touches: `visible`, `trashed` (read from the notes at launch), the stored queue and `work/` before the queue is
/// ready; the observed state only through `recordLoadFailure`, `refresh` and `markReady`.
extension TranscriptionCoordinator {
    /// The app came to the screen or left it. On the screen, a waiting queue starts when nothing runs, nothing holds
    /// it and the models may be used; paused jobs never resume on their own.
    public func setVisible(_ isVisible: Bool) {
        visible = isVisible
        guard isVisible else { return }
        Task { await startWaitingQueue() }
    }

    /// Repairs the queue after Cassini closed: reads `jobs.json`, applies `Reconcile`, deletes `work/` that no job
    /// owns, brings each note's status in line, and then lets the queue be read. `activeNoteID` is the note being
    /// recorded, which is left alone.
    ///
    /// A `jobs.json` that cannot be read is never overwritten (see `JobStore.load`): the queue opens empty, or takes no
    /// writes when the file is kept, no `work/` is deleted, notes that say they were queued are set back, and the
    /// failure is thrown once the queue is open. When it was moved aside, each note's saved progress becomes a job
    /// paused by the user (`Reconcile.rebuilt`), so the next launch keeps that `work/`.
    @discardableResult
    public func reconcileOnStart(activeNoteID: UUID? = nil) async throws -> ReconcileReport {
        defer { markReady() }
        let jobs: [Job]
        do {
            jobs = try await parts.jobs.load(now: parts.clock.now)
        } catch {
            recordLoadFailure(error)
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
        // A queue moved aside starts empty but takes writes: the saved progress becomes paused jobs again.
        var rebuilt: [Job] = []
        if case .unreadable(movedTo: _?)? = loadFailure {
            var recognizers: [UUID: String] = [:]
            for id in work { recognizers[id] = await parts.checkpoints.recognizer(of: id) }
            rebuilt = Reconcile.rebuilt(work: work, checkpoints: checkpoints, trashed: trashed,
                                        existing: Set(notes.map(\.id)), activeNoteID: activeNoteID, now: parts.clock.now, recognizers: recognizers)
        }
        do { try await parts.jobs.replace(plan.jobs, adding: rebuilt, removing: plan.removeJobs) } catch {
            // The repair goes on in memory, so no job stays running without a run; the next write saves it.
            log.error("Cannot save the repaired queue: \(String(describing: error))")
            await parts.jobs.assume(plan.jobs, adding: rebuilt, removing: plan.removeJobs)
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

    /// Cassini came to the screen on `platform`: when `EnqueueRules.resumesOnActivation` allows it, each job the system
    /// paused (oldest first) is resumed from its checkpoint as its Resume on the screen would be, which clears the
    /// system hold; with none, the hold is cleared and the queue continues. Jobs the person paused stay paused. Returns
    /// the notes it resumed.
    @discardableResult
    public func resumeSystemPause(onActivationOf platform: PlatformFacts) async -> [UUID] {
        await readiness.wait()
        guard EnqueueRules.resumesOnActivation(settings.queueHold, platform: platform) else { return [] }
        let paused = await parts.jobs.all()
            .filter { $0.state == .paused && $0.pauseReason == .system && !trashed.contains($0.noteID) }
            .sorted { $0.seq < $1.seq }
        guard !paused.isEmpty else {
            continueQueue()
            return []
        }
        var resumed: [UUID] = []
        for job in paused {
            if case .queued = await transcribe(job.noteID, kind: job.kind, origin: .screen) { resumed.append(job.noteID) }
        }
        return resumed
    }

    func startWaitingQueue() async {
        await readiness.wait()
        guard visible, active == nil, drainTask == nil, settings.queueHold == nil,
              let head = await parts.jobs.all().first(where: { $0.state == .queued && !trashed.contains($0.noteID) }),
              await consent(for: head.noteID).allows(head.kind, head.language) else { return }
        drain()
    }
}
