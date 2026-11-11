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
            h.checkpoints.addWork(id) // a `work/` folder with nothing a person made in it
            first.finish(.failed(failure))

            // The same note runs next, before the note queued behind it, with the other recognizer and no progress.
            let second = try await h.run(1)
            #expect(second.noteID == id)
            #expect(second.job.recognizer == "whistle")
            #expect(second.job.doneMs == 0 && second.job.words == 0 && second.job.totalMs == nil)
            #expect(second.job.failure == nil)
            #expect(h.checkpoints.discarded.isEmpty && h.checkpoints.hasWork(id), "the hand-over deletes nothing")
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

    /// Saved progress cannot be continued by another recognizer, and the draft's speaker names live beside it: a run
    /// with either fails as it is, and Try again continues it.
    @Test func aRunWithSavedProgressOrDraftNamesFailsAndKeepsThem() async throws {
        for names in [false, true] {
            let h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: Self.whistleAfterParakeet)
            defer { h.tearDown() }
            try await h.start(visible: false)
            let id = try await h.note("English recording")
            #expect(await h.coordinator.transcribe(id) == .queued(changed: true))
            let first = try await h.run(0)
            if names { h.checkpoints.addNames(id) }
            else { h.checkpoints.save(id, .saved(doneMs: 28_000, totalMs: 60_000, words: 40), recognizer: "parakeet") }
            first.finish(.failed(.memory))
            await h.coordinator.awaitIdle()
            let job = try #require(await h.job(id))
            #expect(job.state == .failed && job.failure == .memory && job.recognizer == "parakeet")
            #expect(h.runner.runs.count == 1)
            #expect(h.checkpoints.discarded.isEmpty && h.checkpoints.hasWork(id))
        }
    }

    /// The same over real `work/` files: a checkpoint and a `names.json` with a name and a merge the person made
    /// during the Parakeet run are still there, byte for byte, after the run fails with `MEMORY`; a note whose
    /// `names.json` holds only what a fresh run writes is handed over, and that file stays too.
    @Test func realWorkFilesWithADraftAreKeptAndAFreshRunsAreHandedOver() async throws {
        let draftsBox = Box<DraftNamesStore>()
        let h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: Self.whistleAfterParakeet, work: { notes in
            let drafts = DraftNamesStore(notes: notes)
            draftsBox.value = drafts
            return NoteWorkFolders(notes: notes, drafts: drafts)
        })
        defer { h.tearDown() }
        let drafts = try #require(draftsBox.value)
        let files = CheckpointFiles(notes: h.notes)
        try await h.start(visible: false)
        let named = try await h.note("Named during the run")
        let fresh = try await h.note("Failed before its first window")
        #expect(await h.coordinator.transcribe(named) == .queued(changed: true))
        #expect(await h.coordinator.transcribe(fresh) == .queued(changed: true))

        let first = try await h.run(0)
        #expect(first.noteID == named)
        let audio = h.root.appendingPathComponent(named.uuidString).appendingPathComponent("audio.m4a")
        try Data([1, 2]).write(to: audio)
        try files.save(CheckpointState(source: "audio.m4a", signature: CheckpointState.signature(of: audio),
                                       model: SpeechRecognizer.parakeet.checkpointModel(language: "en-US"),
                                       segments: [TranscriptSegment(text: "Hello there", start: 0, end: 1,
                                                                    words: [.init(text: "Hello", start: 0, end: 0.5),
                                                                            .init(text: " there", start: 0.5, end: 1)])],
                                       doneMs: 28_000, totalMs: 60_000, elapsedMs: 10), for: named)
        drafts.mutate(named) { _ in DraftNames(generation: 3) }
        drafts.mutate(named) { $0.rename("speaker_0", "Ada") }
        try drafts.mutate(named) { try $0.merge("speaker_2", into: "speaker_1") }
        let work = files.directory(for: named)
        let before = try Self.contents(of: work)
        #expect(before.keys.contains(CheckpointFiles.filename) && before.keys.contains(DraftNamesStore.filename))
        first.finish(.failed(.memory))

        // The named note failed, so the next run is the other note's own Parakeet run.
        let second = try await h.run(1)
        #expect(second.noteID == fresh && second.job.recognizer == "parakeet")
        let job = try #require(await h.job(named))
        #expect(job.state == .failed && job.failure == .memory && job.recognizer == "parakeet")
        #expect(try Self.contents(of: work) == before, "nothing in work/ changed")
        #expect(drafts.current(named).labels == ["speaker_0": "Ada"])
        #expect(drafts.current(named).merges == ["speaker_2": "speaker_1"])
        #expect(await NoteWorkFolders(notes: h.notes, drafts: drafts).status(of: named)
                == .saved(doneMs: 28_000, totalMs: 60_000, words: 2))

        // What a fresh streaming run writes before its first window: the names of nobody, in today's generation.
        drafts.mutate(fresh) { _ in DraftNames(generation: 3) }
        let freshWork = try Self.contents(of: files.directory(for: fresh))
        #expect(freshWork.keys.sorted() == [DraftNamesStore.filename])
        second.finish(.failed(.memory))
        let third = try await h.run(2)
        #expect(third.noteID == fresh && third.job.recognizer == "whistle")
        #expect(try Self.contents(of: files.directory(for: fresh)) == freshWork)
        third.finish(.done)
        await h.coordinator.awaitIdle()
    }

    /// "Stop and keep progress" pressed while the fallback is being chosen: the choice is held open by the test, the
    /// stop arrives, the choice returns. No Whistle run starts; the job fails as its own run ended.
    @Test func aStopDuringTheHandOverLeavesTheJobFailedAndStartsNoNewRun() async throws {
        let (entered, enter) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        let h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: { _, _ in
            enter.yield()
            for await _ in released { break }
            return "whistle"
        })
        defer { h.tearDown() }
        try await h.start(visible: false)
        let id = try await h.note("English recording")
        #expect(await h.coordinator.transcribe(id) == .queued(changed: true))
        try await h.run(0).finish(.failed(.memory))
        for await _ in entered { break }
        #expect(h.coordinator.stop(id), "the note still shows as running, so its Stop is offered")
        release.yield()
        await h.coordinator.awaitIdle()
        let job = try #require(await h.job(id))
        #expect(job.state == .failed && job.failure == .memory && job.recognizer == "parakeet")
        #expect(await h.notes.note(id)?.failure == .memory)
        #expect(h.runner.runs.count == 1, "no Whistle run")
        #expect(h.notifier.posted.map(\.noteID) == [id], "the failure is told, as without a fallback")
    }

    /// The same with Stop from outside the note, which also holds the queue, and with a stop from before the run ended.
    @Test func aStopFromOutsideOrFromBeforeTheRunEndedAlsoPreventsTheHandOver() async throws {
        let (entered, enter) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        var h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: { _, _ in
            enter.yield()
            for await _ in released { break }
            return "whistle"
        })
        try await h.start(visible: false)
        var id = try await h.note("English recording")
        #expect(await h.coordinator.transcribe(id) == .queued(changed: true))
        try await h.run(0).finish(.failed(.model))
        for await _ in entered { break }
        h.coordinator.stopAll()
        release.yield()
        await h.coordinator.awaitIdle()
        #expect(await h.job(id)?.state == .failed)
        #expect(await h.job(id)?.failure == .model)
        #expect(await h.job(id)?.recognizer == "parakeet")
        #expect(h.settings.queueHold == .user)
        #expect(h.runner.runs.count == 1)
        h.tearDown()

        let asked = Box<Bool>()
        h = try QueueHarness(recognizer: "parakeet", fallbackRecognizer: { _, _ in asked.value = true; return "whistle" })
        defer { h.tearDown() }
        try await h.start(visible: false)
        id = try await h.note("English recording")
        #expect(await h.coordinator.transcribe(id) == .queued(changed: true))
        let run = try await h.run(0)
        #expect(h.coordinator.stop(id))
        run.finish(.failed(.memory))
        await h.coordinator.awaitIdle()
        #expect(await h.job(id)?.state == .failed)
        #expect(await h.job(id)?.recognizer == "parakeet")
        #expect(asked.value == nil, "no fallback is chosen for a job that was asked to stop")
        #expect(h.runner.runs.count == 1)
    }

    private static func contents(of folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            result[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return result
    }

    @MainActor private final class Box<Value> { var value: Value? }

    @Test func onlyMemoryAndModelFailuresCanBeHandedOver() {
        for failure in JobFailure.allCases {
            #expect(RecognizerFallback.applies(to: failure) == (failure == .memory || failure == .model), "\(failure)")
        }
    }
}
