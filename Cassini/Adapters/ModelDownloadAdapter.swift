import Foundation
import CassiniEngine
import CassiniNotebook

/// `ModelDownloadPorts` over the app's stores and models.
@MainActor final class ModelDownloadAdapter: ModelDownloadPorts {
    private let settings: SettingsStore
    private let processing: ProcessingStore
    private let transcriber: any Transcribing
    private let analyzer: any SpeakerAnalyzing
    private let storage: any StorageProbe
    private let notices: NoticeCenter
    private let root: URL

    init(settings: SettingsStore, processing: ProcessingStore, transcriber: any Transcribing,
         analyzer: any SpeakerAnalyzing, storage: any StorageProbe, notices: NoticeCenter, root: URL) {
        self.settings = settings; self.processing = processing; self.transcriber = transcriber
        self.analyzer = analyzer; self.storage = storage; self.notices = notices; self.root = root
    }

    /// `ModelDownloadPlan.plan` over the speech assets of the chosen language and the speaker models' status, for the note's
    /// job.
    func plan(for noteID: UUID?) async -> ModelDownloadPlan {
        let speakersOnly = noteID.flatMap { processing.state.jobs[$0]?.kind } == .speakersOnly
        return ModelDownloadPlan.plan(speech: await transcriber.assetStatus(locale: Locale(identifier: settings.speechLanguage)),
                              speakers: await analyzer.modelStatus(), forNote: noteID != nil,
                              identifySpeakers: settings.identifySpeakers, speakersOnly: speakersOnly,
                              speakersInstallBytes: analyzer.modelInstallBytes)
    }

    func usableBytes() async -> Int64 { storage.availableBytes(at: root) }

    func recordConsent(for parts: [ModelPart]) {
        if parts.contains(.speech) { settings.recordConsent() }
        if parts.contains(.speakers) { settings.recordSpeakerConsent() }
    }

    func recordDeclined() { settings.recordDeclined() }

    func transcribe(_ noteID: UUID) async -> TranscribeOutcome {
        await processing.transcribe(noteID, kind: processing.state.jobs[noteID]?.kind ?? .transcribe)
    }

    /// The parts are installed now, one after another, with their progress and failure in
    /// `ProcessingStore.models` (the Settings rows and the download notice).
    func downloadModels(_ parts: [ModelPart]) {
        processing.models.install(parts)
    }

    func askNotificationsOnce() async { await notices.askNotificationsOnce() }
}

