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

    @Test func recognitionDefaultsOnAndPersistsIndependentlyFromAutoNaming() async {
        defer { cleanUp() }
        let settings = store()
        #expect(settings.recogniseSavedVoices)
        #expect(await Task.detached { settings.allowsSavedVoiceRecognition }.value)
        #expect(!settings.automaticallyNameVoices)
        settings.recogniseSavedVoices = false
        settings.automaticallyNameVoices = true
        let reloaded = store()
        #expect(!reloaded.recogniseSavedVoices)
        #expect(await Task.detached { !settings.allowsSavedVoiceRecognition && !reloaded.allowsSavedVoiceRecognition }.value)
        #expect(reloaded.automaticallyNameVoices)
        #expect(reloaded.identifySpeakers)
    }

    @Test func disablingRecognitionScrubsPausedDraftsAndColdStartBeforeJobsResume() async throws {
        defer { cleanUp() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = UUID(), confirmed = UUID(), suggested = UUID(), automatic = UUID()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(note.uuidString), withIntermediateDirectories: true)
        let names = DraftNames.empty.confirm("a", voice: confirmed, name: "Alex", generation: 1, score: 1)
            .rename("b", "Manual").reject("c", voice: suggested)
            .applyLive(["d": LiveMatch(suggested, 0.6, .suggested), "e": LiveMatch(automatic, 1, .auto)],
                       names: [automatic: "Auto"])
        let drafts = DraftNamesStore(notes: try NoteStore(root: root))
        drafts.mutate(note) { _ in names }
        drafts.release(note) // A paused draft not loaded into memory.
        let settings = store()
        settings.bindDraftNames(drafts)
        settings.recogniseSavedVoices = false
        await settings.settleDraftRecognition()
        let expected = names.withoutUnconfirmedMatches()
        #expect(DraftNamesStore(notes: try NoteStore(root: root)).current(note) == expected)
        // Simulate an older process leaving stale suggestions behind before this cold start.
        let old = DraftNamesStore(notes: try NoteStore(root: root))
        old.mutate(note) { _ in names }
        let reopened = store(), fresh = DraftNamesStore(notes: try NoteStore(root: root))
        reopened.bindDraftNames(fresh)
        #expect(fresh.current(note) == expected)
        await reopened.settleDraftRecognition()
        #expect(DraftNamesStore(notes: try NoteStore(root: root)).current(note) == expected)
    }

    @Test func rememberAnswerPersistsIndependentlyAndDismissalPreservesIt() {
        defer { cleanUp() }
        let settings = store()
        #expect(settings.rememberPeopleIName && !settings.voiceSetupAnswered)
        settings.automaticallyNameVoices = true
        settings.answerVoiceSetup(enable: false)
        #expect(store().voiceSetupAnswered && !store().rememberPeopleIName)
        #expect(store().automaticallyNameVoices && store().recogniseSavedVoices)
        settings.answerVoiceSetup(enable: nil)
        #expect(!store().rememberPeopleIName)
        settings.setRememberPeopleIName(true)
        #expect(store().voiceSetupAnswered && store().rememberPeopleIName)
        settings.automaticallyNameVoices = false
        #expect(store().rememberPeopleIName)
    }

    @Test func legacyAnsweredDoesNotInferRememberFromAutomaticNaming() {
        defer { cleanUp() }
        defaults().set(true, forKey: "voices.setupAnswered")
        defaults().set(false, forKey: SettingsKeys.automaticallyNameVoices)
        #expect(store().voiceSetupAnswered && store().rememberPeopleIName)
        store().answerVoiceSetup(enable: false)
        #expect(!store().rememberPeopleIName)
    }

    @Test func dismissingFirstQuestionRecordsAnswerAndRetainsDefault() {
        defer { cleanUp() }
        store().answerVoiceSetup(enable: nil)
        #expect(store().voiceSetupAnswered && store().rememberPeopleIName)
        #expect(!store().automaticallyNameVoices)
    }

    // ports: SettingsRepositoryTest#defaultsBeforeAnyWrite
    @Test func defaultsBeforeAnyWrite() {
        defer { cleanUp() }
        let settings = store()
        #expect(settings.speechLanguage == "en-US")
        #expect(settings.autoTranscribe && settings.identifySpeakers)
        #expect(!settings.automaticallyNameVoices)
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
}
