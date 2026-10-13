import Foundation
import CassiniNotebook

/// The queue around Recently Deleted: a note that goes there, comes back, or is deleted for good.
extension TranscriptionCoordinator {
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
}
