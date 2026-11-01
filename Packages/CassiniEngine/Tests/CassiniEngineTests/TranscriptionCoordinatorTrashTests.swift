import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionCoordinatorTests {
    /// The queue around Recently Deleted.
    @MainActor @Suite struct Trash {
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
            h.checkpoints.save(queued, .saved(doneMs: 28_000, totalMs: 60_000, words: 40), language: "it-IT")
            let trashed = h.coordinator.moveToTrash(queued)
            try await h.notes.mutate(queued) { $0.trashedAt = Date() }
            try await h.waitUntil("the queued job left the queue") { await h.job(queued) == nil }
            first.finish(.done)
            await h.coordinator.awaitIdle()
            #expect(h.runner.runs.count == 1)

            try await h.notes.mutate(queued) { $0.trashedAt = nil }
            h.settings.speechLanguage = "en-US"
            await h.coordinator.restore(queued, trashedJob: trashed)
            let restored = try await h.run(1)
            #expect(restored.noteID == queued)
            #expect(restored.job.doneMs == 28_000, "the job takes the numbers of its saved progress")
            #expect(restored.job.language == "it-IT", "and the language that progress began in, which it must match")
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

        @Test func anUndoRightAfterTrashKeepsTheQueuedJob() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let running = try await h.note("Running"), queued = try await h.note("Queued")
            await h.coordinator.transcribe(running)
            await h.coordinator.transcribe(queued)
            let first = try await h.run(0)

            let trashed = h.coordinator.moveToTrash(queued)
            await h.coordinator.restore(queued, trashedJob: trashed)
            try await h.settle()
            #expect(await h.job(queued)?.state == .queued)
            #expect(h.coordinator.state.queue == [queued])
            first.finish(.done)
            #expect(try await h.run(1).noteID == queued)
        }

        @Test func aQueuedJobOfANoteInRecentlyDeletedNeitherWaitsNorRunsAfterARelaunch() async throws {
            let first = try QueueHarness(); defer { first.tearDown() }
            try await first.start()
            let gone = try await first.note("Gone"), live = try await first.note("Live")
            try await first.notes.mutate(gone) { $0.trashedAt = first.clock.now }
            first.checkpoints.save(gone, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            // Cassini closed before Trash removed the queued job.
            try JobRepository(root: first.root).save([
                Job(noteID: gone, seq: 1, kind: .transcribe, enqueuedAt: first.clock.now),
                Job(noteID: live, seq: 2, kind: .transcribe, state: .paused, pauseReason: .user, enqueuedAt: first.clock.now),
            ])

            let h = try first.reopened()
            h.settings.queueHold = .user
            let report = try await h.start()
            #expect(report.trashed == [gone])
            #expect(h.coordinator.state.queue.isEmpty)
            #expect(h.coordinator.state.heldWaiting == nil, "nothing waits behind the hold")
            #expect(await h.job(gone) == nil)
            #expect(h.checkpoints.hasWork(gone), "Restore needs the saved progress")
            h.settings.queueHold = nil
            h.coordinator.setVisible(true)
            try await h.settle()
            #expect(h.runner.runs.isEmpty)
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
    }
}
