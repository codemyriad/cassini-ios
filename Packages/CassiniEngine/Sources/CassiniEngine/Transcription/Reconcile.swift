import Foundation
import CassiniNotebook

/// What the launch repair did; every list holds note ids in a stable order.
public struct ReconcileReport: Hashable, Sendable {
    /// A running job became queued again at its place.
    public var requeued: [UUID] = []
    /// A running job passed its automatic attempts and waits for Resume.
    public var interrupted: [UUID] = []
    /// A running job under the `system` hold: iOS took the time back and Cassini was killed before the pause was
    /// written. It is paused by the system, as it would have been.
    public var pausedBySystem: [UUID] = []
    /// A paused job without saved progress starts again from the beginning.
    public var restarted: [UUID] = []
    /// Saved progress no longer matches: the job failed with `CHECKPOINT_MISMATCH`.
    public var mismatched: [UUID] = []
    /// A `work/` directory that no job owns was deleted.
    public var deletedWork: [UUID] = []
    /// The job of a note in Recently Deleted left the queue (queued) or was paused (running), as Trash would have
    /// done had Cassini not closed first; its `work/` stays for Restore.
    public var trashed: [UUID] = []

    public init() {}

    public var isEmpty: Bool { self == ReconcileReport() }
}

/// The launch repair of the queue, as a pure function: the jobs Cassini closed with, what each note's `work/` holds,
/// and the notes, give the jobs to write and the `work/` directories to delete. Running it again on its own result
/// changes nothing.
public enum Reconcile {
    /// Automatic restarts after Cassini closed during a job, before it waits for Resume. It also stops a job that
    /// crashes before its first checkpoint from restarting forever.
    public static let maxAutomaticAttempts = 2

    public struct Plan: Hashable, Sendable {
        /// Changed jobs, each with its `seq` kept.
        public var jobs: [Job] = []
        /// Jobs to remove, in the same write as `jobs`.
        public var removeJobs: [UUID] = []
        public var deleteWork: [UUID] = []
        public var report = ReconcileReport()
        public init() {}
    }

    /// - Parameters:
    ///   - jobs: the stored queue.
    ///   - checkpoints: what each note with a job or a `work/` directory has saved.
    ///   - work: notes that have a `work/` directory.
    ///   - trashed: notes in Recently Deleted. Trash deletes the row of a queued job and pauses a running one; its
    ///     `work/` stays for Restore. A job Cassini closed before Trash had finished with is ended the same way here.
    ///   - existing: every note Cassini read; a `work/` directory of a note it could not read is left alone.
    ///   - activeNoteID: the note being recorded now, which is never touched.
    ///   - hold: the stored queue hold. Under `system` no job is claimed, so a job still running was the one iOS
    ///     stopped; it is paused by the system instead of being counted as a crash.
    public static func plan(jobs: [Job], checkpoints: [UUID: CheckpointStatus], work: Set<UUID>, trashed: Set<UUID>,
                            existing: Set<UUID>, activeNoteID: UUID?, hold: QueueHold? = nil, now: Date) -> Plan {
        var plan = Plan()
        let owned = Set(jobs.map(\.noteID))
        for job in jobs.sorted(by: { $0.seq < $1.seq }) where job.noteID != activeNoteID {
            let checkpoint = checkpoints[job.noteID] ?? .missing
            if trashed.contains(job.noteID), job.state == .queued || job.state == .running {
                inTrash(job, checkpoint, now, &plan)
                continue
            }
            switch job.state {
            case .running: running(job, checkpoint, hold, now, &plan)
            case .paused: paused(job, checkpoint, now, &plan)
            case .queued, .failed, .needsConsent: break
            }
        }
        let orphans = work.subtracting(owned).subtracting(trashed).intersection(existing)
        plan.deleteWork = orphans.filter { $0 != activeNoteID }.sorted { $0.uuidString < $1.uuidString }
        plan.report.deletedWork = plan.deleteWork
        return plan
    }

    /// The jobs to write after a `jobs.json` that could not be read was moved aside and the queue started empty: each
    /// note with saved progress (`checkpoints` holds `.saved`) that exists, is not in Recently Deleted and is not being
    /// recorded gets a job paused by the user with its checkpoint's numbers, in note-id order, so its `work/` is owned
    /// and kept at the next launch, and Resume goes on from it (as Android's catalogue rebuild turns such work into a
    /// paused job). The job's language is empty: a Resume and the run take the checkpoint's.
    public static func rebuilt(work: Set<UUID>, checkpoints: [UUID: CheckpointStatus], trashed: Set<UUID>,
                               existing: Set<UUID>, activeNoteID: UUID?, now: Date, recognizers: [UUID: String] = [:]) -> [Job] {
        let resumable = work.intersection(existing).subtracting(trashed).filter { id in
            guard id != activeNoteID, case .saved? = checkpoints[id] else { return false }
            return true
        }
        return resumable.sorted { $0.uuidString < $1.uuidString }.enumerated().map { index, id in
            Job(noteID: id, seq: index + 1, kind: .transcribe, state: .paused, pauseReason: .user, enqueuedAt: now, recognizer: recognizers[id])
                .withNumbers(of: checkpoints[id] ?? .missing)
        }
    }

    private static func running(_ job: Job, _ checkpoint: CheckpointStatus, _ hold: QueueHold?, _ now: Date,
                                _ plan: inout Plan) {
        var changed = job
        changed.updatedAt = now
        if checkpoint == .mismatch {
            plan.jobs.append(mismatch(changed))
            plan.report.mismatched.append(job.noteID)
            return
        }
        if hold == .system {
            // Not a crash: the attempts stay as they were.
            changed.state = .paused
            changed.pauseReason = .system
            plan.jobs.append(changed.withNumbers(of: checkpoint))
            plan.report.pausedBySystem.append(job.noteID)
            return
        }
        changed.attempts = job.attempts + 1
        if changed.attempts > maxAutomaticAttempts {
            changed.state = .paused
            changed.pauseReason = .interrupted
            plan.report.interrupted.append(job.noteID)
        } else {
            changed.state = .queued
            plan.report.requeued.append(job.noteID)
        }
        plan.jobs.append(changed.withNumbers(of: checkpoint))
    }

    private static func inTrash(_ job: Job, _ checkpoint: CheckpointStatus, _ now: Date, _ plan: inout Plan) {
        plan.report.trashed.append(job.noteID)
        guard job.state == .running else {
            plan.removeJobs.append(job.noteID)
            return
        }
        var changed = job.withNumbers(of: checkpoint)
        changed.state = .paused
        changed.pauseReason = .user
        changed.updatedAt = now
        plan.jobs.append(changed)
    }

    private static func paused(_ job: Job, _ checkpoint: CheckpointStatus, _ now: Date, _ plan: inout Plan) {
        switch checkpoint {
        case .mismatch:
            var changed = mismatch(job)
            changed.updatedAt = now
            plan.jobs.append(changed)
            plan.report.mismatched.append(job.noteID)
        case .missing where job.doneMs != 0 || job.words != 0:
            var changed = job.withNumbers(of: .missing)
            changed.updatedAt = now
            plan.jobs.append(changed)
            plan.report.restarted.append(job.noteID)
        case .missing, .saved:
            break
        }
    }

    private static func mismatch(_ job: Job) -> Job {
        var job = job
        job.state = .failed
        job.failure = .checkpointMismatch
        job.pauseReason = nil
        return job
    }
}
