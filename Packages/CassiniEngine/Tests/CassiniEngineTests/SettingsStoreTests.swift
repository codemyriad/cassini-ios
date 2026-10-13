import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@MainActor @Suite struct SettingsStoreTests {
    let suite = "cassini.tests.\(UUID().uuidString)"
    let clock = FakeClock(now: Date(timeIntervalSince1970: 1_000))

    private func defaults() -> UserDefaults { UserDefaults(suiteName: suite)! }
    private func store() -> SettingsStore { SettingsStore(defaults: defaults(), clock: clock, defaultLanguage: "en-US") }
    private func cleanUp() { defaults().removePersistentDomain(forName: suite) }

    // ports: SettingsRepositoryTest#defaultsBeforeAnyWrite
    @Test func defaultsBeforeAnyWrite() {
        defer { cleanUp() }
        let settings = store()
        #expect(settings.speechLanguage == "en-US")
        #expect(settings.autoTranscribe && settings.identifySpeakers)
        #expect(!settings.automaticallyNameVoices)
        #expect(settings.speakerModelIdentity == nil)
        #expect(settings.modelsConsentAt == nil && settings.modelsDeclinedAt == nil && settings.speakerModelsConsentAt == nil)
        #expect(settings.queueHold == nil)
        #expect(settings.recoveredAck == nil)
        #expect(!settings.notificationsAsked)
        #expect(settings.finalizationMs == nil && settings.trashLastPurgeAt == nil)
        #expect(settings.voicesGeneration == 0)
    }

    // ports: SettingsRepositoryTest#everyKeyRoundTripsThroughTheFile
    @Test func everyKeyRoundTripsThroughTheFile() {
        defer { cleanUp() }
        let settings = store()
        settings.speechLanguage = "it-IT"
        settings.autoTranscribe = false
        settings.identifySpeakers = false
        settings.automaticallyNameVoices = true
        settings.speakerModelIdentity = "model:abc"
        settings.recordConsent()
        clock.advance(by: .seconds(1)); settings.recordDeclined()
        settings.recordSpeakerConsent()
        settings.queueHold = .system
        settings.acknowledgeRecovered(upTo: Date(timeIntervalSince1970: 5))
        settings.markNotificationsAsked()
        settings.recordFinalization(8_000)
        settings.recordPurge()
        settings.advanceVoicesGeneration()

        let reopened = store()
        #expect(reopened.speechLanguage == "it-IT")
        #expect(!reopened.autoTranscribe && !reopened.identifySpeakers && reopened.automaticallyNameVoices)
        #expect(reopened.speakerModelIdentity == "model:abc")
        #expect(reopened.modelsConsentAt == Date(timeIntervalSince1970: 1_000))
        #expect(reopened.modelsDeclinedAt == Date(timeIntervalSince1970: 1_001))
        #expect(reopened.speakerModelsConsentAt == Date(timeIntervalSince1970: 1_001))
        #expect(reopened.queueHold == .system)
        #expect(reopened.recoveredAck == Date(timeIntervalSince1970: 5))
        #expect(reopened.notificationsAsked)
        #expect(reopened.finalizationMs == 8_000)
        #expect(reopened.trashLastPurgeAt == Date(timeIntervalSince1970: 1_001))
        #expect(reopened.voicesGeneration == 1)
    }

    // ports: SettingsRepositoryTest#keysKeepTheirStoredNames
    @Test func keysKeepTheirStoredNames() {
        defer { cleanUp() }
        let settings = store()
        settings.recordConsent()
        settings.queueHold = .user
        let stored = defaults().dictionaryRepresentation()
        #expect((stored["models.consentAt"] as? NSNumber)?.int64Value == 1_000_000)
        #expect(stored["queue.hold"] as? String == "user")
        #expect(Set(SettingsKeys.all).count == SettingsKeys.all.count)
    }

    // ports: SettingsRepositoryTest#finalizationIsARunningEstimate
    @Test func finalizationIsARunningEstimate() {
        defer { cleanUp() }
        let settings = store()
        #expect(settings.recordFinalization(8_000) == 8_000)
        #expect(settings.recordFinalization(4_000) == (8_000 * 3 + 4_000) / 4)
        #expect(settings.finalizationMs == 7_000)
    }

    // ports: SettingsRepositoryTest#holdsClearAndRecoveredAckNeverGoesBack
    @Test func holdsClearAndRecoveredAckNeverGoesBack() {
        defer { cleanUp() }
        let settings = store()
        settings.queueHold = .user
        settings.queueHold = nil
        #expect(store().queueHold == nil)
        settings.acknowledgeRecovered(upTo: Date(timeIntervalSince1970: 5))
        settings.acknowledgeRecovered(upTo: Date(timeIntervalSince1970: 3))
        #expect(store().recoveredAck == Date(timeIntervalSince1970: 5))
        #expect(!settings.notificationsAsked)
    }

    @Test func schemaOneDownloadSwitchesBecomeConsentAndLanguagesBecomeBCP47() {
        defer { cleanUp() }
        defaults().set(true, forKey: SettingsKeys.legacyModelDownloadsAllowed)
        defaults().set(false, forKey: SettingsKeys.legacySpeakerDownloadsAllowed)
        defaults().set("pt_BR", forKey: SettingsKeys.speechLanguage)
        let settings = store()
        #expect(settings.modelsConsentAt == clock.now)
        #expect(settings.speakerModelsConsentAt == nil)
        #expect(settings.speechLanguage == "pt-BR")
        #expect(defaults().object(forKey: SettingsKeys.legacyModelDownloadsAllowed) == nil)
        settings.modelsConsentAt = nil
        #expect(store().modelsConsentAt == nil, "a withdrawn consent is not migrated again")
    }
}
