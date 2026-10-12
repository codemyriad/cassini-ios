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
    private let notifier: any Notifier
    private let root: URL

    init(settings: SettingsStore, processing: ProcessingStore, transcriber: any Transcribing,
         analyzer: any SpeakerAnalyzing, storage: any StorageProbe, notifier: any Notifier, root: URL) {
        self.settings = settings; self.processing = processing; self.transcriber = transcriber
        self.analyzer = analyzer; self.storage = storage; self.notifier = notifier; self.root = root
    }

    /// `ModelPlan.plan` over the speech assets of the chosen language and the speaker models' status.
    func plan(for noteID: UUID?) async -> ModelPlan {
        ModelPlan.plan(speech: await transcriber.assetStatus(locale: Locale(identifier: settings.speechLanguage)),
                       speakers: await analyzer.modelStatus(), forNote: noteID != nil,
                       identifySpeakers: settings.identifySpeakers, speakersInstallBytes: analyzer.modelInstallBytes)
    }

    func usableBytes() async -> Int64 { storage.availableBytes(at: root) }

    func recordConsent(for parts: [ModelPart]) {
        if parts.contains(.speech) { settings.recordConsent() }
        if parts.contains(.speakers) { settings.speakerDownloadsAllowed = true }
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

    func shouldAskNotifications() async -> Bool {
        guard !settings.notificationsAsked else { return false }
        return await notifier.authorizationStatus() == .notDetermined
    }

    func askNotifications() async {
        settings.markNotificationsAsked()
        await notifier.requestOnce()
    }
}

