import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@MainActor private final class RestoreChoice { var value = "whistle" }

@MainActor @Suite struct RecognizerPersistenceTests {
    @Test func trashRestorePreservesTheQueuedBackendAfterChangingTheDefault() async throws {
        let choice = RestoreChoice()
        let h = try QueueHarness(recognizerChoice: { choice.value })
        defer { h.tearDown() }
        try await h.start(visible: false)
        let id = try await h.note("English meeting")
        h.settings.queueHold = .system
        await h.coordinator.transcribe(id, origin: .automatic)
        let trashed = try #require(h.coordinator.moveToTrash(id))
        #expect(trashed.recognizer == "whistle")
        try await h.waitUntil("the queued job left") { await h.job(id) == nil }
        choice.value = "appleSpeech"
        let persisted = try JSONDecoder().decode(TrashedJob.self, from: JSONEncoder().encode(trashed))
        await h.coordinator.restore(id, trashedJob: persisted)
        #expect(await h.job(id)?.recognizer == "whistle")
        #expect(await h.coordinator.modelDownloadContext(for: id).recognizer == "whistle")
    }

    @Test func damagedQueueRebuildRecoversIdentityFromTheCheckpoint() async throws {
        let h = try QueueHarness(recognizer: "appleSpeech")
        defer { h.tearDown() }
        let id = try await h.note("English meeting")
        h.checkpoints.save(id, .saved(doneMs: 30_000, totalMs: 60_000, words: 4), recognizer: "whistle")
        try Data("{broken".utf8).write(to: h.root.appendingPathComponent(JobRepository.filename))
        await #expect(throws: JobStore.Failure.self) { try await h.start(visible: false) }
        #expect(await h.job(id)?.recognizer == "whistle")
        #expect(await h.job(id)?.state == .paused)
        #expect(h.checkpoints.hasWork(id))
    }

    @Test func oldTrashMetadataAndKnownCheckpointFamiliesStayCompatible() throws {
        let old = TrashedJob(state: .queued, kind: .transcribe)
        let decoded = try JSONDecoder().decode(TrashedJob.self, from: JSONEncoder().encode(old))
        #expect(decoded.recognizer == nil)
        let future = TrashedJob(state: .queued, kind: .transcribe, recognizer: "future-engine")
        #expect(try JSONDecoder().decode(TrashedJob.self, from: JSONEncoder().encode(future)).recognizer == "future-engine")
        #expect(SpeechRecognizer.fromCheckpoint(model: SpeechRecognizer.whistle.checkpointModel(language: "")) == .whistle)
        #expect(SpeechRecognizer.fromCheckpoint(model: SpeechRecognizer.appleSpeech.checkpointModel(language: "en-US")) == .appleSpeech)
        #expect(SpeechRecognizer.fromCheckpoint(model: SpeechRecognizer.parakeet.checkpointModel(language: "")) == .parakeet)
        #expect(SpeechRecognizer.fromCheckpoint(model: "unknown-model") == nil)
    }

    @Test func downloadContextUsesPendingIdentityAndSavedLanguage() async throws {
        let h = try QueueHarness(recognizer: "whistle")
        defer { h.tearDown() }
        try await h.start(visible: false)
        for state in [JobState.needsConsent, .paused] {
            for identity in [nil, "appleSpeech", "parakeet"] as [String?] {
                let id = try await h.note("English meeting")
                try await h.jobs.enqueue(id, kind: .transcribe, language: "en-US", now: h.clock.now, recognizer: identity)
                try await h.jobs.transition(id, now: h.clock.now) { $0.state = state }
                h.checkpoints.save(id, .saved(doneMs: 30_000, totalMs: 60_000, words: 4), language: "en-US")
                h.settings.speechLanguage = "it-IT"
                let context = await h.coordinator.modelDownloadContext(for: id)
                #expect(context.recognizer == identity)
                #expect(context.language == "en-US")
            }
        }
    }
}
