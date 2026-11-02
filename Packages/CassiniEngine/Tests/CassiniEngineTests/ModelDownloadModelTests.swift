import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

/// The model download screen over fake ports.
@MainActor @Suite struct ModelDownloadModelTests {
    private static let note = UUID()
    private static let fresh = ModelDownloadPlan(missing: [.speech, .speakers], speakersInstallBytes: 54_000_000)

    @MainActor private final class FakePorts: ModelDownloadPorts {
        var plan = ModelDownloadModelTests.fresh
        var usable = Int64.max
        var askNotifications = false
        var notificationsAsked = false
        var consents: [[ModelPart]] = []
        var declines = 0
        var transcribed: [UUID] = []
        var downloads: [[ModelPart]] = []
        var language: String? = "it-IT"

        func plan(for noteID: UUID?) async -> ModelDownloadPlan { plan }
        func speechLanguage() -> String? { language }
        func usableBytes() async -> Int64 { usable }
        func recordConsent(for parts: [ModelPart]) { consents.append(parts) }
        func recordDeclined() { declines += 1 }
        func transcribe(_ noteID: UUID) async -> TranscribeOutcome { transcribed.append(noteID); return .queued(changed: true) }
        func downloadModels(_ parts: [ModelPart]) { downloads.append(parts) }
        func askNotificationsOnce() async { if askNotifications { notificationsAsked = true } }
    }

    private let ports = FakePorts()

    private func model(noteID: UUID? = note, effects: Effects) async -> ModelDownloadModel {
        let model = ModelDownloadModel(noteID: noteID, ports: ports)
        model.onEffect = { effects.list.append($0) }
        await model.load()
        return model
    }

    @MainActor private final class Effects { var list: [ModelDownloadModel.Effect] = [] }

    // ports: ModelDownloadViewModelTest#showsTheMissingPartsWithTheirSizesAndTheSpaceTheInstallNeeds
    @Test func showsTheMissingPartsAndTheSpaceTheInstallNeeds() async {
        let effects = Effects()
        let model = await model(effects: effects)
        #expect(model.plan?.missing == [.speech, .speakers])
        #expect(model.plan?.requiredFreeBytes == ModelDownloadPlan.speechInstallBytes + 54_000_000)
        #expect(model.withNote)
        #expect(model.noSpaceBytes == nil)
        #expect(await self.model(noteID: nil, effects: effects).withNote == false)
        #expect(effects.list.isEmpty)
    }

    /// D59 (2): on a device that keeps Apple Speech the screen names the speech language a transcription will hear,
    /// set in Settings; a Parakeet device hears it and a speakers-only job recognises no speech, so neither names one.
    @Test func theSpeechLanguageIsNamedOnlyWhereAppleSpeechWillHearIt() async {
        let effects = Effects()
        #expect(await model(effects: effects).speechLanguage == "it-IT", "a note's transcription")
        #expect(await model(noteID: nil, effects: effects).speechLanguage == "it-IT", "the download from Settings")
        ports.plan = ModelDownloadPlan(missing: [.speakers], speakersInstallBytes: 54_000_000)
        #expect(await model(effects: effects).speechLanguage == "it-IT", "Apple's assets are in, the job still transcribes")
        ports.plan = ModelDownloadPlan(missing: [.speakers], speakersInstallBytes: 54_000_000, speakersOnly: true)
        #expect(await model(effects: effects).speechLanguage == nil, "Identify speakers recognises no speech")
        ports.plan = Self.fresh
        ports.language = nil
        #expect(await model(effects: effects).speechLanguage == nil, "Parakeet hears the language")
        #expect(effects.list.isEmpty)
    }

    // ports: ModelDownloadViewModelTest#aStaleEntryQueuesItsNoteAndPopsItself
    @Test func aStaleEntryQueuesItsNoteAndClosesItself() async {
        ports.plan = ModelDownloadPlan(missing: [], requiredFreeBytes: 0)
        let effects = Effects()
        let model = await model(effects: effects)
        #expect(model.plan == nil)
        #expect(ports.transcribed == [Self.note])
        #expect(effects.list == [.close])
        #expect(ports.consents.isEmpty)
    }

    // ports: ModelDownloadViewModelTest#aStaleEntryWithoutANoteOnlyPops
    @Test func aStaleEntryWithoutANoteOnlyCloses() async {
        ports.plan = ModelDownloadPlan(missing: [], requiredFreeBytes: 0)
        let effects = Effects()
        _ = await model(noteID: nil, effects: effects)
        #expect(ports.transcribed.isEmpty)
        #expect(effects.list == [.close])
    }

    // ports: ModelDownloadViewModelTest#downloadAndTranscribeRecordsConsentQueuesTheNoteAndGoesBack
    @Test func downloadAndTranscribeRecordsConsentQueuesTheNoteAndGoesBack() async {
        let effects = Effects()
        let model = await model(effects: effects)
        await model.download()
        #expect(ports.consents == [[.speech, .speakers]])
        #expect(ports.transcribed == [Self.note])
        #expect(ports.downloads.isEmpty)
        #expect(effects.list == [.close])
        await model.download()
        #expect(ports.consents.count == 1, "a closing screen starts nothing again")
    }

    // ports: ModelDownloadViewModelTest#downloadWithoutANoteStartsTheStandaloneDownloadOfTheMissingParts
    @Test func downloadWithoutANoteStartsTheStandaloneDownloadOfTheMissingParts() async {
        ports.plan = ModelDownloadPlan(missing: [.speakers], speakersInstallBytes: 54_000_000)
        let effects = Effects()
        let model = await model(noteID: nil, effects: effects)
        await model.download()
        #expect(ports.consents == [[.speakers]])
        #expect(ports.downloads == [[.speakers]])
        #expect(ports.transcribed.isEmpty)
        #expect(effects.list == [.close])
    }

    // ports: ModelDownloadViewModelTest#notEnoughSpaceShowsTheBannerAndRecordsNoConsentUntilRetryFits
    @Test func notEnoughSpaceShowsTheBannerAndRecordsNoConsentUntilRetryFits() async {
        ports.usable = Self.fresh.requiredFreeBytes - 1
        let effects = Effects()
        let model = await model(effects: effects)
        await model.download()
        #expect(model.noSpaceBytes == Self.fresh.requiredFreeBytes)
        #expect(!model.busy)
        #expect(ports.consents.isEmpty)
        #expect(effects.list.isEmpty)

        ports.usable = Self.fresh.requiredFreeBytes
        await model.download()
        #expect(model.noSpaceBytes == nil)
        #expect(ports.consents.count == 1)
        #expect(ports.transcribed == [Self.note])
        #expect(effects.list == [.close])
    }

    // ports: ModelDownloadViewModelTest#asksForNotificationsOnceBeforeTheFirstDownload
    @Test func asksForNotificationsOnceBeforeTheFirstDownload() async {
        ports.askNotifications = true
        let effects = Effects()
        await model(effects: effects).download()
        #expect(ports.notificationsAsked)
        #expect(ports.consents.count == 1)
        #expect(ports.transcribed == [Self.note])
        #expect(effects.list == [.close])

        // A second download (another note) asks nothing again.
        ports.askNotifications = true
        let second = Effects()
        await model(effects: second).download()
        #expect(ports.consents.count == 2)
        #expect(second.list == [.close])
    }

    // ports: ModelDownloadViewModelTest#notNowRecordsTheRefusalAndGoesBackWithoutConsent
    @Test func notNowRecordsTheRefusalAndGoesBackWithoutConsent() async {
        let effects = Effects()
        let model = await model(effects: effects)
        model.notNow()
        model.notNow()
        #expect(ports.declines == 1)
        #expect(ports.consents.isEmpty)
        #expect(ports.transcribed.isEmpty)
        #expect(effects.list == [.close])
    }

    /// Identify speakers without consent: declining the speaker models is no refusal of the speech model, which
    /// automatic transcription reads.
    @Test func notNowForASpeakersOnlyJobRefusesNoSpeechModel() async {
        ports.plan = ModelDownloadPlan.plan(speech: .notDownloaded, speakers: .notDownloaded, forNote: true,
                                            identifySpeakers: false, speakersOnly: true, speakersInstallBytes: 54_000_000)
        let effects = Effects()
        let model = await model(effects: effects)
        #expect(model.identifiesSpeakers)
        model.notNow()
        #expect(ports.declines == 0)
        #expect(ports.consents.isEmpty)
        #expect(effects.list == [.close])
        // A transcription's plan still says "Download and transcribe".
        ports.plan = Self.fresh
        #expect(await self.model(effects: Effects()).identifiesSpeakers == false)
    }

    // ports: ModelDownloadViewModelTest#closeOnlyPopsAndSourcesOpenLicenses
    @Test func closeOnlyClosesAndSourcesOpenLicenses() async {
        let effects = Effects()
        let model = await model(effects: effects)
        model.openSources()
        model.close()
        #expect(effects.list == [.openLicenses, .close])
        #expect(ports.declines == 0)
        #expect(ports.consents.isEmpty)
    }

    @Test func theStandaloneDownloadPlansTheSpeakerModelsEvenWithIdentifySpeakersOff() {
        func plan(speech: ModelPartStatus, speakers: ModelPartStatus, forNote: Bool, identify: Bool) -> [ModelPart] {
            ModelDownloadPlan.plan(speech: speech, speakers: speakers, forNote: forNote, identifySpeakers: identify,
                                   speakersInstallBytes: 54_000_000).missing
        }
        // The Speakers row of Settings, tapped with Identify speakers off.
        #expect(plan(speech: .ready, speakers: .notDownloaded, forNote: false, identify: false) == [.speakers])
        #expect(plan(speech: .notDownloaded, speakers: .failed(.interrupted), forNote: false, identify: false)
                == [.speech, .speakers])
        // A note's job needs the speaker models only when it tells speakers apart.
        #expect(plan(speech: .ready, speakers: .notDownloaded, forNote: true, identify: false).isEmpty)
        #expect(plan(speech: .ready, speakers: .notDownloaded, forNote: true, identify: true) == [.speakers])
        #expect(plan(speech: .unsupported, speakers: .ready, forNote: false, identify: true).isEmpty,
                "a language the device cannot transcribe has nothing to download")
    }

    @Test func aSpeakersOnlyJobPlansTheSpeakerModelsAlone() {
        func plan(speech: ModelPartStatus, speakers: ModelPartStatus, identify: Bool) -> [ModelPart] {
            ModelDownloadPlan.plan(speech: speech, speakers: speakers, forNote: true, identifySpeakers: identify,
                                   speakersOnly: true, speakersInstallBytes: 54_000_000).missing
        }
        // Identify speakers asks for the speaker models whatever the switch says, and never for the speech model.
        #expect(plan(speech: .notDownloaded, speakers: .notDownloaded, identify: false) == [.speakers])
        #expect(plan(speech: .notDownloaded, speakers: .ready, identify: true).isEmpty)
    }

    // ports: ModelDownloadViewModelTest#showsTheMissingPartsWithTheirSizesAndTheSpaceTheInstallNeeds (the figures)
    /// On a Parakeet device speech shows Ultra's download ("443 MB", D16: the speech detector has no row of its own),
    /// the speakers part both speaker models', the body their total, and the space check asks for the whole install,
    /// the detector included (Android's `ModelPlan`). iOS shows the two speaker models as one part.
    @Test func aParakeetDeviceShowsEachPartsDownloadAndTheSpaceOfTheWholeInstall() {
        let fresh = ModelPlan.of { _ in false }
        let plan = ModelDownloadPlan.plan(speech: .notDownloaded, speakers: .notDownloaded, forNote: false,
                                          identifySpeakers: true, speakersInstallBytes: 1, recognizer: .parakeet,
                                          catalog: fresh)
        #expect(plan.missing == [.speech, .speakers])
        let speech: Int64 = 464_908_884, speakers: Int64 = 64_915_668 + 27_138_478
        #expect(plan.downloadBytes == [.speech: speech, .speakers: speakers])
        #expect(plan.totalDownloadBytes == fresh.totalBytes - ModelCatalog.vad.downloadBytes)
        #expect(plan.requiredFreeBytes == fresh.requiredFreeBytes, "the speech detector counts in the free space")
        #expect(SizeText(bytes: plan.downloadBytes[.speech]!).english() == "443 MB", "D4 and D16")
        #expect(SizeText(bytes: plan.downloadBytes[.speakers]!).english() == "88 MB")
        #expect(SizeText(bytes: plan.totalDownloadBytes!).english() == "531 MB")
        #expect(SizeText(bytes: plan.requiredFreeBytes).english() == "1.2 GB")
    }

    /// Only what is still missing counts: a speech detector already installed is neither shown nor asked room for,
    /// and an installed diarizer leaves CAM++ alone on the speakers row.
    @Test func aParakeetPlanCountsOnlyTheModelsStillMissing() {
        let catalog = ModelPlan.of { $0 == ModelCatalog.vad || $0 == ModelCatalog.diarization }
        let plan = ModelDownloadPlan.plan(speech: .notDownloaded, speakers: .notDownloaded, forNote: false,
                                          identifySpeakers: true, speakersInstallBytes: 1, recognizer: .parakeet,
                                          catalog: catalog)
        #expect(plan.downloadBytes == [.speech: ModelCatalog.parakeetBytes, .speakers: ModelCatalog.voiceprintBytes])
        #expect(plan.requiredFreeBytes == catalog.requiredFreeBytes)
        // A speakers-only job on a Parakeet device: the speaker models' own figures.
        let speakers = ModelDownloadPlan.plan(speech: .notDownloaded, speakers: .notDownloaded, forNote: true,
                                              identifySpeakers: false, speakersOnly: true, speakersInstallBytes: 54_000_000,
                                              recognizer: .parakeet, catalog: ModelPlan.of { _ in false })
        #expect(speakers.missing == [.speakers])
        #expect(speakers.totalDownloadBytes == ModelCatalog.speakerBytes + ModelCatalog.voiceprintBytes)
        #expect(speakers.requiredFreeBytes == 54_000_000, "what the speaker models' installer checks")
    }

    /// On a device that keeps Apple Speech the speech part has no size (iOS does not tell it first), so the body
    /// quotes no total and the space check keeps its estimate.
    @Test func anAppleSpeechDeviceShowsNoSpeechSizeAndKeepsItsEstimate() {
        let plan = ModelDownloadPlan.plan(speech: .notDownloaded, speakers: .notDownloaded, forNote: false,
                                          identifySpeakers: true, speakersInstallBytes: 54_000_000,
                                          recognizer: .appleSpeech, catalog: ModelPlan.of { _ in false })
        #expect(plan.downloadBytes == [.speakers: ModelCatalog.speakerBytes + ModelCatalog.voiceprintBytes])
        #expect(plan.totalDownloadBytes == nil)
        #expect(plan.requiredFreeBytes == ModelDownloadPlan.speechInstallBytes + 54_000_000)
        #expect(ModelDownloadPlan.fullDownloadBytes(.voices) == ModelDownloadPlan.fullDownloadBytes(.speakers))
    }

    @Test func thePlanKeepsThePartOrderAndNeedsNoSpaceWhenComplete() {
        #expect(ModelDownloadPlan(missing: [.speakers, .speech], speakersInstallBytes: 1).missing == [.speech, .speakers])
        #expect(ModelDownloadPlan(missing: [], speakersInstallBytes: 1).requiredFreeBytes == 0)
        #expect(ModelDownloadPlan(missing: [.speakers], speakersInstallBytes: 54_000_000).requiredFreeBytes == 54_000_000,
                "the screen asks for what the installer checks")
    }
}
