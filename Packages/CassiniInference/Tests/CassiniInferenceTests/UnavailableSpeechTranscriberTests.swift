import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import CassiniInference

/// The candidate of a system without Apple speech where nothing else can run: it refuses as the hardware failure the
/// note screen already disables Transcribe for (PR #43), and a router selecting no recognizer reaches it.
@Suite struct UnavailableSpeechTranscriberTests {
    private let request = TranscriptionRequest(url: URL(fileURLWithPath: "/unused.wav"), language: "en-US", allowDownload: true)

    @Test func itRefusesEveryJobAsTheDeviceFailureOfTheFakeItReplaces() async {
        let unavailable = UnavailableSpeechTranscriber(), fake = FakeUnavailableTranscriber(.model)
        let locale = Locale(identifier: "en_US")
        #expect(await unavailable.availability(locale: locale) == fake.availability(locale: locale))
        #expect(await unavailable.availability(locale: locale) == SpeechAvailability(assets: .unsupported, failure: .model))
        #expect(await unavailable.assetStatus(locale: locale) == .unsupported)
        #expect(await unavailable.unavailability(locale: locale) == .model)
        #expect(await unavailable.speechLanguages().isEmpty, "no speech language to pick")
        #expect(await unavailable.runLanguage(requested: "en-US") == nil)
        #expect(unavailable.recognizer == .appleSpeech)
        await #expect(throws: TranscriptionError.failed(.model)) { try await unavailable.installAssets(locale: locale) { _ in } }
        await #expect(throws: TranscriptionError.failed(.model)) { try await unavailable.transcribe(request) { _ in } }
    }

    /// The iOS 18 composition: the Apple slot holds the unavailable candidate, so when the policy selects nothing every
    /// path refuses, and once Whistle or a verified Parakeet is selected the router uses it.
    @Test func aRouterThatSelectsNothingOnIOS18Refuses() async throws {
        let whistle = FakeTranscriber(.returns([], total: 1), recognizer: .whistle)
        var facts = SpeechModelPolicy(whistleAvailable: false, parakeetLinked: true, physicalMemory: 3 << 30,
            availableMemory: nil, parakeetInstallation: .missing, availableDiskBytes: .max, downloadPlan: ModelPlan([]))
        let router = RoutedTranscriber(legacy: UnavailableSpeechTranscriber(), candidates: [whistle]) { [facts] in
            facts.recognizer(platform: .iOS18) ?? .appleSpeech
        }
        #expect(router.recognizer == .appleSpeech)
        #expect(await router.unavailability(locale: .current) == .model)
        #expect(await router.speechLanguages().isEmpty)
        await #expect(throws: TranscriptionError.failed(.model)) { try await router.transcribe(request) { _ in } }
        #expect(throws: Never.self) { try router.forJob(recognizer: "appleSpeech") }
        facts.whistleAvailable = true
        let available = RoutedTranscriber(legacy: UnavailableSpeechTranscriber(), candidates: [whistle]) { [facts] in
            facts.recognizer(platform: .iOS18) ?? .appleSpeech
        }
        #expect(available.recognizer == .whistle)
        #expect(await available.unavailability(locale: .current) == nil)
    }
}
