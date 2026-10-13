import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionCoordinatorTests {
    /// The launch repair: a queue file that cannot be read, and a restart.
    @MainActor @Suite struct Launch {
        // MARK: A queue file that cannot be read

        @Test func anUnreadableQueueFileIsKeptAsideAndTheQueueStartsEmpty() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            var note = Note(title: "Was queued", audioFilename: "audio.m4a")
            note.status = .queued
            try await h.notes.save(note)
            h.checkpoints.save(note.id, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            let broken = Data("{\"version\":1,\"jobs\":[{".utf8)
            try broken.write(to: h.root.appendingPathComponent(JobRepository.filename))

            await #expect(throws: JobStore.Failure.self) { try await h.start() }
            guard case .unreadable(let aside?) = h.coordinator.loadFailure else {
                Issue.record("the file was not moved aside")
                return
            }
            #expect(try Data(contentsOf: aside) == broken)
            #expect(h.checkpoints.hasWork(note.id), "no saved progress is deleted without the queue")
            #expect(await h.notes.note(note.id)?.status == .audioOnly, "the note no longer says it is queued")
            let paused = try #require(await h.job(note.id), "the saved progress is a paused job again")
            #expect(paused.state == .paused && paused.pauseReason == .user)
            #expect(paused.doneMs == 28_000 && paused.totalMs == 60_000 && paused.words == 40)

            // The next launch reads the rebuilt queue: the work is owned, so it stays, and the note shows its progress.
            let next = try h.reopened()
            try await next.start()
            #expect(next.checkpoints.hasWork(note.id), "the saved progress outlives the launch after the damage")
            #expect(next.coordinator.state.jobs[note.id]?.state == .paused)
            #expect(next.coordinator.state.jobs[note.id]?.doneMs == 28_000)

            #expect(await next.coordinator.transcribe(note.id) == .queued(changed: true))
            let resumed = try await next.run(0)
            #expect(resumed.noteID == note.id)
            #expect(resumed.job.doneMs == 28_000, "Resume goes on from the saved progress")
            #expect(try Data(contentsOf: aside) == broken)
        }

        @Test func aQueueFileFromANewerCassiniIsNeverOverwritten() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
            let file = h.root.appendingPathComponent(JobRepository.filename)
            let newer = Data(#"{"version":2,"jobs":[]}"#.utf8)
            try newer.write(to: file)
            let a = try await h.note("A")
            h.checkpoints.addWork(a)

            await #expect(throws: JobStore.Failure.newerVersion(2)) { try await h.start() }
            #expect(h.coordinator.loadFailure == .newerVersion(2))
            #expect(await h.coordinator.transcribe(a) == .refused(.queueUnavailable))
            await h.coordinator.restore(a, trashedJob: TrashedJob(state: .queued, kind: .transcribe))
            try await h.settle()
            #expect(h.runner.runs.isEmpty)
            #expect(try Data(contentsOf: file) == newer)
            #expect(h.checkpoints.hasWork(a))
        }

        @Test func aRepairThatCannotBeSavedLetsTheInterruptedJobRunAgain() async throws {
            let first = try QueueHarness(); defer { first.tearDown() }
            try await first.start()
            let a = try await first.note("A")
            try JobRepository(root: first.root).save([
                Job(noteID: a, seq: 1, kind: .transcribe, state: .running, enqueuedAt: first.clock.now),
            ])

            let h = try first.reopened()
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.root.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.root.path) }
            try await h.start(visible: false)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.root.path)
            #expect(h.coordinator.state.queue == [a], "the job is queued again in memory")

            h.coordinator.setVisible(true)
            #expect(try await h.run(0).noteID == a, "the queue is not stuck on a job that no longer runs")
            #expect(try JobRepository(root: h.root).load().map(\.state) == [.running])
        }

        // MARK: Restart

        // ports: ProcessingCoordinatorTest#aRestartRequeuesRunningRowsAndPausesOnesPastTheirAttempts
        @Test func aRestartRequeuesRunningJobsAndPausesOnesPastTheirAttempts() async throws {
            let first = try QueueHarness(); defer { first.tearDown() }
            try await first.start()
            let withCheckpoint = try await first.note("Checkpoint"), bare = try await first.note("Bare")
            let third = try await first.note("Third"), pausedBare = try await first.note("Paused")
            first.checkpoints.save(withCheckpoint, .saved(doneMs: 28_000, totalMs: 60_000, words: 40))
            let now = first.clock.now
            try JobRepository(root: first.root).save([
                Job(noteID: withCheckpoint, seq: 1, kind: .transcribe, state: .running, enqueuedAt: now),
                Job(noteID: bare, seq: 2, kind: .transcribe, state: .running, enqueuedAt: now),
                Job(noteID: third, seq: 3, kind: .transcribe, state: .running, attempts: 2, enqueuedAt: now),
                Job(noteID: pausedBare, seq: 4, kind: .transcribe, state: .paused, pauseReason: .user, doneMs: 12_000,
                    enqueuedAt: now),
            ])

            // Cassini closed: a new launch over the same files, not on the screen.
            let h = try first.reopened()
            try await h.start(visible: false)
            let state = h.coordinator.state
            #expect(state.queue == [withCheckpoint, bare])
            #expect(state.jobs[withCheckpoint]?.doneMs == 28_000)
            #expect(state.jobs[bare]?.doneMs == 0)
            #expect(state.jobs[bare]?.attempts == 1)
            #expect(state.jobs[third]?.pauseReason == .interrupted)
            #expect(state.jobs[pausedBare]?.state == .paused)
            #expect(state.jobs[pausedBare]?.doneMs == 0, "a paused job without saved progress starts from 0")
            #expect(h.notifier.posted.map(\.noteID) == [third])
            #expect(h.notifier.posted.first?.kind == .transcriptionStopped)
            try await h.settle()
            #expect(h.runner.runs.isEmpty, "nothing starts while Cassini is not on the screen")

            // On the screen: the queue starts, the job with saved progress first.
            h.coordinator.setVisible(true)
            #expect(try await h.run(0).noteID == withCheckpoint)
            try await h.run(0).finish(.done)
            #expect(try await h.run(1).noteID == bare)
            try await h.run(1).finish(.done)
            await h.coordinator.awaitIdle()
            #expect(h.runner.runs.count == 2, "paused jobs never resume on their own")
        }

        // ports: ProcessingCoordinatorTest#aVisibleAppStartsAWaitingQueueWithoutAnyReadOfTheCoordinator
        @Test func aVisibleAppStartsAWaitingQueueAtLaunch() async throws {
            let first = try QueueHarness(); defer { first.tearDown() }
            try await first.start()
            let id = try await first.note("Waiting")
            try JobRepository(root: first.root).save([Job(noteID: id, seq: 1, kind: .transcribe, enqueuedAt: first.clock.now)])

            let h = try first.reopened()
            try await h.start(visible: true)
            #expect(try await h.run(0).noteID == id)
            try await h.run(0).finish(.done)
            await h.coordinator.awaitIdle()
            #expect(h.runner.runs.count == 1)
        }

        @Test func aNoteThatSaysItWasTranscribingWithoutAJobIsSetBack() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            var note = Note(title: "Older queue", audioFilename: "audio.m4a")
            note.status = .transcribing
            note.transcript = [TranscriptSegment(text: "Keep this.", start: 0, end: 1)]
            try await h.notes.save(note)
            h.checkpoints.addWork(note.id)
            let report = try await h.start()
            let stored = try #require(await h.notes.note(note.id))
            #expect(stored.status == .ready)
            #expect(stored.failure == .interrupted)
            #expect(report.deletedWork == [note.id])
        }
    }
}
