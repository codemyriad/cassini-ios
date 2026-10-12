import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

/// The launch repair as a pure function: every row of its table.
@Suite struct ReconcileTests {
    let now = Date(timeIntervalSince1970: 1_791_452_460)
    let then = Date(timeIntervalSince1970: 1_791_000_000)

    private struct Tree {
        var jobs: [Job] = []
        var checkpoints: [UUID: CheckpointStatus] = [:]
        var work: Set<UUID> = []
        var trashed: Set<UUID> = []
        var existing: Set<UUID> = []
    }

    private let runningBare = UUID(), runningSaved = UUID(), runningThird = UUID(), runningBareThird = UUID()
    private let pausedBare = UUID(), pausedSaved = UUID(), runningMismatch = UUID(), pausedMismatch = UUID()
    private let orphanWork = UUID(), active = UUID(), queued = UUID(), failed = UUID()

    private func tree() -> Tree {
        var tree = Tree()
        var seq = 0
        func row(_ id: UUID, _ state: JobState?, attempts: Int = 0, reason: PauseReason? = nil, doneMs: Int64 = 0,
                 checkpoint: CheckpointStatus? = nil) {
            tree.existing.insert(id)
            if let checkpoint { tree.checkpoints[id] = checkpoint; tree.work.insert(id) }
            guard let state else { return }
            seq += 1
            tree.jobs.append(Job(noteID: id, seq: seq, kind: .transcribe, state: state, pauseReason: reason,
                                 attempts: attempts, doneMs: doneMs, totalMs: 60_000, words: doneMs > 0 ? 50 : 0,
                                 language: "it-IT", enqueuedAt: then))
        }
        let saved = CheckpointStatus.saved(doneMs: 28_000, totalMs: 60_000, words: 3)
        row(runningBare, .running)
        row(runningSaved, .running, attempts: 1, checkpoint: saved)
        row(runningThird, .running, attempts: 2, checkpoint: saved)
        row(runningBareThird, .running, attempts: 2)
        row(pausedBare, .paused, reason: .user, doneMs: 40_000)
        row(pausedSaved, .paused, reason: .user, doneMs: 28_000, checkpoint: saved)
        row(runningMismatch, .running, checkpoint: .mismatch)
        row(pausedMismatch, .paused, reason: .memory, doneMs: 28_000, checkpoint: .mismatch)
        row(orphanWork, nil, checkpoint: saved)
        row(active, .running)
        row(queued, .queued, checkpoint: .mismatch)
        row(failed, .failed, checkpoint: .mismatch)
        return tree
    }

    private func plan(_ tree: Tree) -> Reconcile.Plan {
        Reconcile.plan(jobs: tree.jobs, checkpoints: tree.checkpoints, work: tree.work, trashed: tree.trashed,
                       existing: tree.existing, activeNoteID: active, now: now)
    }

    /// The jobs after applying `plan` to `tree`.
    private func applied(_ plan: Reconcile.Plan, to tree: Tree) -> Tree {
        var tree = tree
        for job in plan.jobs { tree.jobs[tree.jobs.firstIndex { $0.noteID == job.noteID }!] = job }
        for id in plan.removeJobs { tree.jobs.removeAll { $0.noteID == id } }
        for id in plan.deleteWork { tree.work.remove(id); tree.checkpoints[id] = nil }
        return tree
    }

    private func job(_ id: UUID, in plan: Reconcile.Plan, _ tree: Tree) throws -> Job {
        try #require(applied(plan, to: tree).jobs.first { $0.noteID == id })
    }

    // ports: ReconcileOnStartTest#everyRowOfTheTable
    @Test func everyRowOfTheTable() throws {
        let tree = tree()
        let plan = plan(tree)

        // Running without saved progress: queued at the same seq, attempts + 1.
        let bare = try job(runningBare, in: plan, tree)
        #expect(bare.state == .queued)
        #expect(bare.seq == 1)
        #expect(bare.attempts == 1)
        #expect(bare.doneMs == 0)
        #expect(bare.updatedAt == now)
        // Running with saved progress: queued at its seq, attempts + 1, the checkpoint's numbers.
        let saved = try job(runningSaved, in: plan, tree)
        #expect(saved.state == .queued)
        #expect(saved.seq == 2)
        #expect(saved.attempts == 2)
        #expect(saved.doneMs == 28_000)
        #expect(saved.words == 3)
        // Past two attempts: paused as interrupted, its progress kept.
        let third = try job(runningThird, in: plan, tree)
        #expect(third.state == .paused && third.pauseReason == .interrupted)
        #expect(third.attempts == 3)
        #expect(third.doneMs == 28_000)
        // The same limit without saved progress (a crash while the model loads would otherwise loop).
        let bareThird = try job(runningBareThird, in: plan, tree)
        #expect(bareThird.state == .paused && bareThird.pauseReason == .interrupted)
        #expect(bareThird.attempts == 3)

        // Paused without saved progress: stays paused, from the beginning.
        let paused = try job(pausedBare, in: plan, tree)
        #expect(paused.state == .paused && paused.pauseReason == .user)
        #expect(paused.doneMs == 0 && paused.words == 0)
        // Paused with saved progress: unchanged.
        #expect(try job(pausedSaved, in: plan, tree) == tree.jobs.first { $0.noteID == pausedSaved })

        // Saved progress that no longer matches: failed, its files kept for Start over.
        for id in [runningMismatch, pausedMismatch] {
            let mismatched = try job(id, in: plan, tree)
            #expect(mismatched.state == .failed)
            #expect(mismatched.failure == .checkpointMismatch)
            #expect(mismatched.pauseReason == nil)
            #expect(!plan.deleteWork.contains(id))
        }

        // work/ that no job owns: deleted.
        #expect(plan.deleteWork == [orphanWork])

        // The active capture, queued and failed jobs are not touched.
        for id in [active, queued, failed] {
            #expect(try job(id, in: plan, tree) == tree.jobs.first { $0.noteID == id })
        }

        #expect(Set(plan.report.requeued) == [runningBare, runningSaved])
        #expect(Set(plan.report.interrupted) == [runningThird, runningBareThird])
        #expect(plan.report.restarted == [pausedBare])
        #expect(Set(plan.report.mismatched) == [runningMismatch, pausedMismatch])
        #expect(plan.report.deletedWork == [orphanWork])
    }

    // ports: ReconcileOnStartTest#aSecondRunChangesNothing
    @Test func aSecondRunChangesNothing() {
        let first = applied(plan(tree()), to: tree())
        let second = plan(first)
        #expect(second.jobs.isEmpty)
        #expect(second.deleteWork.isEmpty)
        #expect(second.report.isEmpty)
    }

    // ports: ReconcileOnStartTest#aTrashedQueuedNoteKeepsItsCheckpointForRestore
    @Test func aTrashedQueuedNoteKeepsItsCheckpointForRestore() {
        let id = UUID()
        // Trash deleted the row of the queued job; its work/ stays for Restore.
        let plan = Reconcile.plan(jobs: [], checkpoints: [id: .saved(doneMs: 28_000, totalMs: 60_000, words: 3)],
                                  work: [id], trashed: [id], existing: [id], activeNoteID: nil, now: now)
        #expect(plan.deleteWork.isEmpty)
        #expect(plan.report.isEmpty)
    }

    @Test func aJobThatTrashDidNotFinishWithEndsAsTrashWouldHaveEndedIt() {
        let queued = UUID(), running = UUID(), paused = UUID()
        let saved = CheckpointStatus.saved(doneMs: 28_000, totalMs: 60_000, words: 3)
        let jobs = [
            Job(noteID: queued, seq: 1, kind: .transcribe, state: .queued, enqueuedAt: then),
            Job(noteID: running, seq: 2, kind: .transcribeAgain, state: .running, enqueuedAt: then),
            Job(noteID: paused, seq: 3, kind: .transcribe, state: .paused, pauseReason: .user, enqueuedAt: then),
        ]
        let all: Set<UUID> = [queued, running, paused]
        let plan = Reconcile.plan(jobs: jobs, checkpoints: [queued: saved, running: saved], work: [queued, running],
                                  trashed: all, existing: all, activeNoteID: nil, now: now)
        #expect(plan.removeJobs == [queued], "a queued job leaves the queue")
        let stopped = try? #require(plan.jobs.first { $0.noteID == running })
        #expect(stopped?.state == .paused && stopped?.pauseReason == .user, "a running job is paused with its progress")
        #expect(stopped?.doneMs == 28_000)
        #expect(stopped?.attempts == 0, "it was stopped, not interrupted")
        #expect(!plan.jobs.contains { $0.noteID == paused }, "a paused job stays as it is")
        #expect(plan.deleteWork.isEmpty, "Restore needs the saved progress")
        #expect(plan.report.trashed == [queued, running])
    }

    @Test func workOfANoteThatCouldNotBeReadStays() {
        let id = UUID()
        let plan = Reconcile.plan(jobs: [], checkpoints: [:], work: [id], trashed: [], existing: [], activeNoteID: nil,
                                  now: now)
        #expect(plan.deleteWork.isEmpty)
    }
}

@Suite struct EnqueueRulesTests {
    @Test func theHeldQueueNoticeShowsOnlyWhileAHoldKeepsWaitingNotesFromStarting() {
        let a = UUID(), b = UUID()
        #expect(ProcessingState(queue: [a, b], hold: .user).heldWaiting == 2)
        #expect(ProcessingState(queue: [a], hold: .system).heldWaiting == 1)
        #expect(ProcessingState(queue: [a, b]).heldWaiting == nil, "nothing holds the queue")
        #expect(ProcessingState(queue: [], hold: .user).heldWaiting == nil, "nothing waits")
        #expect(ProcessingState(running: RunningJob(noteID: b, title: "B"), queue: [a], hold: .user).heldWaiting == nil,
                "the running job shows its own Stop")
    }

    // ports: JobRepositoryTest#enqueueRefusesNotesThatCannotBeTranscribed
    @Test func notesThatCannotBeTranscribedAreRefused() {
        var trashed = Note(title: "Trashed"); trashed.trashedAt = Date()
        var recording = Note(title: "Recording"); recording.audio = .live
        var unknown = Note(title: "Unknown"); unknown.document = DocumentInfo(state: .unknownFormat)
        var unplayable = Note(title: "Opus"); unplayable.audio = .unplayable(.unsupportedFormat)
        var unverified = Note(title: "Unverified"); unverified.document = DocumentInfo(state: .unverified)

        #expect(EnqueueRules.refusal(for: nil) == .noNote)
        #expect(EnqueueRules.refusal(for: trashed) == .trashed)
        #expect(EnqueueRules.refusal(for: recording) == .recording)
        #expect(EnqueueRules.refusal(for: unknown) == .unknownFormat)
        #expect(EnqueueRules.refusal(for: unplayable) == .unplayable)
        #expect(EnqueueRules.refusal(for: unverified) == nil, "only a format this build cannot read is refused")
        #expect(EnqueueRules.refusal(for: Note(title: "Plain")) == nil)
    }

    @Test func eachHoldYieldsOnlyToItsOwnRequests() {
        #expect(EnqueueRules.clears(.user, origin: .screen, resume: false))
        #expect(EnqueueRules.clears(.user, origin: .notification, resume: false))
        #expect(!EnqueueRules.clears(.user, origin: .automatic, resume: true))
        #expect(EnqueueRules.clears(.system, origin: .screen, resume: true))
        #expect(!EnqueueRules.clears(.system, origin: .screen, resume: false))
        #expect(!EnqueueRules.clears(.system, origin: .notification, resume: true))
        #expect(!EnqueueRules.clears(nil, origin: .screen, resume: true))
    }

    @Test func speakersOnlyJobsNeverTakeTheSpeechLanguage() {
        #expect(EnqueueRules.language(for: .transcribe, speechLanguage: "it-IT") == "it-IT")
        #expect(EnqueueRules.language(for: .transcribeAgain, speechLanguage: "it-IT") == "it-IT")
        #expect(EnqueueRules.language(for: .speakersOnly, speechLanguage: "it-IT") == nil)
    }

    @Test func theStoredStatusFollowsTheJob() {
        let job = Job(noteID: UUID(), seq: 1, kind: .transcribe, enqueuedAt: Date())
        func with(_ state: JobState) -> Job { var copy = job; copy.state = state; return copy }
        #expect(NoteStatus.mirroring(with(.queued), hasTranscript: true) == .queued)
        #expect(NoteStatus.mirroring(with(.running), hasTranscript: false) == .transcribing)
        #expect(NoteStatus.mirroring(with(.failed), hasTranscript: true) == .failed)
        #expect(NoteStatus.mirroring(with(.paused), hasTranscript: false) == .audioOnly)
        #expect(NoteStatus.mirroring(with(.needsConsent), hasTranscript: true) == .ready)
        #expect(NoteStatus.mirroring(nil, hasTranscript: false) == .audioOnly)
    }
}

@Suite struct RunningJobEventsTests {
    @Test func progressIsCappedBelowDoneAndNeverGoesBack() {
        var job = RunningJob(noteID: UUID(), title: "A")
        job = job.applying(.windowDone(doneMs: 30_000, totalMs: 60_000, words: []))
        #expect(job.phase == .transcribing)
        #expect(job.fraction == 0.5)
        job = job.applying(.windowDone(doneMs: 20_000, totalMs: 60_000, words: []))
        #expect(job.fraction == 0.5)
        job = job.applying(.windowDone(doneMs: 60_000, totalMs: 60_000, words: []))
        #expect(job.fraction == 0.99)
        job = job.applying(.stageChanged(.speakers))
        #expect(job.phase == .identifyingSpeakers)
        job = job.applying(.stopping)
        job = job.applying(.stageChanged(.saving))
        #expect(job.phase == .stopping, "a stop is shown until the job ends")
    }

    @Test func aResumedRunStartsFromItsSavedProgress() {
        let restored = RestoredCheckpoint(doneMs: 15_000, totalMs: 60_000, words: [], elapsedMs: 0)
        let job = RunningJob(noteID: UUID(), title: "A")
            .applying(.started(JobStart(totalMs: 60_000, restored: restored, speakers: true, prints: false)))
        #expect(job.fraction == 0.25)
        let downloading = RunningJob(noteID: UUID(), title: "A")
            .applying(.downloading(DownloadProgress(part: .speech, doneBytes: 1, totalBytes: 4, verifying: false)))
        #expect(downloading.phase == .downloading(0.25))
    }
}
