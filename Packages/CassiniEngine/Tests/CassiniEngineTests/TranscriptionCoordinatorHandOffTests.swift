import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionCoordinatorTests {
    /// Consent, the hand-off of a saved recording, and the language a job is queued with.
    @MainActor @Suite struct HandOff {
        // ports: ProcessingCoordinatorTest#withoutConsentTranscribeEndsNeedsConsentWithoutAnyJobOrNetwork
        @Test func withoutConsentTranscribeEndsReadyToTranscribeWithoutAnyJobRun() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            h.consented = false
            try await h.start()
            let a = try await h.note("A")

            #expect(await h.coordinator.transcribe(a) == .needsConsent)
            #expect(await h.job(a)?.state == .needsConsent)
            h.coordinator.drain()
            await h.coordinator.awaitIdle()
            #expect(h.runner.runs.isEmpty)

            // With consent the same note goes to the queue.
            h.consented = true
            #expect(await h.coordinator.transcribe(a) == .queued(changed: true))
            #expect(try await h.run(0).noteID == a)
        }

        @Test func withoutConsentAQueuedJobWaitsAsReadyToTranscribeInOneWrite() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A")
            h.settings.queueHold = .user
            await h.coordinator.transcribe(a, origin: .automatic)
            h.consented = false
            #expect(await h.coordinator.transcribe(a, origin: .automatic) == .needsConsent)
            #expect(try JobRepository(root: h.root).load().map(\.state) == [.needsConsent])
            #expect(h.coordinator.state.queue.isEmpty)
        }

        // ports: RecordingControllerTest#withoutConsentTheDownloadIsAskedOrTheNoteStaysAudioOnly
        @Test func aSavedRecordingIsQueuedOrTheDownloadIsOfferedUnlessItWasDeclined() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let consented = try await h.note("Consented"), asked = try await h.note("Asked")
            let declined = try await h.note("Declined"), long = try await h.note("Long")
            try await h.notes.mutate(long) { $0.duration = Limits.maxTranscribeDuration + 1 }

            #expect(await h.coordinator.handOff(consented) == .queued)
            #expect(try await h.run(0).noteID == consented)
            #expect(await h.coordinator.handOff(long) == .audioOnly, "too long for one transcription")
            h.consented = false
            #expect(await h.coordinator.handOff(asked) == .askConsent)
            #expect(await h.job(asked) == nil, "asking queues nothing")
            h.settings.recordDeclined()
            #expect(await h.coordinator.handOff(declined) == .audioOnly)
            #expect(await h.job(declined) == nil)
            #expect(await h.job(long) == nil)
        }

        /// The note's language is the language of the words it shows (D53.2): queueing never sets it, whatever Settings
        /// say; only a finished run does. A speakers-only job decodes nothing and takes no language.
        @Test func queueingNeverChangesTheNotesLanguage() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A")
            try await h.notes.mutate(a) { $0.language = "en-US" }
            h.settings.speechLanguage = "it-IT"
            await h.coordinator.transcribe(a, kind: .speakersOnly)
            #expect(try await h.run(0).job.language == "")
            #expect(await h.notes.note(a)?.language == "en-US")
            try await h.run(0).finish(.done)
            await h.coordinator.awaitIdle()

            await h.coordinator.transcribe(a, kind: .transcribeAgain)
            #expect(try await h.run(1).job.language == "it-IT")
            #expect(await h.notes.note(a)?.language == "en-US")
        }

        /// The windowed job's checkpoint must match the job's language, so saved progress resumes in the language it began
        /// in, whatever Settings say now; once it is gone (Start over) the Settings language applies again.
        @Test func savedProgressResumesInTheLanguageItBeganIn() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A")
            h.settings.speechLanguage = "it-IT"
            await h.coordinator.transcribe(a)
            let first = try await h.run(0)
            #expect(first.job.language == "it-IT")
            h.checkpoints.save(a, .saved(doneMs: 1_000, totalMs: 60_000, words: 1))
            first.finish(.paused(.user))
            await h.coordinator.awaitIdle()

            h.settings.speechLanguage = "en-US"
            await h.coordinator.transcribe(a)
            #expect(try await h.run(1).job.language == "it-IT")
            try await h.run(1).finish(.paused(.user))
            await h.coordinator.awaitIdle()

            await h.coordinator.startOver(a)
            #expect(try await h.run(2).job.language == "en-US")
            #expect(await h.notes.note(a)?.language == "", "the note has no words yet, so no language")
        }

        /// Saved progress whose job is gone (a rebuilt queue) resumes in the language its checkpoint began in, never in
        /// the note's, which is the language of the words it shows.
        @Test func savedProgressWithoutAJobResumesInItsCheckpointsLanguage() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A")
            try await h.notes.mutate(a) { $0.language = TranscriptLanguage.undetermined }
            h.checkpoints.save(a, .saved(doneMs: 1_000, totalMs: 60_000, words: 1), language: "it-IT")
            h.settings.speechLanguage = "en-US"
            await h.coordinator.transcribe(a)
            #expect(try await h.run(0).job.language == "it-IT")
        }

        @Test func theRunningJobsProgressIsTold() async throws {
            let h = try QueueHarness(); defer { h.tearDown() }
            try await h.start()
            let a = try await h.note("A")

            await h.coordinator.transcribe(a)
            let run = try await h.run(0)
            #expect(h.progress.noteID == a)
            run.send(.started(JobStart(totalMs: 10_000, speakers: false, prints: false)))
            run.send(.windowDone(doneMs: 5_000, totalMs: 10_000, words: []))
            try await h.waitUntil("the card reads the job's events") { h.progress.fraction(for: a) == 0.5 }
            run.finish(.paused(.user))
            await h.coordinator.awaitIdle()
            #expect(h.progress.noteID == nil)
            #expect(h.coordinator.state.jobs[a]?.state == .paused)
        }
    }
}
