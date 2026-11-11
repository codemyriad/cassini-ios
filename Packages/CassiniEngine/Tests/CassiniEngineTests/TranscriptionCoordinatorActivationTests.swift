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

        // MARK: Activation and the system's Stop meeting

        /// A runs with saved progress and iOS takes the background time back, but the pause of A is not written yet:
        /// its write waits in the queue's serial section until the test calls `release`. The run of A has not ended
        /// either, as when iOS suspends Cassini right after the handler.
        private func systemStopInFlight(_ h: QueueHarness) async throws -> (a: UUID, run: FakeJobRun, release: () -> Void) {
            try await h.start()
            let a = try await h.note("A")
            await h.coordinator.transcribe(a)
            let run = try await h.run(0)
            run.pauseOnStop = false
            h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            h.checkpoints.hold(a)
            h.coordinator.setVisible(false)
            h.background.expireAll()
            #expect(h.settings.queueHold == .system)
            try await h.waitUntil("the pause write holds the serial section") { h.sectionBusy }
            #expect(await h.job(a)?.state == .running, "the pause is not written yet")
            return (a, run, { h.checkpoints.release(a) })
        }

        /// Starts an activation and waits until it has either returned or waits behind the pause write.
        private func activate(_ h: QueueHarness, _ platform: PlatformFacts, waiting: Int = 1) async throws -> Task<[UUID], Never> {
            let returned = Flag()
            let activation = Task { @MainActor in
                defer { returned.raise() }
                return await h.coordinator.resumeSystemPause(onActivationOf: platform)
            }
            try await h.waitUntil("the activation returned or waits for the pause") {
                returned.raised || h.sectionWaiting >= waiting
            }
            return activation
        }

        /// Codex re-review of #73: the activation read A as running, found nothing paused and cleared the hold; the
        /// late pause then left A paused by the system with no hold, which no later activation resumes.
        @Test func anActivationBeforeTheSystemPauseIsWrittenResumesTheJobFromItsCheckpoint() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, run, release) = try await systemStopInFlight(h)

            h.coordinator.setVisible(true)
            let activation = try await activate(h, .iOS18)
            release()
            run.finish(.paused(.system))
            await h.coordinator.waitForJob(of: a)
            let resumed = await activation.value

            let job = try #require(await h.job(a))
            #expect(h.settings.queueHold == nil)
            try #require(job.state != .paused, "A must never stay paused by the system with no hold: no activation would resume it")
            #expect(resumed == [a])
            let again = try await h.run(1)
            #expect(again.noteID == a)
            #expect(again.job.doneMs == 28_000, "from its checkpoint")
            again.finish(.done)
            await h.coordinator.awaitIdle()
            #expect(await h.jobs.all().isEmpty)
            #expect(h.runner.runs.count == 2)
        }

        @Test func twoActivationsBeforeTheSystemPauseIsWrittenResumeTheJobOnce() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, run, release) = try await systemStopInFlight(h)

            h.coordinator.setVisible(true)
            let first = try await activate(h, .iOS18)
            let second = try await activate(h, .iOS18, waiting: 2)
            release()
            run.finish(.paused(.system))
            await h.coordinator.waitForJob(of: a)
            let results = [await first.value, await second.value]

            let job = try #require(await h.job(a))
            #expect(h.settings.queueHold == nil)
            try #require(job.state != .paused, "A must never stay paused by the system with no hold")
            #expect(results.filter { $0 == [a] }.count == 1, "one activation resumes A: \(results)")
            let again = try await h.run(1)
            #expect(again.noteID == a)
            again.finish(.done)
            await h.coordinator.awaitIdle()
            #expect(await h.jobs.all().isEmpty)
            #expect(h.runner.runs.count == 2)
        }

        @Test func onIOS26AnActivationBeforeTheSystemPauseIsWrittenKeepsTheHold() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, run, release) = try await systemStopInFlight(h)

            h.coordinator.setVisible(true)
            let activation = try await activate(h, .iOS26)
            release()
            run.finish(.paused(.system))
            await h.coordinator.waitForJob(of: a)
            #expect(await activation.value == [])
            await h.coordinator.awaitIdle()
            try await h.settle()
            #expect(h.settings.queueHold == .system)
            let job = try #require(await h.job(a))
            #expect(job.state == .paused && job.pauseReason == .system)
            #expect(h.runner.runs.count == 1)
        }

        /// Claude re-review of #73: two quick activations both read the paused job; only one may resume it.
        @Test func twoConcurrentActivationsResumeTheJobOnce() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, b) = try await pausedBySystem(h)

            h.coordinator.setVisible(true)
            async let first = h.coordinator.resumeSystemPause(onActivationOf: .iOS18)
            async let second = h.coordinator.resumeSystemPause(onActivationOf: .iOS18)
            let results = await [first, second]
            #expect(results.filter { $0 == [a] }.count == 1, "one activation resumes A: \(results)")
            #expect(results.filter { $0 == [] }.count == 1)
            try await h.run(1).finish(.done)
            let again = try await h.run(2)
            #expect(again.noteID == a)
            again.finish(.done)
            await h.coordinator.awaitIdle()
            #expect(await h.jobs.all().isEmpty)
            #expect(h.runner.runs.map(\.noteID) == [a, b, a])
        }

        @Test func backToBackActivationsResumeTheJobOnce() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, b) = try await pausedBySystem(h)

            h.coordinator.setVisible(true)
            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [a])
            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [])
            try await h.run(1).finish(.done)
            try await h.run(2).finish(.done)
            await h.coordinator.awaitIdle()
            #expect(await h.jobs.all().isEmpty)
            #expect(h.runner.runs.map(\.noteID) == [a, b, a])
        }

        /// A runs with saved progress and iOS takes the background time back: A is paused by the system, but its run
        /// has not ended yet, so a Resume of A waits for it. Then Cassini comes to the screen and the activation claims
        /// the resume of A; it waits for the old run until the test ends it.
        private func activationWaitingForTheOldRun(_ h: QueueHarness) async throws
            -> (a: UUID, run: FakeJobRun, activation: Task<[UUID], Never>) {
            try await h.start()
            let a = try await h.note("A")
            await h.coordinator.transcribe(a)
            let run = try await h.run(0)
            run.pauseOnStop = false
            h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            h.coordinator.setVisible(false)
            h.background.expireAll()
            try await h.waitUntil("A is paused by the system") { await h.job(a)?.pauseReason == .system }

            h.coordinator.setVisible(true)
            let activation = Task { await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) }
            try await h.waitUntil("the activation claimed the resume") { h.activationClaimed }
            return (a, run, activation)
        }

        /// The mirror case: iOS takes the time back again while the activation waits for A's old run to end. The new
        /// system hold stays, so A waits in the queue for the next activation instead of running without it.
        @Test func aSystemStopDuringTheActivationKeepsItsHold() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, run, activation) = try await activationWaitingForTheOldRun(h)
            h.coordinator.setVisible(false)
            h.coordinator.systemStop()
            run.finish(.paused(.system))
            #expect(await activation.value == [a])
            await h.coordinator.awaitIdle()
            try await h.settle()
            #expect(h.settings.queueHold == .system)
            #expect(await h.job(a)?.state == .queued)
            #expect(h.runner.runs.count == 1)

            h.coordinator.setVisible(true)
            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [])
            let again = try await h.run(1)
            #expect(again.job.doneMs == 28_000)
            again.finish(.done)
            await h.coordinator.awaitIdle()
            #expect(await h.jobs.all().isEmpty)
            #expect(h.runner.runs.count == 2)
        }

        /// The person's Stop while the activation waits: the user hold stays when the activation ends.
        @Test func aUserStopDuringTheActivationKeepsItsHold() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, run, activation) = try await activationWaitingForTheOldRun(h)
            h.coordinator.stopAll()
            run.finish(.paused(.system))
            #expect(await activation.value == [a])
            await h.coordinator.awaitIdle()
            try await h.settle()
            #expect(h.settings.queueHold == .user)
            #expect(await h.job(a)?.state == .queued)
            #expect(h.runner.runs.count == 1)
        }

        /// Review of #101: iOS kills Cassini while the activation waits for A's old run. The stored hold and the stored
        /// job must still say that A waits for an activation, so the next launch resumes it once, from its checkpoint.
        @Test func aKillWhileTheActivationWaitsLeavesTheResumeForTheNextLaunch() async throws {
            let first = try QueueHarness(); defer { first.tearDown() }
            let (a, run, activation) = try await activationWaitingForTheOldRun(first)
            let killed = try QueueHarness.snapshot(of: first)
            defer { killed.tearDown() }

            try await killed.start(visible: true)
            let storedHold = killed.settings.queueHold, storedJob = await killed.job(a)
            let resumedOnLaunch = await killed.coordinator.resumeSystemPause(onActivationOf: .iOS18)
            try #require(resumedOnLaunch == [a], "the next launch's activation resumes A (stored hold: \(String(describing: storedHold)), job: \(String(describing: storedJob?.state)) \(String(describing: storedJob?.pauseReason)))")
            let resumed = try await killed.run(0)
            #expect(resumed.job.doneMs == 28_000, "from its checkpoint")
            #expect(await killed.jobs.all().count == 1)
            resumed.finish(.done)
            await killed.coordinator.awaitIdle()
            #expect(await killed.jobs.all().isEmpty)
            #expect(killed.runner.runs.count == 1)
            #expect(killed.settings.queueHold == nil)

            // The killed process, had it gone on, would have resumed A itself: end that run too.
            run.finish(.paused(.system))
            #expect(await activation.value == [a])
            try await first.run(1).finish(.done)
            await first.coordinator.awaitIdle()
        }

        /// Third review of #101: the activation's requeue of A cannot be saved (`jobs.json` cannot be written, as on a
        /// full disk). A must not count as resumed and the stored system hold must stay, so that once the queue can be
        /// written again the next activation resumes A once, from its checkpoint.
        @Test func aRequeueThatCannotBeSavedKeepsTheHoldForTheNextActivation() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, b) = try await pausedBySystem(h)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.root.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.root.path) }

            h.coordinator.setVisible(true)
            let failed = await h.coordinator.resumeSystemPause(onActivationOf: .iOS18)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.root.path)
            #expect(failed == [], "A was not queued again")
            #expect(h.settings.queueHold == .system, "the hold still says that A waits for an activation")
            #expect(try JobRepository(root: h.root).load().first { $0.noteID == a }?.pauseReason == .system)
            try await h.settle()
            #expect(h.runner.runs.count == 1)

            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [a])
            #expect(h.settings.queueHold == nil)
            try await h.run(1).finish(.done)
            let again = try await h.run(2)
            #expect(again.noteID == a)
            #expect(again.job.doneMs == 28_000, "from its checkpoint")
            again.finish(.done)
            await h.coordinator.awaitIdle()
            #expect(await h.jobs.all().isEmpty)
            #expect(h.runner.runs.map(\.noteID) == [a, b, a])
        }

        /// The same failed save, then Cassini is closed: the next launch's activation resumes A once, from its checkpoint.
        @Test func aRequeueThatCannotBeSavedLeavesTheResumeForTheNextLaunch() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, b) = try await pausedBySystem(h)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.root.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.root.path) }
            h.coordinator.setVisible(true)
            _ = await h.coordinator.resumeSystemPause(onActivationOf: .iOS18)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.root.path)
            try await h.settle()

            let next = try QueueHarness.snapshot(of: h)
            defer { next.tearDown() }
            try await next.start(visible: true)
            try #require(await next.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [a],
                         "the next launch resumes A")
            try await next.run(0).finish(.done)
            let resumed = try await next.run(1)
            #expect(resumed.noteID == a)
            #expect(resumed.job.doneMs == 28_000, "from its checkpoint")
            resumed.finish(.done)
            await next.coordinator.awaitIdle()
            #expect(await next.jobs.all().isEmpty)
            #expect(next.runner.runs.map(\.noteID) == [b, a])
        }

        /// Round-4 review of #101: the system stop's pause of A cannot be saved (`jobs.json` cannot be written), so A
        /// is still stored as running. The activation must not take that for "nothing paused" and clear the hold: once
        /// the queue can be written again, the old run's own outcome stores A as paused by the system, and only the
        /// hold makes an activation resume it. Returns once that outcome is stored.
        private func pauseWriteFailedThenOldRunEnded(_ h: QueueHarness) async throws -> UUID {
            try await h.start()
            let a = try await h.note("A")
            await h.coordinator.transcribe(a)
            let run = try await h.run(0)
            run.pauseOnStop = false
            h.checkpoints.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.root.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.root.path) }
            h.coordinator.setVisible(false)
            h.background.expireAll()
            try await h.waitUntil("the system stop's pause write ran") { !h.systemStopPending }
            #expect(await h.job(a)?.state == .running, "the pause could not be saved")

            h.coordinator.setVisible(true)
            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [])
            #expect(h.settings.queueHold == .system, "the hold stays while A's system stop is not stored")
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.root.path)
            run.finish(.paused(.system))
            await h.coordinator.waitForJob(of: a)
            let job = try #require(await h.job(a))
            #expect(job.state == .paused && job.pauseReason == .system, "the old run's outcome is stored")
            try await h.settle()
            return a
        }

        @Test func aPauseWriteThatFailsKeepsTheHoldUntilTheJobsOutcomeIsStored() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let a = try await pauseWriteFailedThenOldRunEnded(h)
            try #require(h.settings.queueHold == .system, "the stored hold still says that A waits for an activation")
            #expect(h.runner.runs.count == 1)

            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [a])
            let again = try await h.run(1)
            #expect(again.noteID == a)
            #expect(again.job.doneMs == 28_000, "from its checkpoint")
            again.finish(.done)
            await h.coordinator.awaitIdle()
            #expect(await h.jobs.all().isEmpty)
            #expect(h.runner.runs.count == 2)
            #expect(h.settings.queueHold == nil)
        }

        @Test func aPauseWriteThatFailsLeavesTheResumeForTheNextLaunch() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let a = try await pauseWriteFailedThenOldRunEnded(h)

            let next = try QueueHarness.snapshot(of: h)
            defer { next.tearDown() }
            try await next.start(visible: true)
            let storedHold = next.settings.queueHold
            let resumedOnLaunch = await next.coordinator.resumeSystemPause(onActivationOf: .iOS18)
            try #require(resumedOnLaunch == [a], "the next launch resumes A (stored hold: \(String(describing: storedHold)))")
            let resumed = try await next.run(0)
            #expect(resumed.job.doneMs == 28_000, "from its checkpoint")
            resumed.finish(.done)
            await next.coordinator.awaitIdle()
            #expect(await next.jobs.all().isEmpty)
            #expect(next.runner.runs.count == 1)
        }

        /// A job that cannot be queued again without the model download's consent: it waits as "Ready to transcribe",
        /// and the system hold is cleared so the rest of the queue goes on.
        @Test func aResumeThatNeedsConsentClearsTheHoldAndLeavesTheJobReady() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, b) = try await pausedBySystem(h)
            h.consented = false

            h.coordinator.setVisible(true)
            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [])
            #expect(h.settings.queueHold == nil)
            #expect(await h.job(a)?.state == .needsConsent)
            #expect(try await h.run(1).noteID == b)
        }

        /// A job that cannot be queued again at all: it stays paused for Resume, and the system hold is cleared so
        /// it never keeps the rest of the queue waiting.
        @Test func aRefusedResumeClearsTheHoldAndLeavesTheJobPaused() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            let (a, b) = try await pausedBySystem(h)
            h.speechFailure = .unsupportedLanguage

            h.coordinator.setVisible(true)
            #expect(await h.coordinator.resumeSystemPause(onActivationOf: .iOS18) == [])
            #expect(h.settings.queueHold == nil)
            let job = try #require(await h.job(a))
            #expect(job.state == .paused && job.pauseReason == .system)
            #expect(try await h.run(1).noteID == b)
        }
    }
}

/// Raised once, read from the main actor.
@MainActor private final class Flag {
    private(set) var raised = false
    func raise() { raised = true }
}
