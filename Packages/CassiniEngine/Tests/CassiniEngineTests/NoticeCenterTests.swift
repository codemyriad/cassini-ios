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
    private func recovered(createdAt: TimeInterval, recoveredAt: TimeInterval, duration: TimeInterval) -> RecoveredRecording {
        RecoveredRecording(noteID: UUID(), createdAt: Date(timeIntervalSince1970: createdAt),
                           recoveredAt: Date(timeIntervalSince1970: recoveredAt), duration: duration)
    }

    @Test func everySourceAddsItsFactsAndTwoFactsBothShow() {
        defer { cleanUp() }
        let center = NoticeCenter(settings: settings(), notifier: notifier) { false }
        let saved = recovered(createdAt: 400, recoveredAt: 900, duration: 312)
        center.register { $0.recovered = [saved] }
        center.register { $0.importing = ["call.m4a"] }
        center.register { $0.queueHold = .user; $0.waitingJobs = 2 }
        let facts = center.facts
        #expect(facts.recovered == [saved])
        #expect(facts.importing == ["call.m4a"])
        #expect(facts.waitingJobs == 2)
        #expect(center.library(LibraryFacts(loading: true)).map(\.kind) == [.txQueueHeld, .recovered, .importing])
    }

    @Test func closingRecoveredAcknowledgesItForGood() {
        defer { cleanUp() }
        let store = settings()
        let center = NoticeCenter(settings: store, notifier: notifier) { false }
        let older = recovered(createdAt: 300, recoveredAt: 800, duration: 1)
        let latest = recovered(createdAt: 400, recoveredAt: 900, duration: 2)
        let shown = Box([older, latest])
        center.register { $0.recovered = shown.value }
        #expect(center.latestRecovered == latest)
        center.dismiss(.recovered)
        #expect(store.recoveredAck == latest.recoveredAt)
        #expect(center.facts.recovered.isEmpty)
        #expect(center.library(LibraryFacts(loading: true)).isEmpty)

        // A later recovery shows again; the acknowledgement never goes back.
        let next = recovered(createdAt: 450, recoveredAt: 950, duration: 3)
        shown.value = [older, next]
        #expect(center.facts.recovered == [next])
        store.acknowledgeRecovered(upTo: Date(timeIntervalSince1970: 100))
        #expect(store.recoveredAck == latest.recoveredAt)

        let reopened = NoticeCenter(settings: settings(), notifier: notifier) { false }
        reopened.register { $0.recovered = [older, latest] }
        #expect(reopened.facts.recovered.isEmpty, "the acknowledgement is kept across launches")
    }

    @Test func theLatestRecoveredIsTheLastRecordedAndClosingAcknowledgesThemAll() {
        defer { cleanUp() }
        let store = settings()
        let center = NoticeCenter(settings: store, notifier: notifier) { false }
        // One launch recovers every recording at one moment; the rebuilt one was recorded last.
        let rebuilt = recovered(createdAt: 700, recoveredAt: 900, duration: 312)
        let repaired = recovered(createdAt: 500, recoveredAt: 900, duration: 20)
        center.register { $0.recovered = [repaired, rebuilt] }
        #expect(center.latestRecovered == rebuilt)
        #expect(center.library(LibraryFacts(loading: true)).first?.args.ms1 == 312_000)
        center.dismiss(.recovered)
        #expect(store.recoveredAck == Date(timeIntervalSince1970: 900))
        #expect(center.latestRecovered == nil)
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
        // Every download banner that reports a failure closes until the next install; progress and offers do not.
        for kind in BannerKind.allCases where kind.group == .download {
            #expect(kind.isDownloadFailure == (kind.tone == .error), "\(kind)")
        }
        #expect(BannerKind.dlPinUnavailable.isDownloadFailure)
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
        let ready = Box(false)
        let center = NoticeCenter(settings: store, notifier: notifier) { ready.value }
        await center.refresh()
        #expect(!center.facts.consented)
        ready.value = true
        await center.refresh()
        #expect(center.facts.consented)
        ready.value = false
        await center.refresh()
        store.recordConsent()
        #expect(center.facts.consented)
    }
}

/// A value the closures under test read while the test changes it.
@MainActor private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
