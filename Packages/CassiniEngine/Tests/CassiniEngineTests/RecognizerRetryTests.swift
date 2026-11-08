import Foundation
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@MainActor @Suite(.serialized) struct RecognizerRetryTests {
    @Test func freshFailedRetryUsesSelectedModelAndItsConsent() async throws {
        for previous in [nil, "appleSpeech"] as [String?] {
            let h = try QueueHarness(recognizer: "whistle", consentForRecognizer: { recognizer in
                ModelConsent(unavailability: { _, _ in recognizer == "whistle" ? nil : .model }) { _, _ in true }
            })
            defer { h.tearDown() }
            try await h.start(visible: false)
            let id = try await h.note("English recording")
            try await h.jobs.enqueue(id, kind: .transcribe, language: "en-US", now: h.clock.now, recognizer: previous)
            try await h.jobs.transition(id, now: h.clock.now) {
                $0.state = .failed; $0.failure = .model; $0.doneMs = 100; $0.words = 1
            }
            let existing = await h.job(id)
            #expect(await h.coordinator.adoptsSelectedRecognizer(existing))
            #expect(await h.coordinator.transcribe(id) == .queued(changed: true))
            let job = try #require(await h.job(id))
            #expect(job.recognizer == "whistle")
            #expect(job.doneMs == 0 && job.words == 0 && job.totalMs == nil)
        }
    }

    @Test func savedPausedAndUnknownJobsKeepTheirBackend() async throws {
        let h = try QueueHarness(recognizer: "whistle")
        defer { h.tearDown() }
        try await h.start(visible: false)
        for scenario in ["saved", "paused", "unknown", "corrupt", "speakers"] {
            let id = try await h.note("English recording")
            let backend = scenario == "unknown" ? "future-engine" : "appleSpeech"
            let kind: JobKind = scenario == "speakers" ? .speakersOnly : .transcribe
            try await h.jobs.enqueue(id, kind: kind, language: "en-US", now: h.clock.now, recognizer: backend)
            try await h.jobs.transition(id, now: h.clock.now) { $0.state = scenario == "paused" ? .paused : .failed }
            if scenario == "saved" { h.checkpoints.save(id, .saved(doneMs: 100, totalMs: 1000, words: 1)) }
            if scenario == "corrupt" { h.checkpoints.save(id, .mismatch) }
            let existing = await h.job(id)
            #expect(await !h.coordinator.adoptsSelectedRecognizer(existing), "Preserve \(scenario)")
            _ = await h.coordinator.enqueue(id, kind: kind, language: "en-US")
            #expect(await h.job(id)?.recognizer == backend)
        }
    }
}
