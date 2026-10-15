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

        func plan(for noteID: UUID?) async -> ModelDownloadPlan { plan }
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
        ports.plan = ModelDownloadPlan.plan(speech: .notDownloaded, speakers: .notDownloaded, forNote: true, identifySpeakers: false,
                                    speakersOnly: true, speakersInstallBytes: 54_000_000)
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

    @Test func thePlanKeepsThePartOrderAndNeedsNoSpaceWhenComplete() {
        #expect(ModelDownloadPlan(missing: [.speakers, .speech], speakersInstallBytes: 1).missing == [.speech, .speakers])
        #expect(ModelDownloadPlan(missing: [], speakersInstallBytes: 1).requiredFreeBytes == 0)
        #expect(ModelDownloadPlan(missing: [.speakers], speakersInstallBytes: 54_000_000).requiredFreeBytes == 54_000_000,
                "the screen asks for what the installer checks")
    }
}
