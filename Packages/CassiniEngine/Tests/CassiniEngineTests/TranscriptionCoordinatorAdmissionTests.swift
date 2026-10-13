import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionCoordinatorTests {
    /// The notes the queue does not take for now: a recording whose audio is still being written, and a note on its
    /// way to Recently Deleted; and a trash whose write fails, which leaves the job where it was.
    @MainActor @Suite struct Admission {
        @Test func aRecordingWhoseAudioIsStillWrittenIsNotQueued() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let note = try await h.note("Voice note")
            h.coordinator.beginFinalizing(note)
            #expect(await h.coordinator.transcribe(note) == .refused(.recording))
            #expect(await h.coordinator.handOff(note) == .audioOnly)
            #expect(await h.job(note) == nil)

            // The recorder showed the note as queued; Remove from queue sets it back.
            _ = try await h.notes.mutate(note) { $0.status = .queued }
            await h.coordinator.dequeue(note)
            #expect(await h.notes.note(note)?.status == .audioOnly)

            h.coordinator.endFinalizing(note)
            #expect(await h.coordinator.transcribe(note) == .queued(changed: true))
        }

        @Test func aNoteOnItsWayToRecentlyDeletedIsNotQueuedAgain() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let note = try await h.note("Running")
            await h.coordinator.transcribe(note)
            let run = try await h.run(0)
            run.pauseOnStop = true

            let trashing = Task { await h.coordinator.trash(note) { _ in true } }
            try await h.waitUntil("the running job was asked to stop") { run.stopRequest != nil }
            #expect(await h.coordinator.transcribe(note) == .refused(.trashed), "the job is still ending")
            #expect(await trashing.value)
        }

        @Test func aTrashThatCannotBeWrittenPutsTheJobBack() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let running = try await h.note("Running"), queued = try await h.note("Queued")
            await h.coordinator.transcribe(running)
            await h.coordinator.transcribe(queued)
            _ = try await h.run(0)

            var moved: TrashedJob?
            #expect(await h.coordinator.trash(queued) { job in
                moved = job
                return false
            } == false)
            #expect(moved == TrashedJob(state: .queued, kind: .transcribe))
            try await h.waitUntil("the queued job is back") { await h.job(queued)?.state == .queued }
            try await h.settle()
            #expect(h.coordinator.state.queue == [queued], "the note stays in the queue")
            #expect(await h.coordinator.transcribe(queued) == .queued(changed: false), "it may be queued again")
        }
    }
}
