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
        var languages: [SpeechLanguage] = []
        func speechLanguages() async -> [SpeechLanguage] { languages }
        var recognizer = SpeechRecognizer.appleSpeech
        var platform = PlatformFacts.iOS26
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

    /// Each row's size is its download: on a Parakeet device the speech row shows Ultra's with the precision, "INT8 ·
    /// 443 MB" (D16; the speech detector has no row of its own); on a device that keeps Apple Speech iOS manages the
    /// speech assets. The speakers row is both speaker models; voices come with it.
    @Test func theRowsShowTheirDownloadAndTheSpeechRowTheRecognizers() {
        let speech = ModelCatalog.parakeetBytes
        #expect(ModelRows.size(of: .speech, recognizer: .parakeet, platform: .iOS26) == .precision("INT8", bytes: speech))
        #expect(SizeText(bytes: speech).english() == "443 MB")
        #expect(ModelRows.size(of: .speech, recognizer: .appleSpeech, platform: .iOS26) == .managedBySystem)
        for recognizer in [SpeechRecognizer.parakeet, .appleSpeech] {
            #expect(ModelRows.size(of: .speakers, recognizer: recognizer, platform: .iOS26)
                    == .bytes(ModelCatalog.speakerBytes + ModelCatalog.voiceprintBytes))
            #expect(ModelRows.size(of: .voices, recognizer: recognizer, platform: .iOS26) == .includedWith(.speakers))
        }
        #expect(SizeText(bytes: ModelCatalog.speakerBytes + ModelCatalog.voiceprintBytes).english() == "88 MB")
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
        #expect(ports.refreshed == 2, "models may have changed while Cassini was away")
    }

    @Test func theLanguagePickerListsTheOfferedLanguagesByNameAndKeepsTheChosenOne() async {
        ports.languages = [SpeechLanguage(id: "it-IT", installed: false), SpeechLanguage(id: "en-US", installed: true),
                           SpeechLanguage(id: "de-DE", installed: false)]
        let names = ["it-IT": "Italian", "en-US": "English", "de-DE": "German", "xx-XX": "Zz"]
        let model = await model()
        let name: (String) -> String = { names[$0] ?? $0 }
        #expect(model.languageOptions(chosen: "en-US", name: name)
                == [SpeechLanguage(id: "en-US", installed: true), SpeechLanguage(id: "de-DE", installed: false),
                    SpeechLanguage(id: "it-IT", installed: false)])
        #expect(model.languageOptions(chosen: "xx-XX", name: name).map(\.id) == ["xx-XX", "en-US", "de-DE", "it-IT"],
                "a chosen language that is not on offer stays in the picker")
    }

    /// Only Apple Speech takes a speech language: a Parakeet device has no picker (it would offer one language that
    /// changes nothing), as Android has none.
    @Test func onlyAnAppleSpeechDeviceShowsTheSpeechLanguagePicker() async {
        #expect(await model().showsSpeechLanguage)
        ports.recognizer = .parakeet
        #expect(await !model().showsSpeechLanguage)
    }

    /// A system without Apple speech offers no speech language whatever the recognizer, and its speech row never says
    /// "Managed by iOS": with no recognizer that can run it shows no size, only its status. Every other row and
    /// recognizer reads the same on both systems.
    @Test func withoutAppleSpeechNeitherThePickerNorManagedByIOSAppear() async {
        for platform in [PlatformFacts.iOS26, .iOS18] {
            for recognizer in [SpeechRecognizer.appleSpeech, .parakeet, .whistle] {
                ports.platform = platform
                ports.recognizer = recognizer
                #expect(await model().showsSpeechLanguage == (platform.appleSpeech && recognizer == .appleSpeech))
            }
        }
        #expect(ModelRows.size(of: .speech, recognizer: .appleSpeech, platform: .iOS26) == .managedBySystem)
        #expect(ModelRows.size(of: .speech, recognizer: .appleSpeech, platform: .iOS18) == .noModel)
        for recognizer in [SpeechRecognizer.parakeet, .whistle] {
            for part in ModelPart.allCases {
                #expect(ModelRows.size(of: part, recognizer: recognizer, platform: .iOS18)
                        == ModelRows.size(of: part, recognizer: recognizer, platform: .iOS26))
            }
        }
        for part in [ModelPart.speakers, .voices] {
            #expect(ModelRows.size(of: part, recognizer: .appleSpeech, platform: .iOS18)
                    == ModelRows.size(of: part, recognizer: .appleSpeech, platform: .iOS26))
        }
        #expect(ModelRows.size(of: .speech, recognizer: .whistle, platform: .iOS18) == .included)
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

    @Test func everyModelRowStatusHasItsTone() {
        let tones: [(ModelRowStatus, Tone)] = [
            (.ready, .ok), (.downloading(percent: 46), .info), (.checking, .info), (.pending, .warn), (.failed, .error),
            (.notDownloaded, .plain), (.unavailable, .plain),
        ]
        for (status, tone) in tones { #expect(status.tone == tone, "\(status)") }
    }
}
