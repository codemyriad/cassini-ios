import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

/// The Settings screen over fake ports.
@MainActor @Suite struct SettingsModelTests {
    @MainActor private final class FakePorts: SettingsPorts {
        var modelStatuses: [ModelPart: ModelPartStatus] = [:]
        var consents: Set<ModelPart> = []
        var voices = 0
        var trash = 0
        var notes: [Note] = []
        var notificationsOff = false
        let version = "9.9.9"
        var refreshed = 0
        var noticeRefreshes = 0

        func consented(to part: ModelPart) -> Bool { consents.contains(part) }
        func size(of part: ModelPart) -> ModelSize {
            switch part {
            case .speech: .managedBySystem
            case .speakers: .bytes(21_600_000)
            case .voices: .includedWith(.speakers)
            }
        }
        func refreshModels() async { refreshed += 1 }
        func refreshNotices() async { noticeRefreshes += 1 }
    }

    @MainActor private final class Effects { var list: [SettingsModel.Effect] = [] }

    private let ports = FakePorts()
    private let effects = Effects()

    private func model() async -> SettingsModel {
        let model = SettingsModel(ports: ports)
        model.onEffect = { [effects] in effects.list.append($0) }
        await model.appeared()
        return model
    }

    // ports: SettingsViewModelTest#showsTheModelRowsTheCountsTheVersionAndTheNotificationsBanner
    @Test func showsTheModelRowsTheCountsTheVersionAndTheNotificationsBanner() async {
        ports.modelStatuses = [.speech: .ready, .speakers: .downloading(0.46), .voices: .notDownloaded]
        ports.consents = [.speakers, .voices]
        ports.voices = 4
        ports.trash = 2
        ports.notificationsOff = true
        let model = await model()
        #expect(ports.refreshed == 1)
        #expect(ports.noticeRefreshes == 1)
        #expect(model.models.map(\.part) == [.speech, .speakers, .voices])
        #expect(model.models.map(\.status) == [.ready, .downloading(percent: 46), .pending])
        #expect(model.models.map(\.size) == [.managedBySystem, .bytes(21_600_000), .includedWith(.speakers)])
        #expect(model.voices == 4)
        #expect(model.trash == 2)
        #expect(model.version == "9.9.9")
        #expect(model.notificationsOff)
    }

    @Test func aPartNotReadYetHasNoRow() async {
        ports.modelStatuses = [.speech: .notDownloaded]
        #expect(await model().models.map(\.part) == [.speech])
    }

    // ports: SettingsViewModelTest#mapsEveryModelStatus
    @Test func mapsEveryModelStatus() {
        #expect(ModelRows.status(.notDownloaded, consented: false) == .notDownloaded)
        #expect(ModelRows.status(.notDownloaded, consented: true) == .pending)
        #expect(ModelRows.status(.checking, consented: true) == .checking)
        #expect(ModelRows.status(.failed(.fileCheckFailed), consented: true) == .failed)
        #expect(ModelRows.status(.ready, consented: false) == .ready)
        #expect(ModelRows.status(.downloading(0.469), consented: true) == .downloading(percent: 46))
        #expect(ModelRows.status(.downloading(nil), consented: true) == .downloading(percent: 0))
        #expect(ModelRows.status(.unsupported, consented: true) == .unavailable)
        let progress = DownloadProgress(part: .speakers, doneBytes: 50, totalBytes: 200, verifying: false)
        #expect(ModelRows.status(of: progress) == .downloading(0.25))
        #expect(ModelRows.status(of: DownloadProgress(part: .speakers, doneBytes: 1, totalBytes: 2, verifying: true)) == .checking)
    }

    // ports: SettingsViewModelTest#onlyANotDownloadedOrAFailedRowOpensModelDownload
    @Test func onlyANotDownloadedOrAFailedRowOpensModelDownload() async {
        ports.modelStatuses = [.speech: .notDownloaded, .speakers: .failed(.interrupted), .voices: .ready]
        let model = await model()
        model.openModel(.voices)
        model.openModel(.speech)
        // A download that failed (or that iOS stopped) starts again from Model download.
        model.openModel(.speakers)
        #expect(effects.list == Array(repeating: .open(.modelDownload(noteID: nil)), count: 2))

        effects.list = []
        ports.modelStatuses = [.speech: .downloading(0.1), .speakers: .checking, .voices: .notDownloaded]
        ports.consents = [.voices]
        for part in ModelPart.allCases { model.openModel(part) }
        #expect(effects.list.isEmpty, "Downloading, Checking files and Pending rows are not buttons")
    }

    // ports: SettingsViewModelTest#theRowsOpenTheirScreensAndTurnOnOpensTheNotificationSettings
    @Test func theRowsOpenTheirScreensAndTurnOnOpensTheNotificationSettings() async {
        let model = await model()
        model.openVoices()
        model.openTrash()
        model.openLicenses()
        model.turnOnNotifications()
        await model.resumed()
        #expect(effects.list == [.open(.savedVoices), .open(.trash), .open(.licenses), .openNotificationSettings])
        #expect(ports.noticeRefreshes == 2)
    }

    // ports: SettingsViewModelTest#theLanguageGoesToAppCompatAndPhoneIsTheEmptyList (iOS sets the app language in the
    // Settings app: the row opens Cassini's page there)
    @Test func theAppLanguageRowOpensCassinisPageInTheSettingsApp() async {
        let model = await model()
        model.openAppLanguage()
        #expect(effects.list == [.openAppLanguageSettings])
    }

    @Test func theLibraryTotalsLeaveOutRecentlyDeleted() async {
        var kept = Note(title: "Kept"); kept.duration = 90
        var other = Note(title: "Other"); other.duration = 30.5
        var trashed = Note(title: "Trashed"); trashed.duration = 600; trashed.trashedAt = Date(timeIntervalSince1970: 0)
        ports.notes = [kept, trashed, other]
        let totals = await model().library
        #expect(totals == SettingsModel.LibraryTotals(notes: 2, duration: 120.5))
    }
}
