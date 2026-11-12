import Foundation
import Observation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

enum StopStatePublication: CaseIterable, Equatable, Sendable { case running, hold, refresh, trash }

/// Call Stop only on the first callback: old code fails bounded assertions instead of overflowing its stack.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct TranscriptionStopReentrancyTests {
    @Test(arguments: StopStatePublication.allCases)
    func anObserverStopComposesWithTheOuterStatePublication(publication: StopStatePublication) async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let a = try await h.note("A"), b = try await h.note("B"), c = try await h.note("C")
        await h.coordinator.transcribe(a)
        await h.coordinator.transcribe(b)
        let run = try await h.run(0)
        run.pauseOnStop = false
        defer { run.finish(.paused(.user)) }
        try await h.waitUntil("the claim is published") { h.coordinator.state.jobs[a]?.state == .running }
        let trace = StopObserverTrace()
        withObservationTracking { _ = h.coordinator.state } onChange: {
            MainActor.assumeIsolated {
                trace.callbacks += 1
                guard trace.callbacks == 1 else { return }
                trace.accepted = h.coordinator.stop(a)
            }
        }
        switch publication {
        case .running: run.send(.started(JobStart(totalMs: 60_000, speakers: false, prints: false)))
        case .hold: h.coordinator.stopAll()
        case .refresh: await h.coordinator.transcribe(c)
        case .trash: _ = h.coordinator.moveToTrash(b)
        }
        run.send(.checkpointed(doneMs: 1))
        try await h.waitUntil("the triggering event and checkpoint are published") { h.coordinator.state.jobs[a]?.doneMs == 1 }
        #expect(trace.accepted == true)
        #expect(trace.callbacks == 1, "the observer is not recursively notified while its first callback runs")
        expectStopping(h, a)
        #expect(h.coordinator.state.jobs[a]?.state == .running)
        #expect(h.coordinator.state.jobs[a]?.doneMs == 1, "the outer publication still updates checkpoint metadata")
        if publication == .hold { #expect(h.coordinator.state.hold == .user) }
        if publication == .refresh { #expect(h.coordinator.state.queue == [b, c]) }
        if publication == .trash { #expect(!h.coordinator.state.queue.contains(b)) }
        h.coordinator.stopAll()
        run.finish(.paused(.user))
        await h.coordinator.awaitIdle()
        try await h.settle()
        #expect(await h.job(a)?.state == .paused)
    }

    @Test func aProgressObserverStopSurvivesTheOuterPhaseAssignment() async throws {
        let h = try QueueHarness(); defer { h.tearDown() }
        try await h.start()
        let id = try await h.note("A")
        await h.coordinator.transcribe(id)
        let run = try await h.run(0)
        run.pauseOnStop = false
        defer { run.finish(.paused(.user)) }
        try await h.waitUntil("the claim is published") { h.coordinator.state.jobs[id]?.state == .running }
        let trace = StopObserverTrace()
        withObservationTracking { _ = h.progress.phase } onChange: {
            MainActor.assumeIsolated {
                trace.callbacks += 1
                guard trace.callbacks == 1 else { return }
                trace.accepted = h.coordinator.stop(id)
            }
        }
        run.send(.started(JobStart(totalMs: 60_000, speakers: false, prints: false)))
        run.send(.checkpointed(doneMs: 1))
        try await h.waitUntil("the outer phase publication completes") { h.coordinator.state.jobs[id]?.doneMs == 1 }
        #expect(trace.accepted == true)
        #expect(trace.callbacks == 1)
        expectStopping(h, id)
        run.send(.windowDone(doneMs: 28_000, totalMs: 60_000, words: []))
        run.send(.checkpointed(doneMs: 2))
        try await h.waitUntil("the later window is delivered") { h.coordinator.state.jobs[id]?.doneMs == 2 }
        expectStopping(h, id)
        run.finish(.paused(.user))
        await h.coordinator.awaitIdle()
    }

    @Test func anObserverCanStopTheNewJobBeforeItsRunningSnapshotIsPublished() async throws {
        let checkpoints = NewJobStopCheckpoints()
        let h = try QueueHarness(checkpoints: checkpoints.base, work: { _ in checkpoints })
        defer { checkpoints.release.signal(); h.tearDown() }
        try await h.start()
        let a = try await h.note("A"), b = try await h.note("B")
        await h.coordinator.transcribe(a)
        await h.coordinator.transcribe(b)
        let first = try await h.run(0)
        defer { first.finish(.done) }
        await checkpoints.hold(b)
        let trace = StopObserverTrace()
        observeNewJob(h, id: b, trace: trace)
        first.finish(.done)
        // The new worker sees its Stop on entry. Keep its outcome open so both observed identities are inspectable.
        await checkpoints.entered.wait()
        #expect(trace.accepted == true && trace.callbacks == 1)
        #expect(trace.previousRunningID == nil, "Stop arrived in the new running snapshot's willSet")
        expectStopping(h, b)
        #expect(h.progress.phase(for: a) == nil)
        #expect(first.stopRequest == nil, "the new job's Stop never attaches to the previous worker")
        let second = try await h.run(1)
        #expect(second.noteID == b && second.stopRequest == .pause(.user))
        #expect(h.coordinator.state.jobs[b]?.state == .running)
        checkpoints.release.signal()
        await h.coordinator.awaitIdle()
        #expect(await h.job(a) == nil)
        #expect(await h.job(b)?.state == .paused)
    }

    private func expectStopping(_ h: QueueHarness, _ id: UUID,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(h.coordinator.state.running?.noteID == id, sourceLocation: sourceLocation)
        #expect(h.coordinator.state.running?.phase == .stopping, sourceLocation: sourceLocation)
        #expect(h.progress.phase(for: id) == .stopping, sourceLocation: sourceLocation)
        #expect(h.progress.processingPhase(for: id) == .stopping, sourceLocation: sourceLocation)
    }

    private func observeNewJob(_ h: QueueHarness, id: UUID, trace: StopObserverTrace) {
        withObservationTracking { _ = h.coordinator.state } onChange: {
            MainActor.assumeIsolated {
                guard h.coordinator.active?.noteID == id else {
                    self.observeNewJob(h, id: id, trace: trace)
                    return
                }
                trace.callbacks += 1
                guard trace.callbacks == 1 else { return }
                trace.previousRunningID = h.coordinator.state.running?.noteID
                trace.accepted = h.coordinator.stop(id)
            }
        }
    }
}

@MainActor private final class StopObserverTrace {
    var callbacks = 0
    var accepted: Bool?
    var previousRunningID: UUID?
}

private final class StopReentrancyEvent: Sendable {
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

private actor NewJobStopCheckpoints: JobCheckpoints {
    let base = FakeCheckpoints()
    let entered = StopReentrancyEvent(), release = StopReentrancyEvent()
    private var held: UUID?
    func hold(_ id: UUID) { held = id }
    func status(of id: UUID) async -> CheckpointStatus {
        if held == id {
            entered.signal()
            await release.wait()
        }
        return await base.status(of: id)
    }
    func discard(_ id: UUID) async throws { try await base.discard(id) }
    func notesWithWork() async -> Set<UUID> { await base.notesWithWork() }
}
