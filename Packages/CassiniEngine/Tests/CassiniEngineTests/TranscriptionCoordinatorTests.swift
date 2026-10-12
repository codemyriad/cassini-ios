import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The queue over real note and job files with a fake job runner: each claim is a `FakeJobRun` the test ends.
@MainActor @Suite(.serialized) struct TranscriptionCoordinatorTests {
    // MARK: Order, stop and holds

    // ports: ProcessingCoordinatorTest#jobsRunOneAtATimeInQueueOrder
    @Test func jobsRunOneAtATimeInQueueOrder() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let ids = [try await h.note("Uno"), try await h.note("Due"), try await h.note("Tre")]
        for id in ids { #expect(await h.coordinator.transcribe(id) == .queued(changed: true)) }

        let first = try await h.run(0)
        #expect(first.noteID == ids[0])
        try await h.waitUntil("the others wait") { h.coordinator.state.queue == [ids[1], ids[2]] }
        #expect(h.coordinator.state.isRunning(ids[0]))
        #expect(h.coordinator.state.ahead(of: ids[2]) == 2)
        #expect(await h.job(ids[0])?.state == .running)
        #expect(await h.notes.note(ids[0])?.status == .transcribing)
        #expect(await h.notes.note(ids[1])?.status == .queued)
        #expect(h.runner.runs.count == 1)

        first.finish(.done)
        #expect(try await h.run(1).noteID == ids[1])
        try await h.run(1).finish(.done)
        try await h.run(2).finish(.done)
        await h.coordinator.awaitIdle()
        #expect(h.runner.runs.map(\.noteID) == ids)
        #expect(await h.jobs.all().isEmpty)
        #expect(h.coordinator.state.running == nil)
        #expect(h.background.activeCount == 0, "the last job's background time ends with the queue")
    }

    // ports: ProcessingCoordinatorTest#stopKeepsProgressAndTheNextNoteStarts
    @Test func stopKeepsProgressAndTheNextNoteStarts() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A"), b = try await h.note("B")
        await h.coordinator.transcribe(a)
        await h.coordinator.transcribe(b)
        let first = try await h.run(0)
        h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))

        #expect(h.coordinator.stop(a))
        #expect(first.stopRequest == .pause(.user))
        #expect(try await h.run(1).noteID == b)
        let paused = try #require(await h.job(a))
        #expect(paused.state == .paused)
        #expect(paused.pauseReason == .user)
        #expect(paused.doneMs == 28_000 && paused.words == 40)
        #expect(!h.coordinator.stop(a), "a note that does not run cannot be stopped")
    }

    // ports: ProcessingCoordinatorTest#stopAllHoldsTheQueueUntilContinue
    @Test func stopAllHoldsTheQueueUntilContinue() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A"), b = try await h.note("B")
        await h.coordinator.transcribe(a)
        await h.coordinator.transcribe(b)
        _ = try await h.run(0)

        h.coordinator.stopAll()
        try await h.waitUntil("A is paused") { await h.job(a)?.state == .paused }
        await h.coordinator.awaitIdle()
        #expect(h.settings.queueHold == .user)
        #expect(await h.job(b)?.state == .queued)
        #expect(h.runner.runs.count == 1, "the held queue starts nothing")
        #expect(h.coordinator.state.hold == .user)
        #expect(h.coordinator.state.queue == [b])

        h.coordinator.continueQueue()
        #expect(try await h.run(1).noteID == b)
        #expect(h.settings.queueHold == nil)
    }

    // ports: ProcessingCoordinatorTest#anExplicitTranscribeClearsTheUserHold
    @Test func anExplicitTranscribeClearsTheUserHold() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        h.settings.queueHold = .user
        let a = try await h.note("A")
        await h.coordinator.transcribe(a, origin: .automatic)
        try await h.settle()
        #expect(h.runner.runs.isEmpty, "the automatic enqueue keeps the hold")
        await h.coordinator.transcribe(a)
        #expect(try await h.run(0).noteID == a)
    }

    // MARK: Remove from queue, Start over, Cancel

    // ports: ProcessingCoordinatorTest#removeFromQueueDeletesTheRowOrPausesANoteWithACheckpoint
    @Test func removeFromQueueDeletesTheJobOrPausesANoteWithSavedProgress() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let running = try await h.note("Running"), bare = try await h.note("Bare"), saved = try await h.note("Saved")
        for id in [running, bare, saved] { await h.coordinator.transcribe(id) }
        let first = try await h.run(0)
        h.checkpoints.save(saved, .saved(doneMs: 56_000, totalMs: 90_000, words: 70))

        #expect(await h.coordinator.dequeue(bare) == .removed)
        #expect(await h.job(bare) == nil)
        #expect(await h.notes.note(bare)?.status == .audioOnly)
        #expect(await h.coordinator.dequeue(saved) == .paused)
        let paused = try #require(await h.job(saved))
        #expect(paused.state == .paused && paused.pauseReason == .user)
        #expect(paused.doneMs == 56_000)
        #expect(await h.coordinator.dequeue(running) == .notQueued)

        first.finish(.done)
        await h.coordinator.awaitIdle()
        #expect(h.runner.runs.count == 1, "nothing else was queued")
    }

    // ports: ProcessingCoordinatorTest#startOverDiscardsTheCheckpointAndQueuesTheNoteAgain
    @Test func startOverDiscardsTheSavedProgressAndQueuesTheNoteAgain() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A")
        await h.coordinator.transcribe(a, kind: .transcribeAgain)
        let first = try await h.run(0)
        h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))

        // On the running note: cancel, discard once it ended, then the back of the queue.
        #expect(await h.coordinator.startOver(a) == .queued(changed: true))
        #expect(first.stopRequest == .cancel)
        #expect(!h.checkpoints.hasWork(a))
        let again = try await h.run(1)
        #expect(again.noteID == a)
        #expect(again.job.kind == .transcribeAgain, "Start over keeps the kind")

        // On a paused note.
        h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
        again.finish(.paused(.user))
        try await h.waitUntil("A is paused") { await h.job(a)?.state == .paused }
        #expect(await h.job(a)?.doneMs == 28_000)
        await h.coordinator.startOver(a)
        let third = try await h.run(2)
        #expect(third.noteID == a)
        #expect(!h.checkpoints.hasWork(a))
        #expect(third.job.doneMs == 0)
    }

    @Test func aTranscribeRightAfterACancelIsQueuedAndStartsOnceTheCancelledJobEnded() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A")
        await h.coordinator.transcribe(a)
        let first = try await h.run(0)
        first.pauseOnStop = false

        // Stop, and Transcribe again before the job has wound down.
        #expect(h.coordinator.stop(a))
        let transcribe = Task { await h.coordinator.transcribe(a) }
        try await h.settle()
        #expect(h.runner.runs.count == 1)
        first.finish(.paused(.user))

        #expect(await transcribe.value == .queued(changed: true))
        #expect(try await h.run(1).noteID == a, "no job is lost after a cancel")
    }

    @Test func aDismissedFailureRemovesTheJobAndTooLongDropsItsWork() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let short = try await h.note("Short"), long = try await h.note("Long")
        await h.coordinator.transcribe(short)
        await h.coordinator.transcribe(long)
        try await h.run(0).finish(.failed(.short))
        h.checkpoints.save(long, .saved(doneMs: 1_000, totalMs: 60_000, words: 1))
        try await h.run(1).finish(.failed(.long))
        await h.coordinator.awaitIdle()
        #expect(await h.notes.note(short)?.status == .failed)
        #expect(await h.notes.note(short)?.failure == .short)

        await h.coordinator.clearFailed(short)
        await h.coordinator.clearFailed(long)
        #expect(await h.jobs.all().isEmpty)
        #expect(await h.notes.note(short)?.failure == nil)
        #expect(await h.notes.note(short)?.status == .audioOnly)
        #expect(!h.checkpoints.hasWork(long), "too long: no new try can use the saved progress")
    }

    // ports: ProcessingCoordinatorTest#aFailureAroundTheJobEndsItAndTheQueueGoesOn
    @Test func aClaimThatCannotBeSavedLeavesTheJobQueuedForTheNextDrain() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A")
        // Queued behind a hold, so the claim happens only on Continue.
        h.settings.queueHold = .user
        await h.coordinator.transcribe(a, origin: .automatic)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.root.path)
        h.coordinator.continueQueue()
        await h.coordinator.awaitIdle()
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.root.path)
        #expect(h.runner.runs.isEmpty)
        #expect(h.coordinator.state.running == nil, "the coordinator is not stuck on a job it could not start")
        #expect(await h.job(a)?.state == .queued, "the failed claim left the job queued")
        #expect(try JobRepository(root: h.root).load().map(\.state) == [.queued])

        h.coordinator.continueQueue()
        #expect(try await h.run(0).noteID == a)
    }

    // MARK: Recently Deleted

    // ports: ProcessingCoordinatorTest#trashDeletesAQueuedRowButKeepsItsWork
    @Test func trashDeletesAQueuedJobButKeepsItsWork() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let running = try await h.note("Running"), queued = try await h.note("Queued")
        await h.coordinator.transcribe(running)
        await h.coordinator.transcribe(queued)
        let first = try await h.run(0)
        h.checkpoints.save(queued, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))

        #expect(h.coordinator.moveToTrash(queued) == TrashedJob(state: .queued, kind: .transcribe))
        try await h.waitUntil("the queued job is gone") { await h.job(queued) == nil }
        #expect(h.checkpoints.hasWork(queued), "Restore needs the saved progress")
        #expect(first.stopRequest == nil, "the running note is untouched")
    }

    // ports: ProcessingCoordinatorTest#restoreOfAQueuedNoteStartsTheQueue
    @Test func restoreOfAQueuedNoteStartsTheQueue() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let running = try await h.note("Running"), queued = try await h.note("Queued")
        await h.coordinator.transcribe(running)
        await h.coordinator.transcribe(queued)
        let first = try await h.run(0)
        h.checkpoints.save(queued, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
        let trashed = h.coordinator.moveToTrash(queued)
        try await h.notes.mutate(queued) { $0.trashedAt = Date() }
        try await h.waitUntil("the queued job left the queue") { await h.job(queued) == nil }
        first.finish(.done)
        await h.coordinator.awaitIdle()
        #expect(h.runner.runs.count == 1)

        try await h.notes.mutate(queued) { $0.trashedAt = nil }
        await h.coordinator.restore(queued, trashedJob: trashed)
        let restored = try await h.run(1)
        #expect(restored.noteID == queued)
        #expect(restored.job.doneMs == 28_000, "the job takes the numbers of its saved progress")
    }

    // ports: ProcessingCoordinatorTest#trashStopsARunningJobAndKeepsItsProgress
    @Test func trashStopsARunningJobAndKeepsItsProgress() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A")
        await h.coordinator.transcribe(a)
        let first = try await h.run(0)
        h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))

        #expect(h.coordinator.moveToTrash(a) == TrashedJob(state: .paused, kind: .transcribe))
        #expect(first.stopRequest == .pause(.user))
        await h.coordinator.awaitIdle()
        let job = try #require(await h.job(a))
        #expect(job.state == .paused && job.pauseReason == .user)
        #expect(job.doneMs == 28_000)
        #expect(h.checkpoints.hasWork(a))
    }

    // ports: ProcessingCoordinatorTest#trashKeepsAPausedJob
    @Test func trashKeepsAPausedJob() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A")
        await h.coordinator.transcribe(a)
        try await h.run(0).finish(.paused(.user))
        try await h.waitUntil("A is paused") { await h.job(a)?.state == .paused }

        #expect(h.coordinator.moveToTrash(a) == TrashedJob(state: .paused, kind: .transcribe))
        try await h.settle()
        #expect(await h.job(a)?.state == .paused)
    }

    @Test func aPermanentDeleteStopsTheJobAndRemovesIt() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A")
        await h.coordinator.transcribe(a)
        let first = try await h.run(0)
        await h.coordinator.forget(a)
        #expect(first.hasEnded)
        #expect(await h.job(a) == nil)
    }

    // MARK: Restart

    // ports: ProcessingCoordinatorTest#aRestartRequeuesRunningRowsAndPausesOnesPastTheirAttempts
    @Test func aRestartRequeuesRunningJobsAndPausesOnesPastTheirAttempts() async throws {
        let first = try QueueHarness(); defer { first.tearDown() }
        try await first.start()
        let withCheckpoint = try await first.note("Checkpoint"), bare = try await first.note("Bare")
        let third = try await first.note("Third"), pausedBare = try await first.note("Paused")
        first.checkpoints.save(withCheckpoint, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
        let now = first.clock.now
        try JobRepository(root: first.root).save([
            Job(noteID: withCheckpoint, seq: 1, kind: .transcribe, state: .running, enqueuedAt: now),
            Job(noteID: bare, seq: 2, kind: .transcribe, state: .running, enqueuedAt: now),
            Job(noteID: third, seq: 3, kind: .transcribe, state: .running, attempts: 2, enqueuedAt: now),
            Job(noteID: pausedBare, seq: 4, kind: .transcribe, state: .paused, pauseReason: .user, doneMs: 12_000,
                enqueuedAt: now),
        ])

        // Cassini closed: a new launch over the same files, not on the screen.
        let h = try first.reopened()
        try await h.start(visible: false)
        let state = h.coordinator.state
        #expect(state.queue == [withCheckpoint, bare])
        #expect(state.jobs[withCheckpoint]?.doneMs == 28_000)
        #expect(state.jobs[bare]?.doneMs == 0)
        #expect(state.jobs[bare]?.attempts == 1)
        #expect(state.jobs[third]?.pauseReason == .interrupted)
        #expect(state.jobs[pausedBare]?.state == .paused)
        #expect(state.jobs[pausedBare]?.doneMs == 0, "a paused job without saved progress starts from 0")
        #expect(h.notifier.posted.map(\.noteID) == [third])
        #expect(h.notifier.posted.first?.kind == .transcriptionStopped)
        try await h.settle()
        #expect(h.runner.runs.isEmpty, "nothing starts while Cassini is not on the screen")

        // On the screen: the queue starts, the job with saved progress first.
        h.coordinator.setVisible(true)
        #expect(try await h.run(0).noteID == withCheckpoint)
        try await h.run(0).finish(.done)
        #expect(try await h.run(1).noteID == bare)
        try await h.run(1).finish(.done)
        await h.coordinator.awaitIdle()
        #expect(h.runner.runs.count == 2, "paused jobs never resume on their own")
    }

    // ports: ProcessingCoordinatorTest#aVisibleAppStartsAWaitingQueueWithoutAnyReadOfTheCoordinator
    @Test func aVisibleAppStartsAWaitingQueueAtLaunch() async throws {
        let first = try QueueHarness(); defer { first.tearDown() }
        try await first.start()
        let id = try await first.note("Waiting")
        try JobRepository(root: first.root).save([Job(noteID: id, seq: 1, kind: .transcribe, enqueuedAt: first.clock.now)])

        let h = try first.reopened()
        try await h.start(visible: true)
        #expect(try await h.run(0).noteID == id)
        try await h.run(0).finish(.done)
        await h.coordinator.awaitIdle()
        #expect(h.runner.runs.count == 1)
    }

    @Test func aNoteThatSaysItWasTranscribingWithoutAJobIsSetBack() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        var note = Note(title: "Older queue", audioFilename: "audio.m4a")
        note.status = .transcribing
        note.transcript = [TranscriptSegment(text: "Keep this.", start: 0, end: 1)]
        try await h.notes.save(note)
        h.checkpoints.addWork(note.id)
        let report = try await h.start()
        let stored = try #require(await h.notes.note(note.id))
        #expect(stored.status == .ready)
        #expect(stored.failure == .interrupted)
        #expect(report.deletedWork == [note.id])
    }

    // MARK: Consent

    // ports: ProcessingCoordinatorTest#withoutConsentTranscribeEndsNeedsConsentWithoutAnyJobOrNetwork
    @Test func withoutConsentTranscribeEndsReadyToTranscribeWithoutAnyJobRun() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        h.consented = false
        try await h.start()
        let a = try await h.note("A")

        #expect(await h.coordinator.transcribe(a) == .needsConsent)
        #expect(await h.job(a)?.state == .needsConsent)
        h.coordinator.drain()
        await h.coordinator.awaitIdle()
        #expect(h.runner.runs.isEmpty)

        // With consent the same note goes to the queue.
        h.consented = true
        #expect(await h.coordinator.transcribe(a) == .queued(changed: true))
        #expect(try await h.run(0).noteID == a)
    }

    @Test func speakersOnlyNeverChangesTheLanguage() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A")
        try await h.notes.mutate(a) { $0.language = "en-US" }
        h.settings.speechLanguage = "it-IT"
        await h.coordinator.transcribe(a, kind: .speakersOnly)
        #expect(try await h.run(0).job.language == "en-US")
        #expect(await h.notes.note(a)?.language == "en-US")
        try await h.run(0).finish(.done)
        await h.coordinator.awaitIdle()

        await h.coordinator.transcribe(a, kind: .transcribeAgain)
        #expect(try await h.run(1).job.language == "it-IT")
        #expect(await h.notes.note(a)?.language == "it-IT")
    }

    // MARK: Background time

    // ports: ProcessingCoordinatorTest#aSystemStopPausesTheRowAtOnceAndHoldsTheQueue
    @Test func aSystemStopPausesTheJobAtOnceAndHoldsTheQueue() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A"), b = try await h.note("B")
        await h.coordinator.transcribe(a)
        await h.coordinator.transcribe(b)
        let first = try await h.run(0)
        first.pauseOnStop = false
        h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
        #expect(h.background.activeCount == 1)

        h.coordinator.setVisible(false)
        h.background.expireAll()
        #expect(first.stopRequest == .pause(.system), "the job learns of it before the handler returns")
        #expect(h.settings.queueHold == .system)
        #expect(h.background.activeCount == 0)
        try await h.waitUntil("every screen shows Paused") { await h.job(a)?.state == .paused }
        let job = try #require(await h.job(a))
        #expect(job.pauseReason == .system)
        #expect(job.doneMs == 28_000, "the job has the numbers of its saved progress")
        try await h.waitUntil("the person is told") { !h.notifier.posted.isEmpty }
        #expect(h.notifier.posted.first?.kind == .pausedBySystem)

        first.finish(.paused(.system))
        await h.coordinator.awaitIdle()
        #expect(await h.job(b)?.state == .queued)
        #expect(h.runner.runs.count == 1)

        // A Transcribe that is not a Resume, or a Resume from a notification, keeps the system hold.
        await h.coordinator.transcribe(b)
        await h.coordinator.transcribe(a, origin: .notification)
        try await h.settle()
        #expect(h.runner.runs.count == 1)
        #expect(h.settings.queueHold == .system)
        // Continue from the screen clears it; B was queued first.
        h.coordinator.continueQueue()
        #expect(try await h.run(1).noteID == b)
    }

    // ports: ProcessingCoordinatorTest#aResumeFromAVisibleScreenClearsTheSystemHold
    @Test func aResumeFromAVisibleScreenClearsTheSystemHold() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A")
        await h.coordinator.transcribe(a)
        let first = try await h.run(0)
        first.pauseOnStop = false
        h.coordinator.systemStop()
        try await h.run(0).finish(.paused(.system))
        await h.coordinator.awaitIdle()

        await h.coordinator.transcribe(a, origin: .screen)
        #expect(h.settings.queueHold == nil)
        #expect(try await h.run(1).noteID == a)
    }

    @Test func eachJobHasItsOwnBackgroundTimeHandedOverWithoutAGap() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A"), b = try await h.note("B")
        await h.coordinator.transcribe(a)
        await h.coordinator.transcribe(b)
        try await h.run(0).finish(.done)
        _ = try await h.run(1)
        #expect(h.background.activeCount == 1)
        #expect(h.background.endedCount == 1)
        try await h.run(1).finish(.done)
        await h.coordinator.awaitIdle()
        #expect(h.background.activeCount == 0)
        #expect(h.background.endedCount == 2)
    }

    // MARK: Outcomes

    // ports: ProcessingCoordinatorTest#outcomesAreWrittenAndToldOnlyWhileTheAppIsHidden
    @Test func outcomesAreWrittenAndToldOnlyWhileTheAppIsHidden() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start(visible: false)
        let failed = try await h.note("Failed"), consentless = try await h.note("Consent"), shown = try await h.note("Shown")
        for id in [failed, consentless, shown] { await h.coordinator.transcribe(id) }

        try await h.run(0).finish(.failed(.checkpointMismatch))
        try await h.run(1).finish(.needsConsent(missingBytes: 1))
        try await h.waitUntil("the second job waits for consent") { await h.job(consentless)?.state == .needsConsent }
        h.coordinator.setVisible(true)
        try await h.run(2).finish(.failed(.checkpointMismatch))
        await h.coordinator.awaitIdle()

        #expect(await h.job(failed)?.failure == .checkpointMismatch)
        #expect(await h.job(shown)?.state == .failed)
        #expect(h.notifier.posted.map(\.noteID) == [failed, consentless])
        #expect(h.notifier.posted.map(\.kind) == [.failed(.checkpointMismatch), .readyToTranscribe])
    }

    @Test func runningProgressFollowsTheJobsEvents() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A")
        await h.coordinator.transcribe(a)
        let run = try await h.run(0)
        run.send(.windowDone(doneMs: 30_000, totalMs: 60_000, words: []))
        try await h.waitUntil("half done") { h.coordinator.state.running?.fraction == 0.5 }
        #expect(h.coordinator.state.running?.title == "A")
        run.send(.checkpointed(doneMs: 30_000))
        try await h.waitUntil("the job has the checkpoint's numbers") { await h.job(a)?.doneMs == 30_000 }
        run.finish(.done)
        await h.coordinator.awaitIdle()
        #expect(h.coordinator.state.running == nil)
        #expect(await h.notes.note(a)?.status == .audioOnly, "the job wrote no transcript")
    }
}
