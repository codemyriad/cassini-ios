import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionCoordinatorTests {
    /// The proposal of docs/ios18.md: on a system without continued processing, coming back to the screen resumes what
    /// the end of the finite background time paused, from its checkpoint, without a Resume.
    @MainActor @Suite struct Activation {
        /// Runs A and B, saves A's progress, and lets the background time run out while A runs.
        private func pausedBySystem(_ h: QueueHarness) async throws -> (a: UUID, b: UUID) {
            try await h.start()
            let a = try await h.note("A"), b = try await h.note("B")
            await h.coordinator.transcribe(a)
            await h.coordinator.transcribe(b)
            let run = try await h.run(0)
            run.pauseOnStop = false
            h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            h.coordinator.setVisible(false)
            h.background.expireAll()
            run.finish(.paused(.system))
            await h.coordinator.awaitIdle()
            #expect(await h.job(a)?.pauseReason == .system)
            #expect(h.settings.queueHold == .system)
            return (a, b)
        }

        @Test func onIOS18ComingBackResumesTheJobFromItsCheckpointThenTheQueue() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, b) = try await pausedBySystem(h)

            h.coordinator.setVisible(true)
            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [a])
            #expect(h.settings.queueHold == nil)
            let resumed = try await h.run(1)
            #expect(resumed.noteID == b, "A went to the back of the queue, as a Resume puts it")
            try await h.run(1).finish(.done)
            let again = try await h.run(2)
            #expect(again.noteID == a)
            #expect(again.job.doneMs == 28_000, "from its checkpoint")
            again.finish(.done)
            await h.coordinator.awaitIdle()
            #expect(await h.jobs.all().isEmpty)
            #expect(h.runner.runs.count == 3)
        }

        @Test func onIOS26TheSystemHoldStillWaitsForResume() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, b) = try await pausedBySystem(h)

            h.coordinator.setVisible(true)
            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS26) == [])
            try await h.settle()
            #expect(h.settings.queueHold == .system)
            #expect(h.runner.runs.count == 1)
            #expect(await h.job(a)?.state == .paused)
            #expect(await h.job(b)?.state == .queued)
        }

        @Test func thePersonsOwnPauseIsNeverResumed() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A"), b = try await h.note("B")
            await h.coordinator.transcribe(a)
            await h.coordinator.transcribe(b)
            _ = try await h.run(0)
            h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            h.coordinator.stopAll()
            await h.coordinator.awaitIdle()
            #expect(await h.job(a)?.pauseReason == .user)
            #expect(h.settings.queueHold == .user)

            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [])
            try await h.settle()
            #expect(h.settings.queueHold == .user)
            #expect(h.runner.runs.count == 1)
            #expect(await h.job(a)?.state == .paused)
        }

        /// Under a system hold, a job the person paused before stays paused; only the system's comes back.
        @Test func underASystemHoldOnlyTheSystemsPauseIsResumed() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let mine = try await h.note("Mine"), a = try await h.note("A")
            await h.coordinator.transcribe(mine)
            _ = try await h.run(0)
            h.checkpoints.save(mine, .saved(doneMs: 10_000, totalMs: 60_000, words: 10))
            h.coordinator.stop(mine)
            try await h.waitUntil("mine is paused") { await h.job(mine)?.state == .paused }
            await h.coordinator.awaitIdle()
            await h.coordinator.transcribe(a)
            let run = try await h.run(1)
            run.pauseOnStop = false
            h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            h.background.expireAll()
            run.finish(.paused(.system))
            await h.coordinator.awaitIdle()

            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [a])
            let resumed = try await h.run(2)
            #expect(resumed.noteID == a)
            resumed.finish(.done)
            await h.coordinator.awaitIdle()
            let kept = try #require(await h.job(mine))
            #expect(kept.state == .paused && kept.pauseReason == .user)
            #expect(h.runner.runs.count == 3)
        }

        /// iOS killed Cassini right after taking the time back: the launch repair pauses the job by the system, and
        /// the launch's coming to the screen resumes it.
        @Test func afterAKillTheLaunchResumesTheJobOnce() async throws {
            let first = try QueueHarness(); defer { first.tearDown() }
            try await first.start(visible: false)
            let a = try await first.note("A")
            await first.coordinator.transcribe(a)
            let run = try await first.run(0)
            run.pauseOnStop = false
            first.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            first.background.expireAll()
            let killed = try QueueHarness.snapshot(of: first)
            defer { killed.tearDown() }

            #expect(try await killed.start(visible: true).pausedBySystem == [a])
            #expect(await killed.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [a])
            let resumed = try await killed.run(0)
            #expect(resumed.job.doneMs == 28_000)
            #expect(await killed.jobs.all().count == 1)
            resumed.finish(.done)
            await killed.coordinator.awaitIdle()
            #expect(await killed.jobs.all().isEmpty)
            #expect(killed.runner.runs.count == 1)

            run.finish(.paused(.system))
            await first.coordinator.awaitIdle()
        }
    }
}
