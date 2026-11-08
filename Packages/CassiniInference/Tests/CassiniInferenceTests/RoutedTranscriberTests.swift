import Foundation
import Testing
import Synchronization
import CassiniEngine
import CassiniEngineTesting
@testable import CassiniInference

@Suite struct RoutedTranscriberTests {
    @Test func verificationChangesNewDefaultsButNeverAnExistingJobAdapter() throws {
        let state = Mutex(SpeechModelPolicy(whistleAvailable: true, parakeetLinked: true,
            physicalMemory: SpeechCapability.minimumPhysicalMemory, availableMemory: nil,
            parakeetInstallation: .missing, availableDiskBytes: .max, downloadPlan: ModelPlan.of { _ in false }))
        let apple = FakeTranscriber(.returns([], total: 1), recognizer: .appleSpeech)
        let whistle = FakeTranscriber(.returns([], total: 1), recognizer: .whistle)
        let parakeet = FakeTranscriber(.returns([], total: 1), recognizer: .parakeet)
        let router = RoutedTranscriber(legacy: apple, candidates: [whistle, parakeet]) {
            state.withLock { $0.selected() ?? .appleSpeech }
        }
        #expect(router.recognizer == .whistle)
        let existing = try router.forJob(recognizer: router.recognizer.rawValue)
        state.withLock { $0.parakeetInstallation = .checking }
        #expect(router.recognizer == .whistle)
        state.withLock { $0.parakeetInstallation = .verified }
        #expect(router.recognizer == .parakeet)
        #expect(existing.recognizer == .whistle)
        #expect(try router.forJob(recognizer: "whistle").recognizer == .whistle)
        #expect(try router.forJob(recognizer: nil).recognizer == .appleSpeech)
        state.withLock { $0.parakeetInstallation = .missing }
        #expect(router.recognizer == .whistle)
    }

    @Test func aMissingCandidateCannotDecodeOrDownloadThroughAnotherBackend() async {
        let whistle = FakeTranscriber(.returns([], total: 1), recognizer: .whistle)
        let router = RoutedTranscriber(legacy: whistle, candidates: []) { .parakeet }
        #expect(await router.assetStatus(locale: .current) == .unsupported)
        #expect(await router.unavailability(locale: .current) == .model)
        #expect(throws: TranscriptionError.failed(.model)) { try router.forJob(recognizer: "parakeet") }
        await #expect(throws: TranscriptionError.failed(.model)) {
            try await router.installAssets(locale: .current) { _ in }
        }
        await #expect(throws: TranscriptionError.failed(.model)) {
            try await router.transcribe(.init(url: URL(fileURLWithPath: "/unused.wav"), language: "", allowDownload: false)) { _ in }
        }
    }

    @Test func persistedJobsKeepTheirBackendAcrossPreferenceChanges() throws {
        let legacy = FakeTranscriber(.returns([], total: 1), recognizer: .appleSpeech)
        let whistle = FakeTranscriber(.returns([], total: 1), recognizer: .whistle)
        let optedIn = RoutedTranscriber(legacy: legacy, preferred: whistle)
        #expect(optedIn.recognizer == .whistle)
        #expect(try optedIn.forJob(recognizer: nil).recognizer == .appleSpeech)
        #expect(try optedIn.forJob(recognizer: "appleSpeech").recognizer == .appleSpeech)
        #expect(try optedIn.forJob(recognizer: "whistle").recognizer == .whistle)
        let internalOptOut = RoutedTranscriber(legacy: legacy, retained: whistle)
        #expect(internalOptOut.recognizer == .appleSpeech)
        #expect(try internalOptOut.forJob(recognizer: "whistle").recognizer == .whistle)
        let optedOut = RoutedTranscriber(legacy: legacy)
        #expect(throws: TranscriptionError.self) { try optedOut.forJob(recognizer: "whistle") }
        #expect(throws: TranscriptionError.self) { try optedIn.forJob(recognizer: "future-engine") }
    }
}
