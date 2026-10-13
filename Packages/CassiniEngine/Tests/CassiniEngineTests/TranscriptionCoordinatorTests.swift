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
        #expect(h.coordinator.state.ahead(of: ids[1]) == 0, "the running job is not counted")
        #expect(h.coordinator.state.ahead(of: ids[2]) == 1)
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

    // ports: ProcessingCoordinatorTest#cancelDuringTheDownloadOfAJobPutsTheNoteBackToItsStateFromBefore
    @Test func cancelDuringTheDownloadOfAJobPutsTheNoteBackToItsStateFromBefore() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let fresh = try await h.note("Fresh"), resumed = try await h.note("Resumed"), late = try await h.note("Late")
        for id in [fresh, resumed, late] { await h.coordinator.transcribe(id) }
        h.checkpoints.save(resumed, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))

        // A first Transcribe goes back to "Audio only": the job goes. The download has reported no progress yet.
        let first = try await h.run(0)
        #expect(!h.coordinator.cancelDownload(), "a job that does not download is not cancelled")
        #expect(first.stopRequest == nil)
        first.send(.downloading(nil))
        try await h.waitUntil("the job downloads") { h.coordinator.state.running?.phase == .downloading(nil) }
        #expect(h.coordinator.cancelDownload())
        #expect(first.stopRequest == .pause(.user))
        #expect(try await h.run(1).noteID == resumed)
        #expect(await h.job(fresh) == nil)
        #expect(await h.notes.note(fresh)?.status == .audioOnly)

        // A note with saved progress goes back to paused by the user and keeps it.
        let second = try await h.run(1)
        second.send(.downloading(nil))
        try await h.waitUntil("the job downloads") { h.coordinator.state.running?.phase == .downloading(nil) }
        #expect(h.coordinator.cancelDownload())
        #expect(try await h.run(2).noteID == late)
        let paused = try #require(await h.job(resumed))
        #expect(paused.state == .paused && paused.pauseReason == .user)
        #expect(paused.doneMs == 28_000)
        #expect(await h.checkpoints.status(of: resumed) == .saved(doneMs: 28_000, totalMs: 60_000, words: 40))

        // A model download that starts once the job runs, before its size is known, is cancelled the same way.
        let third = try await h.run(2)
        third.send(.started(JobStart(totalMs: 10_000, speakers: true, prints: false)))
        third.send(.stageChanged(.speakers, startMs: 0, endMs: 0))
        third.send(.downloading(nil))
        try await h.waitUntil("the job downloads") { h.coordinator.state.running?.phase == .downloading(nil) }
        #expect(h.coordinator.cancelDownload())
        await h.coordinator.awaitIdle()
        #expect(await h.job(late) == nil)
        // Only the note that kept a paused job shows the Note's TX_PAUSED banner.
        #expect(Set(h.coordinator.state.jobs.keys) == [resumed])
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

    // MARK: Outcomes

    // ports: ProcessingCoordinatorTest#outcomesAreWrittenAndToldOnlyWhileTheAppIsHidden
    @Test func outcomesAreWrittenAndToldOnlyWhileTheAppIsHidden() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start(visible: false)
        let failed = try await h.note("Failed"), consentless = try await h.note("Consent"), shown = try await h.note("Shown")
        for id in [failed, consentless, shown] { await h.coordinator.transcribe(id) }

        try await h.run(0).finish(.failed(.checkpointMismatch))
        try await h.run(1).finish(.needsConsent(missingBytes: 1))
        // The outcome is written before it is told: Cassini comes back only once both were told.
        try await h.waitUntil("the second job's outcome is told") { h.notifier.posted.count == 2 }
        #expect(await h.job(consentless)?.state == .needsConsent)
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
