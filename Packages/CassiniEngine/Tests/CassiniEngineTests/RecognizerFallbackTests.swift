import Foundation
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// A Parakeet run that cannot get its memory or load its model is run again by the recognizer the app names.
@MainActor @Suite(.serialized) struct RecognizerFallbackTests {
    private static let whistleAfterParakeet: @MainActor @Sendable (Job, JobFailure) async -> String? = { job, _ in
        job.recognizer == "parakeet" ? "whistle" : nil
    }

    @Test func aRunWithoutMemoryOrModelIsRunAgainByTheFallbackFromTheStart() async throws {
        for failure in [JobFailure.memory, .model] {
            let h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: Self.whistleAfterParakeet)
            defer { h.tearDown() }
            try await h.start(visible: false)
            let id = try await h.note("English recording")
            let later = try await h.note("The next recording")
            #expect(await h.coordinator.transcribe(id) == .queued(changed: true))
            #expect(await h.coordinator.transcribe(later) == .queued(changed: true))
            let first = try await h.run(0)
            #expect(first.job.recognizer == "parakeet")
            h.checkpoints.save(id, .saved(doneMs: 28_000, totalMs: 60_000, words: 40), recognizer: "parakeet")
            first.finish(.failed(failure))

            // The same note runs next, before the note queued behind it, with the other recognizer and no progress.
            let second = try await h.run(1)
            #expect(second.noteID == id)
            #expect(second.job.recognizer == "whistle")
            #expect(second.job.doneMs == 0 && second.job.words == 0 && second.job.totalMs == nil)
            #expect(second.job.failure == nil)
            #expect(h.checkpoints.discarded == [id], "Parakeet's saved progress is not left for Whistle to refuse")
            #expect(await h.notes.note(id)?.failure == nil)
            #expect(h.notifier.posted.isEmpty, "a run handed over has not failed")

            second.finish(.done)
            let third = try await h.run(2)
            #expect(third.noteID == later)
            #expect(third.job.recognizer == "parakeet", "the fallback is for one note: the next keeps the selection")
            #expect(await h.job(id) == nil)
            third.finish(.done)
            await h.coordinator.awaitIdle()
        }
    }

    @Test func theFallbackRunFailsAsItIsWhenItFailsToo() async throws {
        let h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: Self.whistleAfterParakeet)
        defer { h.tearDown() }
        try await h.start(visible: false)
        let id = try await h.note("English recording")
        #expect(await h.coordinator.transcribe(id) == .queued(changed: true))
        try await h.run(0).finish(.failed(.memory))
        let second = try await h.run(1)
        #expect(second.job.recognizer == "whistle")
        second.finish(.failed(.memory))
        await h.coordinator.awaitIdle()
        let job = try #require(await h.job(id))
        #expect(job.state == .failed && job.failure == .memory && job.recognizer == "whistle")
        #expect(await h.notes.note(id)?.failure == .memory)
        #expect(h.runner.runs.count == 2, "no third run")
        #expect(h.notifier.posted.map(\.noteID) == [id], "the failure is told once, when the note has failed")
    }

    @Test func otherFailuresSpeakerJobsAndJobsWithoutAFallbackFail() async throws {
        // A failure that another recognizer would meet too.
        var h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: Self.whistleAfterParakeet)
        try await h.start(visible: false)
        var id = try await h.note("English recording")
        #expect(await h.coordinator.transcribe(id) == .queued(changed: true))
        h.checkpoints.save(id, .saved(doneMs: 28_000, totalMs: 60_000, words: 40), recognizer: "parakeet")
        try await h.run(0).finish(.failed(.open))
        await h.coordinator.awaitIdle()
        #expect(await h.job(id)?.state == .failed)
        #expect(await h.job(id)?.recognizer == "parakeet")
        #expect(h.checkpoints.discarded.isEmpty, "Try again continues from the saved progress")
        h.tearDown()

        // Nothing to fall back to.
        h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: { _, _ in nil })
        try await h.start(visible: false)
        id = try await h.note("English recording")
        #expect(await h.coordinator.transcribe(id) == .queued(changed: true))
        try await h.run(0).finish(.failed(.memory))
        await h.coordinator.awaitIdle()
        #expect(await h.job(id)?.state == .failed)
        #expect(await h.job(id)?.failure == .memory)
        #expect(h.runner.runs.count == 1)
        h.tearDown()

        // The speakers of an existing transcript: no recognizer runs, so none takes over.
        h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: { _, _ in "whistle" })
        defer { h.tearDown() }
        try await h.start(visible: false)
        id = try await h.note("English recording")
        try await h.jobs.enqueue(id, kind: .speakersOnly, language: "en-US", now: h.clock.now, recognizer: "parakeet")
        h.coordinator.drain()
        try await h.run(0).finish(.failed(.memory))
        await h.coordinator.awaitIdle()
        #expect(await h.job(id)?.state == .failed)
        #expect(await h.job(id)?.recognizer == "parakeet")
    }

    @Test func aRunWhoseProgressCannotBeDiscardedFails() async throws {
        let h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: Self.whistleAfterParakeet)
        defer { h.tearDown() }
        try await h.start(visible: false)
        let id = try await h.note("English recording")
        #expect(await h.coordinator.transcribe(id) == .queued(changed: true))
        let first = try await h.run(0)
        h.checkpoints.failDiscard = true
        first.finish(.failed(.memory))
        await h.coordinator.awaitIdle()
        let job = try #require(await h.job(id))
        #expect(job.state == .failed && job.failure == .memory && job.recognizer == "parakeet")
        #expect(h.runner.runs.count == 1)
    }

    @Test func onlyMemoryAndModelFailuresCanBeHandedOver() {
        for failure in JobFailure.allCases {
            #expect(RecognizerFallback.applies(to: failure) == (failure == .memory || failure == .model), "\(failure)")
        }
    }
}
