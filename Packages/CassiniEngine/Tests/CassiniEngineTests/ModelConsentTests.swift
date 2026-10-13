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

    private func consent(_ settings: SettingsStore, speech: ModelPartStatus, speakers: Bool) -> ModelConsent {
        ModelConsent.recorded(settings: settings, speech: FakeTranscriber(.returns([], total: 0), status: speech),
                              speakers: FakeAnalyzer(modelIdentity: speakers ? "fake-model" : nil))
    }

    // ports: ModelRepositoryTest#nothingInstalledAndNoConsent
    @Test func nothingInstalledAndNoConsent() async {
        defer { cleanUp() }
        let consent = consent(settings(), speech: .notDownloaded, speakers: false)
        #expect(await !consent.allows(.transcribe, "en-US"))
        #expect(await !consent.allows(.transcribeAgain, "en-US"))
        #expect(await !consent.allows(.speakersOnly, "en-US"))
        let plan = ModelPlan.plan(speech: .notDownloaded, speakers: .notDownloaded, forNote: false, identifySpeakers: true,
                                  speakersInstallBytes: 100)
        #expect(plan.missing == [.speech, .speakers])
        #expect(plan.requiredFreeBytes == ModelPlan.speechInstallBytes + 100)
    }

    // ports: ModelRepositoryTest#markerFilesDecideReadiness
    /// An installed model counts as consent for its own kind: the speech model for transcriptions, the speaker models
    /// for Identify speakers. A language Apple does not offer asks nothing; its job says so.
    @Test func anInstalledModelCountsAsConsentForItsKind() async {
        defer { cleanUp() }
        let settings = settings()
        let speech = consent(settings, speech: .ready, speakers: false)
        #expect(await speech.allows(.transcribe, "en-US"))
        #expect(await !speech.allows(.speakersOnly, "en-US"))
        #expect(await consent(settings, speech: .unsupported, speakers: false).allows(.transcribe, "en-US"))
        #expect(await consent(settings, speech: .notDownloaded, speakers: true).allows(.speakersOnly, "en-US"))
        let plan = ModelPlan.plan(speech: .ready, speakers: .notDownloaded, forNote: true, identifySpeakers: true,
                                  speakersInstallBytes: 100)
        #expect(plan.missing == [.speakers])
    }

    // ports: ModelRepositoryTest#consentIsTheStoredTimeOrParakeet
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
}
