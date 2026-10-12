import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The center merges the sources' facts and remembers what the user closed.
@MainActor @Suite struct NoticeCenterTests {
    let suite = "cassini.tests.\(UUID().uuidString)"
    let clock = FakeClock(now: Date(timeIntervalSince1970: 1_000))
    let notifier = FakeNotifier(auth: .authorized)

    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: suite)!, clock: clock, defaultLanguage: "en-US")
    }
    private func cleanUp() { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }

    @Test func everySourceAddsItsFactsAndTwoFactsBothShow() {
        defer { cleanUp() }
        let center = NoticeCenter(settings: settings(), notifier: notifier) { false }
        let recovered = RecoveredRecording(noteID: UUID(), recoveredAt: Date(timeIntervalSince1970: 900), duration: 312)
        center.register { $0.recovered = [recovered] }
        center.register { $0.importing = ["call.m4a"] }
        center.register { $0.queueHold = .user; $0.waitingJobs = 2 }
        let facts = center.facts
        #expect(facts.recovered == [recovered])
        #expect(facts.importing == ["call.m4a"])
        #expect(facts.waitingJobs == 2)
        #expect(center.library(LibraryFacts(loading: true)).map(\.kind) == [.txQueueHeld, .recovered, .importing])
    }

    @Test func closingRecoveredAcknowledgesItForGood() {
        defer { cleanUp() }
        let store = settings()
        let center = NoticeCenter(settings: store, notifier: notifier) { false }
        let older = RecoveredRecording(noteID: UUID(), recoveredAt: Date(timeIntervalSince1970: 800), duration: 1)
        let latest = RecoveredRecording(noteID: UUID(), recoveredAt: Date(timeIntervalSince1970: 900), duration: 2)
        var recovered = [older, latest]
        center.register { $0.recovered = recovered }
        #expect(center.latestRecovered == latest)
        center.dismiss(.recovered)
        #expect(store.recoveredAck == latest.recoveredAt)
        #expect(center.facts.recovered.isEmpty)
        #expect(center.library(LibraryFacts(loading: true)).isEmpty)

        // A later recovery shows again; the acknowledgement never goes back.
        let next = RecoveredRecording(noteID: UUID(), recoveredAt: Date(timeIntervalSince1970: 950), duration: 3)
        recovered = [older, next]
        #expect(center.facts.recovered == [next])
        store.acknowledgeRecovered(upTo: Date(timeIntervalSince1970: 100))
        #expect(store.recoveredAck == latest.recoveredAt)

        let reopened = NoticeCenter(settings: settings(), notifier: notifier) { false }
        reopened.register { $0.recovered = [older, latest] }
        #expect(reopened.facts.recovered.isEmpty, "the acknowledgement is kept across launches")
    }

    @Test func closingABannerReachesEverySource() {
        defer { cleanUp() }
        let center = NoticeCenter(settings: settings(), notifier: notifier) { false }
        var heard: [BannerKind] = []
        center.register({ _ in }, dismiss: { heard.append($0) })
        center.dismiss(.importOpen)
        center.dismiss(.dlNoConnection)
        #expect(heard == [.importOpen, .dlNoConnection])
        #expect(BannerKind.importOpen.isImportFailure && !BannerKind.importOpen.isDownloadFailure)
        #expect(BannerKind.dlStopped.isDownloadFailure)
    }

    @Test func unreadableNotesCloseForThisRun() {
        defer { cleanUp() }
        let center = NoticeCenter(settings: settings(), notifier: notifier) { false }
        center.register { $0.unreadableNotes = 2 }
        #expect(center.facts.unreadableNotes == 2)
        center.dismiss(.notesUnreadable)
        #expect(center.facts.unreadableNotes == 0)
    }

    // ports: NoticeCenterTest#libraryAndImportRows (NOTIFICATIONS_OFF follows the permission)
    @Test func theNotificationPermissionIsReadAgainOnRefresh() async {
        defer { cleanUp() }
        let center = NoticeCenter(settings: settings(), notifier: notifier) { false }
        center.register { $0.jobRunning = true }
        await center.refresh()
        #expect(!center.facts.notificationsOff)
        notifier.setAuthorization(.denied)
        #expect(!center.facts.notificationsOff, "read only on refresh")
        await center.refresh()
        #expect(center.facts.notificationsOff)
        #expect(center.library(LibraryFacts(loading: true)).map(\.kind) == [.notificationsOff])
        #expect(center.settingsBanners.map(\.kind) == [.notificationsOff])
        notifier.setAuthorization(.notDetermined)
        await center.refresh()
        #expect(!center.facts.notificationsOff, "not asked yet is not off: the first record or transcribe asks")
    }

    @Test func consentIsRecordedOrAnInstalledSpeechModel() async {
        defer { cleanUp() }
        let store = settings()
        var ready = false
        let center = NoticeCenter(settings: store, notifier: notifier) { ready }
        await center.refresh()
        #expect(!center.facts.consented)
        ready = true
        await center.refresh()
        #expect(center.facts.consented)
        ready = false
        await center.refresh()
        store.recordConsent()
        #expect(center.facts.consented)
    }
}
