import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionCoordinatorTests {
    /// Remove from queue, Start over, Cancel and the writes that fail around a job.
    @MainActor @Suite struct Cancel {
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

        // ports: ProcessingCoordinatorTest#aFailureAroundTheJobEndsItAndTheQueueGoesOn
        @Test func aNoteWriteThatFailsAroundTheJobEndsItAndTheQueueGoesOn() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A"), b = try await h.note("B")
            await h.coordinator.transcribe(a)
            await h.coordinator.transcribe(b)
            let first = try await h.run(0)

            // The note's status cannot be saved when the job ends.
            let folder = h.notes.directory(for: a)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            first.finish(.failed(.unknown))

            #expect(try await h.run(1).noteID == b, "the coordinator is not stuck")
            #expect(await h.job(a)?.state == .failed)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try await h.run(1).finish(.done)
            await h.coordinator.awaitIdle()
            #expect(h.coordinator.moveToTrash(a) == TrashedJob(state: .failed, kind: .transcribe))
        }

        // ports: ProcessingCoordinatorTest#startOverAfterTheRunEndedButBeforeItsOutcomeIsWrittenStillDiscards
        @Test func startOverAfterTheRunEndedButBeforeItsOutcomeIsWrittenStillDiscards() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A"), other = try await h.note("Other")
            await h.coordinator.transcribe(a)
            let first = try await h.run(0)
            first.pauseOnStop = false
            h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            h.settings.queueHold = .user
            await h.coordinator.transcribe(other, origin: .automatic)

            // Another queue action keeps the serial section busy, so the outcome cannot be written yet.
            h.checkpoints.hold(other)
            let busy = Task { await h.coordinator.dequeue(other) }
            try await h.settle()
            #expect(h.coordinator.stop(a))
            let over = Task { await h.coordinator.startOver(a) }
            try await h.settle()
            first.finish(.paused(.user))
            try await h.waitUntil("the run ended") { first.hasEnded }
            h.checkpoints.release(other)
            _ = await busy.value

            #expect(await over.value == .queued(changed: true))
            #expect(!h.checkpoints.hasWork(a), "the saved progress is discarded")
            let again = try await h.run(1)
            #expect(again.noteID == a)
            #expect(again.job.doneMs == 0)
        }

        // ports: ProcessingCoordinatorTest#aRestartRequeuesRunningRowsAndPausesOnesPastTheirAttempts
        @Test func aKillWithThreeQueuedAndOneRunningJobRunsTheRunningOneFirstThenTheRestInOrder() async throws {
            let first = try QueueHarness(); defer { first.tearDown() }
            try await first.start()
            let ids = [try await first.note("Uno"), try await first.note("Due"), try await first.note("Tre"),
                       try await first.note("Quattro")]
            for id in ids { await first.coordinator.transcribe(id) }
            _ = try await first.run(0)
            try await first.waitUntil("one runs, three wait") { first.coordinator.state.queue == Array(ids.dropFirst()) }
            #expect(try JobRepository(root: first.root).load().map(\.state) == [.running, .queued, .queued, .queued])

            // Killed: nothing more is written. A new launch over the same files.
            let h = try first.reopened()
            try await h.start()
            #expect(h.coordinator.state.queue.count + (h.coordinator.state.running == nil ? 0 : 1) == 4)
            for (index, id) in ids.enumerated() {
                let run = try await h.run(index)
                #expect(run.noteID == id)
                run.finish(.done)
            }
            await h.coordinator.awaitIdle()
            #expect(h.runner.runs.map(\.noteID) == ids)
            #expect(await h.jobs.all().isEmpty)
        }
    }
}
