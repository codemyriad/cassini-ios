import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@MainActor private final class AdmissionChoice {
    var recognizer = "whistle"
    var checks: [String?] = []
}

@MainActor @Suite struct SpeechSelectionAdmissionTests {
    @Test func verificationDuringConsentOnlyChangesTheNextJob() async throws {
        let choice = AdmissionChoice()
        let gate = AsyncStream<Void>.makeStream()
        let h = try QueueHarness(recognizerChoice: { choice.recognizer }, consentForRecognizer: { identity in
            ModelConsent(unavailability: { _, _ in
                choice.checks.append(identity)
                if choice.checks.count == 1 { for await _ in gate.stream { break } }
                return nil
            }) { _, _ in true }
        })
        defer { gate.continuation.finish(); h.tearDown() }
        try await h.start(visible: false)
        let first = try await h.note("First meeting"), next = try await h.note("Next meeting")
        let request = Task { await h.coordinator.transcribe(first) }
        try await h.waitUntil("the first model is checked") { choice.checks.count == 1 }
        choice.recognizer = "parakeet" // Installed and verified while the first request awaits consent.
        gate.continuation.yield(())
        #expect(await request.value == .queued(changed: true))
        #expect(await h.job(first)?.recognizer == "whistle")
        #expect(await h.coordinator.transcribe(next) == .queued(changed: true))
        #expect(await h.job(next)?.recognizer == "parakeet")
        #expect(choice.checks == ["whistle", "parakeet"])
    }
}
