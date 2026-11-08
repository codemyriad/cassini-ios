import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Android's ModelRepositoryTest where it applies on iOS: the consent and readiness rules. Android's repository also
/// reads marker files and runs the fetcher; on iOS Apple's AssetInventory owns the speech model and
/// `SpeakerModelInstaller` the speaker models, whose installs are covered by `SpeakerModelInstallerTests` and
/// `ModelInstallsTests`.
@MainActor @Suite struct ModelConsentTests {
    let suite = "cassini.tests.\(UUID().uuidString)"
    let clock = FakeClock(now: Date(timeIntervalSince1970: 42))

    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: suite)!, clock: clock, defaultLanguage: "en-US")
    }

    private func cleanUp() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    private func consent(_ settings: SettingsStore, speech: ModelPartStatus, speakers: Bool,
                         parakeet: Bool = false, recognizer: SpeechRecognizer = .appleSpeech) -> ModelConsent {
        ModelConsent.recorded(settings: settings,
                              speech: FakeTranscriber(.returns([], total: 0), status: speech, recognizer: recognizer),
                              speakers: FakeAnalyzer(modelIdentity: speakers ? "fake-model" : nil),
                              parakeetReady: { parakeet })
    }

    @Test func bundledWhistleNeedsNoDownloadConsentButCannotEnableAnUnavailableCandidate() async {
        defer { cleanUp() }
        let settings = settings()
        let ready = consent(settings, speech: .ready, speakers: false, recognizer: .whistle)
        #expect(await ready.allows(.transcribe, ""))
        #expect(await !ready.allows(.speakersOnly, ""))
        let blocked = consent(settings, speech: .unsupported, speakers: false, recognizer: .whistle)
        #expect(await blocked.unavailability(.transcribe, "") != nil)
        #expect(await !blocked.allows(.transcribe, ""))
    }

    @Test func consentNeverMakesAnUnsupportedSpeechCandidateAvailable() async {
        defer { cleanUp() }
        let settings = settings()
        let blocked = consent(settings, speech: .unsupported, speakers: true)
        #expect(await blocked.unavailability(.transcribe, "en-US") == .unsupportedLanguage)
        settings.recordConsent()
        #expect(await blocked.unavailability(.transcribeAgain, "en-US") == .unsupportedLanguage)
        #expect(await blocked.unavailability(.speakersOnly, "en-US") == nil)
        #expect(await consent(settings, speech: .notDownloaded, speakers: true).unavailability(.transcribe, "en-US") == nil)
    }

    // ports (Apple Speech fallback, ModelRepositoryTests has the port): ModelRepositoryTest#nothingInstalledAndNoConsent
    @Test func nothingInstalledAndNoConsent() async {
        defer { cleanUp() }
        let consent = consent(settings(), speech: .notDownloaded, speakers: false)
        #expect(await !consent.allows(.transcribe, "en-US"))
        #expect(await !consent.allows(.transcribeAgain, "en-US"))
        #expect(await !consent.allows(.speakersOnly, "en-US"))
        let plan = ModelDownloadPlan.plan(speech: .notDownloaded, speakers: .notDownloaded, forNote: false,
                                          identifySpeakers: true, speakersInstallBytes: 100)
        #expect(plan.missing == [.speech, .speakers])
        #expect(plan.requiredFreeBytes == ModelDownloadPlan.speechInstallBytes + 100)
    }

    // ports (Apple Speech fallback, ModelRepositoryTests has the port): ModelRepositoryTest#markerFilesDecideReadiness
    /// An installed model counts as consent for its own kind: the speech model for transcriptions, the speaker models
    /// for Identify speakers. Unavailable speech is refused before the consent decision.
    @Test func anInstalledModelCountsAsConsentForItsKind() async {
        defer { cleanUp() }
        let settings = settings()
        let speech = consent(settings, speech: .ready, speakers: false)
        #expect(await speech.allows(.transcribe, "en-US"))
        #expect(await !speech.allows(.speakersOnly, "en-US"))
        #expect(await !consent(settings, speech: .unsupported, speakers: false).allows(.transcribe, "en-US"))
        #expect(await consent(settings, speech: .notDownloaded, speakers: true).allows(.speakersOnly, "en-US"))
        let plan = ModelDownloadPlan.plan(speech: .ready, speakers: .notDownloaded, forNote: true,
                                          identifySpeakers: true, speakersInstallBytes: 100)
        #expect(plan.missing == [.speakers])
    }

    /// On a Parakeet device Apple's speech assets are no consent: iOS may have installed them for dictation. Only the
    /// recorded consent or an installed Ultra lets a job download (decision D2).
    @Test func appleAssetsAreNoConsentOnAParakeetDevice() async {
        defer { cleanUp() }
        let settings = settings()
        #expect(await !consent(settings, speech: .unsupported, speakers: false, recognizer: .parakeet)
            .allows(.transcribe, "en-US"))
        #expect(await consent(settings, speech: .notDownloaded, speakers: false, parakeet: true, recognizer: .parakeet)
            .allows(.transcribeAgain, "en-US"))
        settings.recordConsent()
        #expect(await consent(settings, speech: .notDownloaded, speakers: false, recognizer: .parakeet)
            .allows(.transcribe, "en-US"))
    }

    // ports (Apple Speech fallback, ModelRepositoryTests has the port): ModelRepositoryTest#consentIsTheStoredTimeOrParakeet
    @Test func consentIsTheStoredTimeOrAnInstalledModel() async {
        defer { cleanUp() }
        let settings = settings()
        let consent = consent(settings, speech: .notDownloaded, speakers: false)
        settings.recordDeclined()
        #expect(await !consent.allows(.transcribe, "en-US"))
        settings.recordConsent()
        #expect(await consent.allows(.transcribe, "en-US"))
        #expect(settings.modelsConsentAt == clock.now)
        #expect(settings.modelsDeclinedAt == clock.now, "the refusal stays recorded beside the consent")
        #expect(await !consent.allows(.speakersOnly, "en-US"), "the speaker models have a consent of their own")
        settings.recordSpeakerConsent()
        #expect(await consent.allows(.speakersOnly, "en-US"))
    }

    /// Android's consent rule: Parakeet installed counts as consent for transcriptions, even with Apple's speech
    /// assets missing; the speaker models keep their own consent.
    @Test func anInstalledParakeetCountsAsConsent() async {
        defer { cleanUp() }
        let consent = consent(settings(), speech: .notDownloaded, speakers: false, parakeet: true)
        #expect(await consent.allows(.transcribe, "en-US"))
        #expect(await consent.allows(.transcribeAgain, "en-US"))
        #expect(await !consent.allows(.speakersOnly, "en-US"))
    }
}
