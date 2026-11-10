import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionCoordinatorTests {
    /// The background time of the drain loop and the system's Stop.
    @MainActor @Suite struct Background {
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

        @Test func oneBackgroundTimeCoversTheWholeQueueAndTakesEachJobsTitle() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A"), b = try await h.note("B")
            await h.coordinator.transcribe(a)
            await h.coordinator.transcribe(b)
            _ = try await h.run(0)
            #expect(Array(h.background.titles.values) == ["Transcribing “A”"])
            #expect(Array(h.background.subtitles.values) == ["Your audio stays on this device"])
            try await h.run(0).finish(.done)
            _ = try await h.run(1)
            #expect(h.background.begunCount == 1, "the next job runs in the same background time")
            #expect(h.background.endedCount == 0)
            #expect(Array(h.background.titles.values) == ["Transcribing “B”"])
            try await h.run(1).finish(.done)
            await h.coordinator.awaitIdle()
            #expect(h.background.activeCount == 0)
            #expect(h.background.endedCount == 1, "it ends with the queue")
        }

        @Test func aKillRightAfterIOSTookTheTimeBackKeepsTheJobPausedByTheSystem() async throws {
            let first = try QueueHarness(); defer { first.tearDown() }
            try await first.start(visible: false)
            let a = try await first.note("A"), b = try await first.note("B")
            await first.coordinator.transcribe(a)
            await first.coordinator.transcribe(b)
            let run = try await first.run(0)
            run.pauseOnStop = false // the step that runs goes on after the stop, as on a device
            first.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))

            // The token ends before iOS's handler returns, and iOS kills Cassini at once: only what was stored before
            // then survives. Copy the files and preferences now, before the pause write the handler started can run.
            first.background.expireAll()
            #expect(first.background.activeCount == 0, "the time ends before the handler returns")
            #expect(first.settings.queueHold == .system)
            let killed = try QueueHarness.snapshot(of: first)
            defer { killed.tearDown() }
            #expect(try JobRepository(root: killed.root).load().first { $0.noteID == a }?.state == .running,
                    "the pause had not landed")

            let report = try await killed.start(visible: false)
            #expect(report.pausedBySystem == [a])
            #expect(report.requeued.isEmpty)
            let job = try #require(await killed.job(a))
            #expect(job.state == .paused && job.pauseReason == .system)
            #expect(job.attempts == 0, "a system stop is not a crash")
            #expect(job.doneMs == 28_000, "the job has the numbers of its saved progress")
            #expect(await killed.notes.note(a)?.status == .audioOnly)
            #expect(killed.notifier.posted.map(\.kind) == [.pausedBySystem], "the notification the kill lost is posted")
            #expect(killed.settings.queueHold == .system)
            killed.coordinator.setVisible(true)
            try await killed.settle()
            #expect(killed.runner.runs.isEmpty, "the queue stays held until Continue")
            #expect(await killed.job(b)?.state == .queued)

            run.finish(.paused(.system))
            await first.coordinator.awaitIdle()
        }

        /// iOS 18 has no continued processing, so every transcription still running when the finite background time
        /// ends goes through this: paused by the system with its checkpoint, the queue held, then a later launch over
        /// the same files keeps that one job paused by the system until a Resume from the screen runs it from its
        /// checkpoint to the end. Nothing in between starts it again or makes a second job.
        @Test func aJobIOSPausedInTheBackgroundStaysOneJobAcrossALaunchAndAResumeFinishesItFromItsCheckpoint() async throws {
            let first = try QueueHarness(); defer { first.tearDown() }
            try await first.start()
            let a = try await first.note("A")
            await first.coordinator.transcribe(a)
            let run = try await first.run(0)
            run.pauseOnStop = false
            first.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))

            first.coordinator.setVisible(false)
            first.background.expireAll()
            #expect(run.stopRequest == .pause(.system))
            run.finish(.paused(.system))
            await first.coordinator.awaitIdle()
            let paused = try #require(await first.job(a))
            #expect(paused.state == .paused && paused.pauseReason == .system)
            #expect(paused.doneMs == 28_000)
            #expect(first.settings.queueHold == .system)

            // The next launch: the job was already written as paused, so the repair leaves it as it is.
            let second = try first.reopened()
            let report = try await second.start(visible: true)
            #expect(report.isEmpty, "nothing to repair: \(report)")
            #expect(await second.jobs.all().map(\.noteID) == [a], "one job")
            let relaunched = try #require(await second.job(a))
            #expect(relaunched.state == .paused && relaunched.pauseReason == .system)
            #expect(relaunched.doneMs == 28_000 && relaunched.attempts == 0)
            #expect(second.settings.queueHold == .system)
            try await second.settle()
            #expect(second.runner.runs.isEmpty, "coming to the screen does not start it")

            #expect(await second.coordinator.transcribe(a, origin: .screen) == .queued(changed: true))
            #expect(second.settings.queueHold == nil)
            let resumed = try await second.run(0)
            #expect(resumed.noteID == a)
            #expect(resumed.job.doneMs == 28_000, "the run is given its checkpoint's numbers, not zero")
            #expect(await second.jobs.all().count == 1, "Resume moved the job, it did not add one")
            resumed.finish(.done)
            await second.coordinator.awaitIdle()
            #expect(await second.jobs.all().isEmpty)
            #expect(second.runner.runs.count == 1)
        }

        @Test func afterIOSTookTheTimeBackTheNextDrainAsksForNewTime() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A"), b = try await h.note("B")
            await h.coordinator.transcribe(a)
            await h.coordinator.transcribe(b)
            _ = try await h.run(0)
            h.background.expireAll()
            try await h.waitUntil("A is paused") { await h.job(a)?.state == .paused }
            await h.coordinator.awaitIdle()

            h.coordinator.continueQueue()
            _ = try await h.run(1)
            #expect(h.background.begunCount == 2)
            #expect(h.background.activeCount == 1)
        }

        // ports: ProcessingCoordinatorTest#aSystemStopReachesTheJobAtOnceAndThePausedNoticeGetsTheLastCheckpoint
        @Test func aSystemStopReachesTheJobAtOnceAndThePausedJobGetsTheLastCheckpoint() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A")
            await h.coordinator.transcribe(a)
            let first = try await h.run(0)
            first.pauseOnStop = false
            h.checkpoints.save(a, .saved(doneMs: 288_000, totalMs: 600_000, words: 400))

            h.coordinator.systemStop()
            #expect(first.stopRequest == .pause(.system), "the job is stopped at once")
            try await h.waitUntil("A is paused") { await h.job(a)?.state == .paused }
            #expect(await h.job(a)?.doneMs == 288_000)

            // The step that was running at the stop ends and saves its progress, then the job ends.
            h.checkpoints.save(a, .saved(doneMs: 314_000, totalMs: 600_000, words: 430))
            first.finish(.paused(.system))
            await h.coordinator.awaitIdle()
            let job = try #require(await h.job(a))
            #expect(job.state == .paused && job.pauseReason == .system)
            #expect(job.doneMs == 314_000)
        }
    }
}
