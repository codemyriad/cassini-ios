import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The worker and the outcome's checkpoint read are independently held. Only their explicit release permits
/// completion: the assertions after Stop run in its calling turn, before a worker event can acknowledge it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct TranscriptionStopAcknowledgmentTests {
    private func expectStopping(_ h: QueueHarness, _ id: UUID,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(h.coordinator.state.running?.noteID == id, sourceLocation: sourceLocation)
        #expect(h.coordinator.state.running?.phase == .stopping, sourceLocation: sourceLocation)
        #expect(h.progress.phase(for: id) == .stopping, sourceLocation: sourceLocation)
        #expect(h.progress.processingPhase(for: id) == .stopping, sourceLocation: sourceLocation)
    }

    @Test func stopAcknowledgesBeforeTheWorkerAndCheckpointOutcomeFinish() async throws {
        let checkpoints = HeldStopCheckpoints()
        let h = try QueueHarness(checkpoints: checkpoints.base, work: { _ in checkpoints })
        defer { checkpoints.release.signal(); h.tearDown() }
        try await h.start()
        let a = try await h.note("A"), b = try await h.note("B")
        await h.coordinator.transcribe(a)
        await h.coordinator.transcribe(b)
        let first = try await h.run(0)
        first.pauseOnStop = false
        defer { first.finish(.paused(.user)) }

        #expect(!h.coordinator.stop(b), "a queued note does not acknowledge a running Stop")
        #expect(first.stopRequest == nil)
        #expect(h.coordinator.stop(a))
        expectStopping(h, a)
        #expect(first.stopRequest == .pause(.user))
        #expect(h.coordinator.state.jobs[a]?.state == .running)
        #expect(h.coordinator.state.queue == [b])
        #expect(!first.hasEnded && h.runner.runs.count == 1)
        #expect(h.background.activeCount == 1, "acknowledgment does not release the worker's background time")
        #expect(h.coordinator.stop(a), "a repeated Stop is harmless while the same worker ends")
        expectStopping(h, a)

        // The persisted checkpoint marker proves all earlier events have passed the async consumer. No elapsed
        // delay or absence window establishes that those late events were delivered.
        let late: [JobEvent] = [
            .waitingForPrevious, .downloading(nil),
            .started(JobStart(totalMs: 60_000, speakers: true, prints: true)),
            .windowDone(doneMs: 28_000, totalMs: 60_000, words: []),
            .stageChanged(.speakers), .namingClosed(matching: true), .stageChanged(.saving)
        ]
        for (index, event) in late.enumerated() {
            first.send(event)
            let marker = Int64(index + 1)
            first.send(.checkpointed(doneMs: marker))
            try await h.waitUntil("the event prefix reaches the queue") { h.coordinator.state.jobs[a]?.doneMs == marker }
            expectStopping(h, a)
            #expect(!first.hasEnded && h.runner.runs.count == 1)
        }

        checkpoints.base.save(a, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
        checkpoints.hold(a)
        first.finish(.paused(.user))
        await checkpoints.entered.wait()
        expectStopping(h, a)
        #expect(h.coordinator.state.jobs[a]?.state == .running, "the outcome is not durable while its checkpoint read waits")
        #expect(h.runner.runs.count == 1, "no next worker before the previous outcome is stored")
        checkpoints.release.signal()

        let second = try await h.run(1)
        defer { second.finish(.done) }
        #expect(second.noteID == b)
        let paused = try #require(await h.job(a))
        #expect(paused.state == .paused && paused.pauseReason == .user)
        #expect(paused.doneMs == 28_000 && paused.words == 40)
        let stored = JobStore(repository: JobRepository(root: h.root))
        try await stored.load()
        #expect(await stored.job(a) == paused, "a new store reads the durable pause and checkpoint numbers")
        #expect(await h.notes.note(a)?.status == .audioOnly, "the paused job, rather than the coarse note status, owns Resume")
        second.finish(.done)
        await h.coordinator.awaitIdle()
        #expect(h.background.activeCount == 0)
    }

    @Test func stopAllAcknowledgesADownloadAndHoldsTheNextNote() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A"), b = try await h.note("B")
        await h.coordinator.transcribe(a)
        await h.coordinator.transcribe(b)
        let first = try await h.run(0)
        first.pauseOnStop = false
        defer { first.finish(.paused(.user)) }
        first.send(.downloading(nil))
        try await h.waitUntil("the job download is visible") { h.progress.phase(for: a) == .downloading(nil) }

        h.coordinator.stopAll()
        expectStopping(h, a)
        #expect(h.coordinator.state.hold == .user)
        #expect(first.stopRequest == .pause(.user))
        #expect(!first.hasEnded && h.runner.runs.count == 1)
        h.coordinator.stopAll()
        expectStopping(h, a)
        first.finish(.paused(.user))
        await h.coordinator.awaitIdle()
        #expect(await h.job(a)?.state == .paused)
        #expect(await h.job(b)?.state == .queued)
        #expect(h.coordinator.state.queue == [b] && h.runner.runs.count == 1)
        h.coordinator.continueQueue()
        let second = try await h.run(1)
        #expect(second.noteID == b)
        second.finish(.done)
        await h.coordinator.awaitIdle()
    }

    @Test(arguments: [false, true])
    func stopKeepsANewJobButDownloadCancelRestoresItsPreviousState(cancelDownload: Bool) async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let id = try await h.note("A")
        await h.coordinator.transcribe(id)
        let run = try await h.run(0)
        run.pauseOnStop = false
        defer { run.finish(.paused(.user)) }
        run.send(.downloading(nil))
        try await h.waitUntil("the download can be cancelled") { h.coordinator.state.running?.phase == .downloading(nil) }

        if cancelDownload {
            #expect(h.coordinator.cancelDownload())
            // A following Stop must not erase the download Cancel's already chosen restore policy.
            #expect(h.coordinator.stop(id))
        } else {
            #expect(h.coordinator.stop(id))
            #expect(!h.coordinator.cancelDownload(), "an acknowledged Stop cannot turn into a late download Cancel")
        }
        expectStopping(h, id)
        #expect(run.stopRequest == .pause(.user))
        #expect(h.coordinator.state.jobs[id]?.state == .running)
        run.finish(.paused(.user))
        await h.coordinator.awaitIdle()
        if cancelDownload {
            #expect(await h.job(id) == nil)
            #expect(await h.notes.note(id)?.status == .audioOnly)
        } else {
            #expect(await h.job(id)?.state == .paused)
            #expect(await h.job(id)?.pauseReason == .user)
        }
        #expect(h.checkpoints.discarded.isEmpty, "neither control discards fetched model files or saved work")
        #expect(!h.coordinator.stop(id) && !h.coordinator.cancelDownload(), "job controls do not target a standalone install")
        #expect(h.progress.noteID == nil && h.coordinator.state.running == nil)
    }

    @Test func aCompletedOutcomeWinsWithoutUndoingTheStopAcknowledgment() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let id = try await h.note("A")
        await h.coordinator.transcribe(id)
        let run = try await h.run(0)
        run.pauseOnStop = false
        defer { run.finish(.done) }
        run.send(.started(JobStart(totalMs: 60_000, speakers: false, prints: false)))
        run.send(.stageChanged(.saving))
        run.send(.checkpointed(doneMs: 1))
        try await h.waitUntil("the save stage was delivered") { h.coordinator.state.jobs[id]?.doneMs == 1 }
        #expect(h.coordinator.stop(id))
        expectStopping(h, id)
        // A sealed result can already have won. A late ended event does not make Stop look unaccepted while the
        // coordinator still owns that result, and its actual successful outcome must not become a pause.
        run.send(.ended(.done))
        run.send(.checkpointed(doneMs: 2))
        try await h.waitUntil("the completed event was delivered") { h.coordinator.state.jobs[id]?.doneMs == 2 }
        expectStopping(h, id)
        run.finish(.done)
        await h.coordinator.awaitIdle()
        #expect(await h.job(id) == nil)
        #expect(h.coordinator.state.running == nil && h.progress.noteID == nil)
    }

    @Test(arguments: [JobOutcome.done, .adoptPending])
    func aDeliveredSealedOutcomeCannotBeStoppedWhileTheRunnerStillOwnsIt(outcome: JobOutcome) async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let id = try await h.note("A")
        await h.coordinator.transcribe(id)
        let run = try await h.run(0)
        run.pauseOnStop = false
        defer { run.finish(outcome) }
        run.send(.started(JobStart(totalMs: 60_000, speakers: false, prints: false)))
        run.send(.stageChanged(.saving))
        run.send(.ended(outcome))
        run.send(.checkpointed(doneMs: 1))
        try await h.waitUntil("the sealed outcome is delivered before Stop") { h.coordinator.state.jobs[id]?.doneMs == 1 }
        let queuePhase = h.coordinator.state.running?.phase
        let progressPhase = h.progress.phase(for: id)
        #expect(!h.coordinator.stop(id), "the sealed result has already won; Stop is no longer admitted")
        #expect(run.stopRequest == nil)
        #expect(h.coordinator.state.running?.phase == queuePhase)
        #expect(h.progress.phase(for: id) == progressPhase)
        h.coordinator.stopAll()
        #expect(h.coordinator.state.hold == .user, "Stop all still holds the remaining queue")
        #expect(run.stopRequest == nil)
        #expect(h.coordinator.state.running?.phase == queuePhase)
        #expect(h.progress.phase(for: id) == progressPhase)
        run.finish(outcome)
        await h.coordinator.awaitIdle()
        #expect(await h.job(id) == nil)
    }

    @Test func aFailedOutcomeStillAcceptsStopDuringItsFallbackHandOver() async throws {
        let entered = StopTestEvent(), release = StopTestEvent()
        let h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: { _, _ in
            entered.signal()
            await release.wait()
            return "whistle"
        })
        defer { release.signal(); h.tearDown() }
        try await h.start()
        let id = try await h.note("A")
        await h.coordinator.transcribe(id)
        let run = try await h.run(0)
        run.finish(.failed(.memory))
        await entered.wait()
        #expect(h.coordinator.stop(id), "a failed run can still be stopped during fallback selection")
        expectStopping(h, id)
        #expect(run.stopRequest == .pause(.user))
        release.signal()
        await h.coordinator.awaitIdle()
        #expect(await h.job(id)?.state == .failed)
        #expect(await h.job(id)?.failure == .memory)
        #expect(h.runner.runs.count == 1, "the stopped hand-over starts no Whistle run")
    }
}

private final class StopTestEvent: Sendable {
    private struct State {
        var signalled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func signal() {
        let waiters = state.withLock { state in
            state.signalled = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let signalled = state.withLock { state in
                if state.signalled { return true }
                state.waiters.append(continuation)
                return false
            }
            if signalled { continuation.resume() }
        }
    }
}

private final class HeldStopCheckpoints: JobCheckpoints {
    let base = FakeCheckpoints()
    let entered = StopTestEvent(), release = StopTestEvent()
    private let held = Mutex<UUID?>(nil)

    func hold(_ id: UUID) { held.withLock { $0 = id } }
    func status(of id: UUID) async -> CheckpointStatus {
        if held.withLock({ $0 == id }) {
            entered.signal()
            await release.wait()
        }
        return await base.status(of: id)
    }
    func discard(_ id: UUID) async throws { try await base.discard(id) }
    func notesWithWork() async -> Set<UUID> { await base.notesWithWork() }
}
